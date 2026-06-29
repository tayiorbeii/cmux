import AppKit
import Foundation

/// Sendable error box so the detached-task result crosses the actor boundary
/// without dragging the non-Sendable `any Error` existential across it.
private struct RemoteHandoffFailure: Error, Sendable {
    let message: String
}

/// In-process entrypoint for Remote Handoff from in-app UI surfaces (command
/// palette, and — once wired — keyboard shortcut + custom-command action).
///
/// All handoff behavior lives in the one shared ``RemoteHandoffRunner`` action;
/// the CLI and socket paths exercise the same runner. This wrapper resolves the
/// focused pane from app state, runs the runner off the main actor (it spawns
/// tmux and awaits the restorable-agent index), and surfaces the resulting
/// `ssh … tmux attach` line on the main actor (pasteboard + a confirmation
/// alert).
@MainActor
enum RemoteHandoffInApp {
    /// Resolves the focused pane from `tabManager`, runs Remote Handoff, and
    /// surfaces the result.
    ///
    /// - Parameters:
    ///   - tabManager: The app's tab manager; used to resolve the focused
    ///     workspace + panel UUIDs.
    ///   - mode: `.fork` (resume a fresh copy of the conversation) or
    ///     `.handoff` (resume in place). Defaults to `.fork`.
    ///   - sessionName: Optional explicit tmux session name.
    ///   - sshHost: Optional ssh host baked into the attach line. When `nil`
    ///     the line uses a `<host>` placeholder the user edits before running.
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

        let request = RemoteHandoffRequest(
            workspaceId: workspace.id,
            panelId: panelId,
            mode: mode,
            sessionName: sessionName,
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
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.sshCommand, forType: .string)
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
        let label = String(localized: "remote-handoff.success.copied", defaultValue: "Attach line copied to clipboard:")
        // The ssh line itself is a shell command, not user-facing prose, so it
        // is concatenated outside the localized string.
        alert.informativeText = "\(label)\n\(result.sshCommand)"
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
