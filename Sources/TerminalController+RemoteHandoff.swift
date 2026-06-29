import Foundation

/// App-side worker-lane handler for the `remote-handoff.run` socket method.
///
/// `remote-handoff.run` blocks (it spawns tmux) and awaits (it loads the
/// restorable-agent index via `loadIncludingProcessDetectedSnapshots`), so —
/// per the `ControlCommandCoordinator` isolation contract ("worker-lane methods
/// that block or await are NOT handled here; they stay on the app-side worker
/// path") — it is NOT hosted on the `@MainActor` coordinator seam. Instead
/// `processV2Command` dispatches it onto the legacy worker lane via
/// `v2AsyncResultCall`, which runs `v2RemoteHandoffRun` off-main and blocks the
/// calling socket read until it finishes.
///
/// UUID / `kind:N` handle-ref resolution happens on the main actor in
/// `processV2Command` (the coordinator's `resolveRef` lives on main); the
/// resolved UUIDs are passed in here so the async body never needs to hop to
/// main. All handoff logic lives in the one shared ``RemoteHandoffRunner``
/// action (also used by the in-app palette/shortcut entrypoints), so the CLI,
/// socket, and UI paths share identical behavior.
extension TerminalController {
    /// Runs one `remote-handoff.run` request against the shared
    /// ``RemoteHandoffRunner`` action.
    ///
    /// - Parameters:
    ///   - workspaceID: The resolved workspace UUID of the targeted pane.
    ///   - panelID: The resolved surface/panel UUID of the targeted pane.
    ///   - params: The raw socket params (used for `mode`, `session_name`,
    ///     `ssh_host`).
    /// - Returns: A ``V2CallResult`` — `.ok` with the handoff payload on
    ///   success, or `.err` with a stable `RemoteHandoffError.socketErrorCode`.
    nonisolated func v2RemoteHandoffRun(
        workspaceID: UUID?,
        panelID: UUID?,
        params: [String: Any]
    ) async -> V2CallResult {
        guard let workspaceID else {
            return .err(
                code: "invalid_params",
                message: String(localized: "remote-handoff.error.missing-workspace-id", defaultValue: "remote-handoff.run requires a workspace_id."),
                data: nil
            )
        }
        guard let panelID else {
            return .err(
                code: "invalid_params",
                message: String(localized: "remote-handoff.error.missing-surface-id", defaultValue: "remote-handoff.run requires a surface_id."),
                data: nil
            )
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
            workspaceId: workspaceID,
            panelId: panelID,
            mode: mode,
            sessionName: sessionName,
            sshHost: sshHost
        )
        // `RemoteHandoffRunner` is a Sendable value type whose async `run()`
        // is nonisolated, so it is safe to drive from this off-main worker body.
        let runner = RemoteHandoffRunner(request: request)
        do {
            let result = try await runner.run()
            return .ok([
                "session_name": result.sessionName,
                "working_directory": result.workingDirectory,
                "agent_display_name": result.agentDisplayName,
                "startup_input": result.startupInput,
                "ssh_command": result.sshCommand,
                "workspace_id": workspaceID.uuidString,
            ])
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

    /// Trims an optional socket string param, returning `nil` for absent/empty.
    nonisolated private func trimmedOptionalString(_ raw: Any?) -> String? {
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
