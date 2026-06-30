import Foundation

/// App-side handler for the compatibility `remote-handoff.run` socket method.
///
/// The method name is retained for existing CLI/config callers, but the default
/// behavior is now local: resolve the targeted terminal surface, validate a tmux
/// relaunch spec off-main, then respawn that same surface on the main actor so
/// it runs `tmux new-session -A` locally. SSH output is produced only when the
/// caller explicitly passes `ssh_host`.
extension TerminalController {
    private struct RemoteHandoffTarget: Sendable {
        var workspaceID: UUID
        var panelID: UUID
        var workingDirectory: String
    }

    private enum RemoteHandoffTargetResolution {
        case success(RemoteHandoffTarget)
        case failure(V2CallResult)
    }

    /// Runs one `remote-handoff.run` request against the shared
    /// ``RemoteHandoffRunner`` preparation action, then applies the resulting
    /// local tmux command to the targeted terminal surface.
    ///
    /// - Parameters:
    ///   - workspaceID: The resolved workspace UUID of the targeted pane.
    ///   - panelID: The resolved surface/panel UUID of the targeted pane.
    ///   - params: The raw socket params (used for `mode`, `session_name`,
    ///     `ssh_host`).
    /// - Returns: A ``V2CallResult`` — `.ok` with the handoff payload on
    ///   success, or `.err` with a stable code.
    nonisolated func v2RemoteHandoffRun(
        workspaceID: UUID?,
        panelID: UUID?,
        params: [String: Any]
    ) async -> V2CallResult {
        let targetResolution = v2MainSync {
            self.v2RemoteHandoffResolveTarget(workspaceID: workspaceID, panelID: panelID)
        }
        let target: RemoteHandoffTarget
        switch targetResolution {
        case .success(let resolved):
            target = resolved
        case .failure(let failure):
            return failure
        }

        let mode: RemoteHandoffMode
        switch (params["mode"] as? String ?? "fork").lowercased() {
        case "handoff", "resume":
            mode = .handoff
        default:
            mode = .fork
        }
        let sessionName = trimmedOptionalString(params["session_name"])
        let sshHost = trimmedOptionalString(params["ssh_host"])

        let request = RemoteHandoffRequest(
            workspaceId: target.workspaceID,
            panelId: target.panelID,
            mode: mode,
            sessionName: sessionName,
            workingDirectory: target.workingDirectory,
            sshHost: sshHost
        )
        // `RemoteHandoffRunner` is a Sendable value type whose async `run()`
        // is nonisolated, so it is safe to drive from this off-main worker body.
        let runner = RemoteHandoffRunner(request: request)
        do {
            let result = try await runner.run()
            return v2MainSync {
                self.v2RemoteHandoffApply(result, target: target)
            }
        } catch let error as RemoteHandoffError {
            return .err(code: error.socketErrorCode, message: String(describing: error), data: nil)
        } catch {
            return .err(code: "handoff_failed", message: String(describing: error), data: nil)
        }
    }

    /// Resolves a `remote-handoff.run` target-id param — either a UUID string
    /// or a `kind:N` handle ref — to a UUID. Called from the nonisolated
    /// `processV2Command` worker lane; ref resolution hops to the main actor via
    /// `v2MainSync` (the coordinator's `resolveRef` is main-isolated).
    nonisolated func v2ResolveHandoffTargetID(_ raw: Any?) -> UUID? {
        guard let string = raw as? String else { return nil }
        if let uuid = UUID(uuidString: string) { return uuid }
        return v2MainSync { self.v2ResolveHandleRef(string) }
    }

    @MainActor
    private func v2RemoteHandoffResolveTarget(workspaceID: UUID?, panelID: UUID?) -> RemoteHandoffTargetResolution {
        guard let workspaceID else {
            return .failure(.err(
                code: "invalid_params",
                message: String(localized: "remote-handoff.error.missing-workspace-id", defaultValue: "remote-handoff.run requires a workspace_id."),
                data: nil
            ))
        }
        guard let panelID else {
            return .failure(.err(
                code: "invalid_params",
                message: String(localized: "remote-handoff.error.missing-surface-id", defaultValue: "remote-handoff.run requires a surface_id."),
                data: nil
            ))
        }
        guard let located = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelID,
            preferredWorkspaceId: workspaceID
        ) else {
            return .failure(.err(
                code: "surface_not_found",
                message: String(localized: "remote-handoff.error.surface-not-found", defaultValue: "The targeted pane could not be found."),
                data: nil
            ))
        }
        guard located.workspace.id == workspaceID else {
            return .failure(.err(
                code: "workspace_not_found",
                message: String(localized: "remote-handoff.error.workspace-not-found", defaultValue: "The targeted workspace could not be found."),
                data: nil
            ))
        }
        guard located.workspace.terminalPanel(for: panelID) != nil else {
            return .failure(.err(
                code: "surface_not_terminal",
                message: String(localized: "remote-handoff.error.surface-not-terminal", defaultValue: "The targeted pane is not a terminal."),
                data: nil
            ))
        }
        return .success(RemoteHandoffTarget(
            workspaceID: workspaceID,
            panelID: panelID,
            workingDirectory: located.workspace.remoteHandoffWorkingDirectory(for: panelID)
        ))
    }

    @MainActor
    private func v2RemoteHandoffApply(_ result: RemoteHandoffResult, target: RemoteHandoffTarget) -> V2CallResult {
        guard let located = AppDelegate.shared?.workspaceContainingPanel(
            panelId: target.panelID,
            preferredWorkspaceId: target.workspaceID
        ), located.workspace.id == target.workspaceID else {
            return .err(
                code: "surface_not_found",
                message: String(localized: "remote-handoff.error.surface-not-found", defaultValue: "The targeted pane could not be found."),
                data: nil
            )
        }
        guard located.workspace.applyRemoteHandoff(result, toPanelId: target.panelID) else {
            return .err(
                code: "respawn_failed",
                message: String(localized: "remote-handoff.error.respawn-failed", defaultValue: "Could not relaunch the targeted pane in tmux."),
                data: nil
            )
        }

        var payload: [String: Any] = [
            "session_name": result.sessionName,
            "working_directory": result.workingDirectory,
            "agent_display_name": result.agentDisplayName,
            "startup_input": result.startupInput,
            "local_command": result.localCommand,
            "workspace_id": target.workspaceID.uuidString,
            "surface_id": target.panelID.uuidString,
        ]
        if let sshCommand = result.sshCommand {
            payload["ssh_command"] = sshCommand
        }
        return .ok(payload)
    }

    /// Trims an optional socket string param, returning `nil` for absent/empty.
    nonisolated private func trimmedOptionalString(_ raw: Any?) -> String? {
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
