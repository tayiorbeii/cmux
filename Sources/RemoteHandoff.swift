import Foundation

// MARK: - Remote handoff public surface

/// Whether a remote handoff continues the original conversation in place or
/// branches a fresh copy, leaving the original untouched.
///
/// `fork` is the safe default: the agent's original session is not modified.
/// `handoff` resumes the original session in place inside the new tmux pane.
enum RemoteHandoffMode: String, Sendable, CaseIterable {
    case fork
    case handoff
}

/// The resolved inputs to a remote handoff.
struct RemoteHandoffRequest: Sendable {
    /// Workspace UUID of the pane whose agent should be handed off.
    var workspaceId: UUID
    /// Panel UUID of the pane. In cmux this is identical to the surface UUID
    /// (`CMUX_PANEL_ID` is exported equal to `CMUX_SURFACE_ID`).
    var panelId: UUID
    /// `.fork` (default) branches the conversation; `.handoff` resumes in place.
    var mode: RemoteHandoffMode = .fork
    /// Optional explicit tmux session name. When `nil` a name is derived from
    /// the detected agent and session id.
    var sessionName: String?
    /// Host printed in the `ssh` attach line. Defaults to a `<host>` placeholder
    /// when the caller does not know the remote address.
    var sshHost: String?
}

/// The outcome of a successful remote handoff.
struct RemoteHandoffResult: Sendable, Codable {
    /// The tmux session name that was created.
    var sessionName: String
    /// Working directory the tmux session was rooted at.
    var workingDirectory: String
    /// Human-readable name of the detected agent.
    var agentDisplayName: String
    /// Startup input fed to the new pane (resume/fork command or launcher path).
    var startupInput: String
    /// The `ssh … tmux attach` line to run from a remote machine.
    var sshCommand: String
}

/// Reasons a remote handoff can fail. Descriptions are user-facing and localized.
enum RemoteHandoffError: Error, CustomStringConvertible {
    /// No restorable agent session was found for the targeted pane.
    case noAgentDetected
    /// An agent was detected but no resume/fork startup input could be produced.
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
            return String(localized: "remote-handoff.error.session-name-invalid", defaultValue: "Invalid tmux session name: \(name)")
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

/// Read-only view over the restorable-agent index sufficient for handoff.
/// `RestorableAgentSessionIndex` conforms retroactively (same target).
protocol RemoteHandoffIndexSnapshotting: Sendable {
    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot?
}

/// Loads the restorable-agent index. Exposed as both an async path (for the
/// app's interactive entrypoints, which must not block the main actor) and a
/// synchronous path (for the short-lived, non-interactive CLI process).
protocol AgentSessionResolving: Sendable {
    func loadIndexAsync() async -> any RemoteHandoffIndexSnapshotting
    func loadIndexSync() -> any RemoteHandoffIndexSnapshotting
}

/// Creates and feeds the tmux session. Split out so tests can capture the
/// exact `tmux` argv without spawning a real process.
protocol TmuxSessionCreating: Sendable {
    func createDetachedSession(name: String, workingDirectory: String) throws
    func sendKeys(target: String, input: String) throws
}

/// Default `AgentSessionResolving` backed by the real vault-agent index.
struct VaultAgentSessionResolver: AgentSessionResolving {
    var homeDirectory: String
    // FileManager is Apple-documented thread-safe; safe to capture in a Sendable value type.
    nonisolated(unsafe) var fileManager: FileManager

    init(homeDirectory: String = NSHomeDirectory(), fileManager: FileManager = .default) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func loadIndexAsync() async -> any RemoteHandoffIndexSnapshotting {
        await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
    }

    func loadIndexSync() -> any RemoteHandoffIndexSnapshotting {
        RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshotsSynchronously(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
    }
}

extension RestorableAgentSessionIndex: RemoteHandoffIndexSnapshotting {}

/// Default `TmuxSessionCreating` that spawns the real `tmux` binary.
struct TmuxSessionController: TmuxSessionCreating {
    func createDetachedSession(name: String, workingDirectory: String) throws {
        try Self.runTmux(arguments: ["new-session", "-d", "-s", name, "-c", workingDirectory])
    }

    func sendKeys(target: String, input: String) throws {
        // `tmux send-keys` types the input verbatim, then `Enter` submits it.
        // A trailing newline in the startup input would be typed as a literal
        // newline, so callers must strip it; we guard defensively here too.
        let sanitized = input.trimmingCharacters(in: .newlines)
        try Self.runTmux(arguments: ["send-keys", "-t", target, sanitized, "Enter"])
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

/// Shared remote-handoff action. The single mutation path invoked by every
/// entrypoint (CLI verb, command palette, keyboard shortcut, custom command).
///
/// Target resolution (which pane is focused) is entrypoint-specific; the
/// handoff logic itself lives only here.
struct RemoteHandoffRunner: Sendable {
    var request: RemoteHandoffRequest
    var resolver: any AgentSessionResolving
    var tmux: any TmuxSessionCreating
    // FileManager is Apple-documented thread-safe; safe to capture in a Sendable value type.
    nonisolated(unsafe) var fileManager: FileManager
    var temporaryDirectory: URL
    var homeDirectory: String

    init(
        request: RemoteHandoffRequest,
        resolver: any AgentSessionResolving = VaultAgentSessionResolver(),
        tmux: any TmuxSessionCreating = TmuxSessionController(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.request = request
        self.resolver = resolver
        self.tmux = tmux
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
        self.homeDirectory = homeDirectory
    }

    /// Async entrypoint for in-app entrypoints (palette/shortcut). Uses the
    /// async agent-index loader so the main actor is never blocked.
    func run() async throws -> RemoteHandoffResult {
        let index = await resolver.loadIndexAsync()
        return try buildResult(from: index)
    }

    /// Synchronous entrypoint for the short-lived, non-interactive CLI process.
    /// Uses the synchronous agent-index loader (acceptable outside the app's
    /// interactive main-actor paths).
    func runSynchronously() throws -> RemoteHandoffResult {
        let index = resolver.loadIndexSync()
        return try buildResult(from: index)
    }

    /// Snapshot → tmux session → ssh line. Shared by both entrypoints.
    private func buildResult(from index: any RemoteHandoffIndexSnapshotting) throws -> RemoteHandoffResult {
        guard let snapshot = index.snapshot(workspaceId: request.workspaceId, panelId: request.panelId) else {
            throw RemoteHandoffError.noAgentDetected
        }

        let rawInput: String?
        switch request.mode {
        case .fork:
            rawInput = snapshot.forkStartupInput(
                fileManager: fileManager,
                temporaryDirectory: temporaryDirectory
            )
        case .handoff:
            rawInput = snapshot.resumeStartupInput(
                fileManager: fileManager,
                temporaryDirectory: temporaryDirectory
            )
        }
        guard let input = rawInput?.trimmingCharacters(in: .newlines), !input.isEmpty else {
            throw RemoteHandoffError.startupInputUnavailable
        }

        let workingDirectory = snapshot.workingDirectory
            ?? snapshot.launchCommand?.workingDirectory
            ?? homeDirectory

        let sessionName = try Self.resolveSessionName(requested: request.sessionName, snapshot: snapshot)

        try tmux.createDetachedSession(name: sessionName, workingDirectory: workingDirectory)
        try tmux.sendKeys(target: sessionName, input: input)

        let sshHost = request.sshHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = (sshHost?.isEmpty == false) ? sshHost! : "<host>"
        let sshCommand = "ssh \(resolvedHost) -t tmux attach -t \(sessionName)"

        return RemoteHandoffResult(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            agentDisplayName: snapshot.agentDisplayName,
            startupInput: input,
            sshCommand: sshCommand
        )
    }

    /// Derives and validates the tmux session name. tmux forbids `.` and `:`
    /// (target separators) and names are easier to type without spaces.
    static func resolveSessionName(requested: String?, snapshot: SessionRestorableAgentSnapshot) throws -> String {
        let candidate: String
        if let requested {
            candidate = requested
        } else {
            let agent = snapshot.kind.rawValue
            let suffix = String(snapshot.sessionId.prefix(8)).lowercased()
            candidate = suffix.isEmpty ? agent : "\(agent)-\(suffix)"
        }
        let sanitized = sanitizeSessionName(candidate)
        guard sanitized == candidate, isValidSessionName(sanitized) else {
            throw RemoteHandoffError.sessionNameInvalid(candidate)
        }
        return sanitized
    }

    /// tmux session names may not contain `.` or `:`. We additionally reject
    /// empty names and whitespace so the printed `ssh`/`tmux` line stays safe.
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
}
