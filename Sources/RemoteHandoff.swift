import Foundation

// MARK: - Remote handoff public surface

/// Compatibility mode accepted by the public tmux-handoff surface.
///
/// The modern flow always relaunches the targeted local terminal surface into a
/// tmux client. `fork`/`handoff` are still parsed so existing configs and CLI
/// invocations keep working, but they no longer change local tmux launch
/// behavior.
enum RemoteHandoffMode: String, Sendable, CaseIterable {
    case fork
    case handoff
}

/// The resolved inputs to a tmux handoff.
struct RemoteHandoffRequest: Sendable {
    /// Workspace UUID of the terminal pane to relaunch.
    var workspaceId: UUID
    /// Panel UUID of the terminal pane. In cmux this is identical to the surface
    /// UUID (`CMUX_PANEL_ID` is exported equal to `CMUX_SURFACE_ID`).
    var panelId: UUID
    /// Compatibility-only mode flag. Accepted for old callers; ignored by the
    /// local tmux relaunch flow.
    var mode: RemoteHandoffMode = .fork
    /// Optional explicit tmux session name. When `nil` a stable local name is
    /// derived from the workspace and panel IDs.
    var sessionName: String?
    /// Optional working directory for the relaunched terminal. When `nil`, the
    /// user's home directory is used.
    var workingDirectory: String?
    /// Optional host for the compatibility SSH attach line. No SSH command is
    /// produced unless this is explicitly provided.
    var sshHost: String?
}

/// The outcome of a successful tmux handoff preparation.
struct RemoteHandoffResult: Sendable, Codable {
    /// The tmux session name that the local pane will attach to/create.
    var sessionName: String
    /// Working directory the relaunched terminal is rooted at.
    var workingDirectory: String
    /// Compatibility field for older socket clients. The local flow is tmux-only.
    var agentDisplayName: String
    /// Compatibility field for older socket clients. Mirrors ``localCommand``.
    var startupInput: String
    /// The local command used to relaunch the targeted terminal pane.
    var localCommand: String
    /// Optional `ssh … tmux attach` line, present only when the caller explicitly
    /// passed a host.
    var sshCommand: String?
}

/// Reasons a tmux handoff can fail. Descriptions are user-facing and localized.
enum RemoteHandoffError: Error, CustomStringConvertible {
    /// Legacy error kept for wire compatibility with the old snapshot-driven
    /// flow. The local flow does not require an agent snapshot.
    case noAgentDetected
    /// Legacy error kept for wire compatibility with the old snapshot-driven flow.
    case startupInputUnavailable
    /// `tmux` is not installed or not on the search PATH.
    case tmuxNotFound
    /// `tmux` exited non-zero. The associated string is tmux's stderr.
    case tmuxFailed(String)
    /// The requested session name is not a valid tmux session name.
    case sessionNameInvalid(String)

    var description: String {
        switch self {
        case .noAgentDetected:
            return String(localized: "remote-handoff.error.no-agent-detected", defaultValue: "No running coding agent was detected in the targeted pane.")
        case .startupInputUnavailable:
            return String(localized: "remote-handoff.error.startup-input-unavailable", defaultValue: "The detected agent could not produce a resume command.")
        case .tmuxNotFound:
            return String(localized: "remote-handoff.error.tmux-not-found", defaultValue: "tmux was not found. Install tmux to use tmux handoff.")
        case .tmuxFailed(let detail):
            let summary = String(localized: "remote-handoff.error.tmux-failed", defaultValue: "tmux failed.")
            return detail.isEmpty ? summary : "\(summary) \(detail)"
        case .sessionNameInvalid(let name):
            return String(localized: "remote-handoff.error.session-name-invalid", defaultValue: "Invalid tmux session name: \(name).")
        }
    }

    /// Stable machine-readable wire code for the `remote-handoff.run` socket
    /// error response (the human message is ``description``).
    var socketErrorCode: String {
        switch self {
        case .noAgentDetected: "no_agent_detected"
        case .startupInputUnavailable: "startup_input_unavailable"
        case .tmuxNotFound: "tmux_not_found"
        case .tmuxFailed: "tmux_failed"
        case .sessionNameInvalid: "invalid_session_name"
        }
    }
}

// MARK: - Seams

/// Resolves the tmux executable. Split out so tests can avoid depending on the
/// developer machine's PATH while production still validates tmux availability
/// before replacing a pane.
protocol TmuxExecutableResolving: Sendable {
    func resolveExecutable() throws -> String
}

/// Default resolver for the real `tmux` binary.
struct TmuxSessionController: TmuxExecutableResolving {
    func resolveExecutable() throws -> String {
        try Self.resolveTmuxExecutable()
    }

    /// Runs `tmux` with the given argv, capturing stderr and throwing
    /// ``RemoteHandoffError/tmuxFailed(_:)`` on a non-zero exit.
    static func runTmux(arguments: [String]) throws {
        let executable = try resolveTmuxExecutable()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw RemoteHandoffError.tmuxFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RemoteHandoffError.tmuxFailed(detail)
        }
    }

    /// Locates the `tmux` executable. Checks well-known Homebrew prefixes and
    /// then the search PATH. Throws ``RemoteHandoffError/tmuxNotFound`` otherwise.
    static func resolveTmuxExecutable() throws -> String {
        let wellKnown = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        for candidate in wellKnown where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = String(dir) + "/tmux"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        throw RemoteHandoffError.tmuxNotFound
    }
}

// MARK: - Runner

/// Shared tmux-handoff action. The single preparation path invoked by every
/// entrypoint (CLI verb, command palette, keyboard shortcut, custom command).
///
/// Target resolution and the actual pane respawn are app-state concerns. This
/// runner validates the tmux/session inputs and returns the local command that
/// the caller should use to replace the targeted terminal surface.
struct RemoteHandoffRunner: Sendable {
    var request: RemoteHandoffRequest
    var tmux: any TmuxExecutableResolving
    var homeDirectory: String

    init(
        request: RemoteHandoffRequest,
        tmux: any TmuxExecutableResolving = TmuxSessionController(),
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.request = request
        self.tmux = tmux
        self.homeDirectory = homeDirectory
    }

    /// Async entrypoint retained for in-app/socket callers that already await
    /// the shared action.
    func run() async throws -> RemoteHandoffResult {
        try buildResult()
    }

    /// Synchronous entrypoint for short-lived, non-interactive callers/tests.
    func runSynchronously() throws -> RemoteHandoffResult {
        try buildResult()
    }

    /// Build the local tmux relaunch spec. This intentionally does not require
    /// a restorable coding-agent snapshot and does not create a detached tmux
    /// session ahead of time; the target pane itself runs `tmux new-session -A`.
    private func buildResult() throws -> RemoteHandoffResult {
        let executable = try tmux.resolveExecutable()
        let workingDirectory = Self.resolveWorkingDirectory(
            requested: request.workingDirectory,
            homeDirectory: homeDirectory
        )
        let sessionName = try Self.resolveSessionName(
            requested: request.sessionName,
            workspaceId: request.workspaceId,
            panelId: request.panelId
        )
        let localCommand = "exec \(Self.shellQuoted(executable)) new-session -A -s \(Self.shellQuoted(sessionName))"

        let sshHost = request.sshHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sshCommand = (sshHost?.isEmpty == false)
            ? "ssh \(sshHost!) -t tmux attach -t \(sessionName)"
            : nil

        return RemoteHandoffResult(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            agentDisplayName: "tmux",
            startupInput: localCommand,
            localCommand: localCommand,
            sshCommand: sshCommand
        )
    }

    /// Derives and validates the tmux session name. tmux forbids `.` and `:`
    /// (target separators) and names are easier to type without spaces.
    static func resolveSessionName(requested: String?, workspaceId: UUID, panelId: UUID) throws -> String {
        let candidate: String
        if let requested {
            candidate = requested
        } else {
            candidate = "cmux-\(shortID(workspaceId))-\(shortID(panelId))"
        }
        let sanitized = sanitizeSessionName(candidate)
        guard sanitized == candidate, isValidSessionName(sanitized) else {
            throw RemoteHandoffError.sessionNameInvalid(candidate)
        }
        return sanitized
    }

    /// tmux session names may not contain `.` or `:`. We additionally reject
    /// empty names and whitespace so printed shell lines stay safe/readable.
    static func isValidSessionName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if name.contains(".") || name.contains(":") { return false }
        if name.contains(where: { $0.isWhitespace }) { return false }
        return true
    }

    /// Returns the name with forbidden characters removed, for diagnostic use.
    static func sanitizeSessionName(_ name: String) -> String {
        String(name.unicodeScalars.filter { scalar in
            scalar != "." && scalar != ":" && !CharacterSet.whitespaces.contains(scalar)
        })
    }

    static func resolveWorkingDirectory(requested: String?, homeDirectory: String) -> String {
        let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requested, !requested.isEmpty {
            return requested
        }
        let home = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return home.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : home
    }

    static func shellQuoted(_ value: String) -> String {
        let safeCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-")
        if !value.isEmpty,
           value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shortID(_ uuid: UUID) -> String {
        String(uuid.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}
