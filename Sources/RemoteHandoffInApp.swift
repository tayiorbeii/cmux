import AppKit
import Foundation

/// Sendable error box so the detached-task result crosses the actor boundary
/// without dragging the non-Sendable `any Error` existential across it.
private struct RemoteHandoffFailure: Error, Sendable {
    let message: String
}

/// In-process entrypoint for Tmux Handoff from in-app UI surfaces (command
/// palette, keyboard shortcut, menu item, and custom-command action).
///
/// All handoff behavior uses the shared ``RemoteHandoffRunner`` preparation
/// path; this wrapper resolves the focused local terminal pane from app state,
/// validates tmux off the main actor, then respawns that same surface locally
/// running tmux.
@MainActor
enum RemoteHandoffInApp {
    /// Resolves the focused pane from `tabManager`, runs Tmux Handoff, and
    /// surfaces the result.
    ///
    /// - Parameters:
    ///   - tabManager: The app's tab manager; used to resolve the focused
    ///     workspace + panel UUIDs.
    ///   - mode: Compatibility-only `.fork`/`.handoff` flag. Accepted but not
    ///     behavior-changing in the local tmux relaunch flow.
    ///   - sessionName: Optional explicit tmux session name.
    ///   - sshHost: Optional ssh host for an additional attach line. When `nil`,
    ///     no SSH command is produced or copied.
    static func perform(
        tabManager: TabManager,
        mode: RemoteHandoffMode = .fork,
        sessionName: String? = nil,
        sshHost: String? = nil
    ) async {
        guard let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            presentError(message: String(localized: "remote-handoff.error.no-focused-pane", defaultValue: "No focused pane to hand off."))
            return
        }
        guard workspace.terminalPanel(for: panelId) != nil else {
            presentError(message: String(localized: "remote-handoff.error.surface-not-terminal", defaultValue: "The targeted pane is not a terminal."))
            return
        }

        let workingDirectory = workspace.remoteHandoffWorkingDirectory(for: panelId)
        let request = RemoteHandoffRequest(
            workspaceId: workspace.id,
            panelId: panelId,
            mode: mode,
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            sshHost: sshHost
        )
        // `RemoteHandoffRunner` is a Sendable value type whose async `run()` is
        // nonisolated, so it is safe to drive from a detached task off the main
        // actor. The error is stringified inside the detached task so the
        // crossed-actor result stays Sendable.
        let runner = RemoteHandoffRunner(request: request)
        let outcome: Result<RemoteHandoffResult, RemoteHandoffFailure> = await Task.detached(priority: .userInitiated) {
            do { return .success(try await runner.run()) }
            catch { return .failure(RemoteHandoffFailure(message: String(describing: error))) }
        }.value

        switch outcome {
        case .success(let result):
            guard workspace.applyRemoteHandoff(result, toPanelId: panelId) else {
                presentError(message: String(localized: "remote-handoff.error.respawn-failed", defaultValue: "Could not relaunch the targeted pane in tmux."))
                return
            }
            if let sshCommand = result.sshCommand {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sshCommand, forType: .string)
            }
            presentSuccess(result: result)
        case .failure(let failure):
            presentError(message: failure.message)
        }
    }

    // MARK: - Presentation

    private static func presentSuccess(result: RemoteHandoffResult) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "remote-handoff.success.title", defaultValue: "Tmux handoff ready")
        if let sshCommand = result.sshCommand {
            let label = String(localized: "remote-handoff.success.copied", defaultValue: "Attach line copied to clipboard:")
            // The ssh line itself is a shell command, not user-facing prose, so
            // it is concatenated outside the localized string.
            alert.informativeText = "\(label)\n\(sshCommand)"
        } else {
            alert.informativeText = String(
                localized: "remote-handoff.success.local",
                defaultValue: "Relaunched the targeted pane in local tmux session \"\(result.sessionName)\"."
            )
        }
        alert.addButton(withTitle: String(localized: "remote-handoff.common.ok", defaultValue: "OK"))
        _ = alert.runModal()
    }

    private static func presentError(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "remote-handoff.error.title", defaultValue: "Tmux handoff failed")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "remote-handoff.common.ok", defaultValue: "OK"))
        _ = alert.runModal()
    }
}

@MainActor
extension Workspace {
    func remoteHandoffWorkingDirectory(for panelId: UUID) -> String {
        for candidate in [
            panelDirectories[panelId],
            terminalPanel(for: panelId)?.requestedWorkingDirectory,
            currentDirectory,
        ] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    @discardableResult
    func applyRemoteHandoff(_ result: RemoteHandoffResult, toPanelId panelId: UUID) -> Bool {
        respawnTerminalSurface(
            panelId: panelId,
            command: result.localCommand,
            workingDirectory: result.workingDirectory,
            tmuxStartCommand: result.localCommand,
            focus: nil
        ) != nil
    }
}
