import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

// MARK: - Test seams

/// Returns a fixed snapshot for any (workspace, panel) lookup.
private struct FixedSnapshotIndex: RemoteHandoffIndexSnapshotting {
    let snapshot: SessionRestorableAgentSnapshot?

    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        snapshot
    }
}

/// Always serves the same index, for both the async and sync paths.
private struct FixedResolver: AgentSessionResolving {
    let index: any RemoteHandoffIndexSnapshotting

    func loadIndexAsync() async -> any RemoteHandoffIndexSnapshotting { index }
    func loadIndexSync() -> any RemoteHandoffIndexSnapshotting { index }
}

/// Records tmux calls instead of spawning a real process. Single-threaded in
/// tests, hence `@unchecked Sendable`.
private final class RecordingTmux: TmuxSessionCreating, @unchecked Sendable {
    private(set) var createdSessions: [(name: String, workingDirectory: String)] = []
    private(set) var sentKeys: [(target: String, input: String)] = []

    func createDetachedSession(name: String, workingDirectory: String) throws {
        createdSessions.append((name, workingDirectory))
    }

    func sendKeys(target: String, input: String) throws {
        sentKeys.append((target, input))
    }
}

// MARK: - Helpers

private extension RemoteHandoffRunner {
    static func make(
        request: RemoteHandoffRequest,
        snapshot: SessionRestorableAgentSnapshot?,
        tmux: RecordingTmux,
        homeDirectory: String = "/tmp/cmux-handoff-home"
    ) -> RemoteHandoffRunner {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-handoff-tests-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        return RemoteHandoffRunner(
            request: request,
            resolver: FixedResolver(index: FixedSnapshotIndex(snapshot: snapshot)),
            tmux: tmux,
            fileManager: .default,
            temporaryDirectory: temporaryDirectory,
            homeDirectory: homeDirectory
        )
    }
}

/// A snapshot for a custom agent whose resume/fork templates are literal
/// `/bin/echo` commands (no `{{executable}}` resolution), so
/// `forkStartupInput`/`resumeStartupInput` are deterministic and non-nil in
/// tests regardless of which binaries are installed.
private func testSnapshot(
    sessionId: String = "abc12345",
    workingDirectory: String? = "/tmp/proj",
    launchCommand: AgentLaunchCommandSnapshot? = nil
) -> SessionRestorableAgentSnapshot {
    let registration = CmuxVaultAgentRegistration(
        id: "testagent",
        name: "Test Agent",
        detect: .init(),
        sessionIdSource: .argvOption("--session"),
        resumeCommand: "/bin/echo resume {{sessionId}}",
        forkCommand: "/bin/echo fork {{sessionId}}"
    )
    return SessionRestorableAgentSnapshot(
        kind: .custom("testagent"),
        sessionId: sessionId,
        workingDirectory: workingDirectory,
        launchCommand: launchCommand,
        registration: registration
    )
}

private let testWorkspace = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let testPanel = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
private let expectedSessionName = "testagent-abc12345"

// MARK: - Tests

@Suite
struct RemoteHandoffRunnerTests {

    @Test
    func forkModeCreatesSessionAndFeedsForkStartupInput() async throws {
        let snapshot = testSnapshot()
        let tmux = RecordingTmux()
        let runner = RemoteHandoffRunner.make(
            request: RemoteHandoffRequest(workspaceId: testWorkspace, panelId: testPanel, mode: .fork),
            snapshot: snapshot,
            tmux: tmux
        )

        let result = try await runner.run()

        let expectedInput = try #require(
            snapshot.forkStartupInput(
                fileManager: .default,
                temporaryDirectory: FileManager.default.temporaryDirectory
            )
        )
        #expect(tmux.createdSessions.count == 1)
        #expect(tmux.createdSessions.first?.name == expectedSessionName)
        #expect(tmux.createdSessions.first?.workingDirectory == "/tmp/proj")
        #expect(tmux.sentKeys.count == 1)
        #expect(tmux.sentKeys.first?.target == expectedSessionName)
        #expect(tmux.sentKeys.first?.input == expectedInput.trimmingCharacters(in: .newlines))
        #expect(result.sessionName == expectedSessionName)
        #expect(result.workingDirectory == "/tmp/proj")
        #expect(result.sshCommand == "ssh <host> -t tmux attach -t \(expectedSessionName)")
    }

    @Test
    func handoffModeFeedsResumeStartupInput() async throws {
        let snapshot = testSnapshot()
        let tmux = RecordingTmux()
        let runner = RemoteHandoffRunner.make(
            request: RemoteHandoffRequest(workspaceId: testWorkspace, panelId: testPanel, mode: .handoff),
            snapshot: snapshot,
            tmux: tmux
        )

        let result = try await runner.run()

        let expectedInput = try #require(
            snapshot.resumeStartupInput(
                fileManager: .default,
                temporaryDirectory: FileManager.default.temporaryDirectory
            )
        )
        #expect(tmux.sentKeys.first?.input == expectedInput.trimmingCharacters(in: .newlines))
        #expect(result.sessionName == expectedSessionName)
    }

    @Test
    func customSessionNameIsHonored() async throws {
        let snapshot = testSnapshot()
        let tmux = RecordingTmux()
        let runner = RemoteHandoffRunner.make(
            request: RemoteHandoffRequest(
                workspaceId: testWorkspace,
                panelId: testPanel,
                mode: .fork,
                sessionName: "desk-agent"
            ),
            snapshot: snapshot,
            tmux: tmux
        )

        let result = try await runner.run()

        #expect(result.sessionName == "desk-agent")
        #expect(tmux.createdSessions.first?.name == "desk-agent")
        #expect(result.sshCommand == "ssh <host> -t tmux attach -t desk-agent")
    }

    @Test
    func sshHostAppearsInAttachLine() async throws {
        let snapshot = testSnapshot()
        let tmux = RecordingTmux()
        let runner = RemoteHandoffRunner.make(
            request: RemoteHandoffRequest(
                workspaceId: testWorkspace,
                panelId: testPanel,
                mode: .fork,
                sshHost: "desktop.local"
            ),
            snapshot: snapshot,
            tmux: tmux
        )

        let result = try await runner.run()

        #expect(result.sshCommand == "ssh desktop.local -t tmux attach -t \(expectedSessionName)")
    }

    @Test
    func workingDirectoryFallsBackToLaunchCommand() async throws {
        let launchCommand = AgentLaunchCommandSnapshot(
            launcher: nil,
            executablePath: nil,
            arguments: [],
            workingDirectory: "/tmp/launch",
            environment: nil,
            capturedAt: nil,
            source: nil
        )
        let snapshot = testSnapshot(workingDirectory: nil, launchCommand: launchCommand)
        let tmux = RecordingTmux()
        let runner = RemoteHandoffRunner.make(
            request: RemoteHandoffRequest(workspaceId: testWorkspace, panelId: testPanel, mode: .fork),
            snapshot: snapshot,
            tmux: tmux,
            homeDirectory: "/tmp/home"
        )

        let result = try await runner.run()

        #expect(result.workingDirectory == "/tmp/launch")
        #expect(tmux.createdSessions.first?.workingDirectory == "/tmp/launch")
    }

    @Test
    func workingDirectoryFallsBackToHomeWhenUnknown() async throws {
        let snapshot = testSnapshot(workingDirectory: nil, launchCommand: nil)
        let tmux = RecordingTmux()
        let runner = RemoteHandoffRunner.make(
            request: RemoteHandoffRequest(workspaceId: testWorkspace, panelId: testPanel, mode: .fork),
            snapshot: snapshot,
            tmux: tmux,
            homeDirectory: "/tmp/home"
        )

        let result = try await runner.run()

        #expect(result.workingDirectory == "/tmp/home")
        #expect(tmux.createdSessions.first?.workingDirectory == "/tmp/home")
    }

    @Test
    func noAgentDetectedThrowsBeforeAnyTmuxCall() async {
        let tmux = RecordingTmux()
        let runner = RemoteHandoffRunner.make(
            request: RemoteHandoffRequest(workspaceId: testWorkspace, panelId: testPanel, mode: .fork),
            snapshot: nil,
            tmux: tmux
        )

        await #expect(throws: RemoteHandoffError.self) {
            _ = try await runner.run()
        }
        #expect(tmux.createdSessions.isEmpty)
        #expect(tmux.sentKeys.isEmpty)
    }

    @Test
    func invalidRequestedSessionNameThrows() async {
        let snapshot = testSnapshot()
        let tmux = RecordingTmux()
        let runner = RemoteHandoffRunner.make(
            request: RemoteHandoffRequest(
                workspaceId: testWorkspace,
                panelId: testPanel,
                mode: .fork,
                sessionName: "bad.name"
            ),
            snapshot: snapshot,
            tmux: tmux
        )

        await #expect(throws: RemoteHandoffError.self) {
            _ = try await runner.run()
        }
        #expect(tmux.createdSessions.isEmpty)
    }

    @Test
    func sessionNameValidationRules() {
        #expect(!RemoteHandoffRunner.isValidSessionName("a.b"))
        #expect(!RemoteHandoffRunner.isValidSessionName("a:b"))
        #expect(!RemoteHandoffRunner.isValidSessionName("a b"))
        #expect(!RemoteHandoffRunner.isValidSessionName(""))
        #expect(RemoteHandoffRunner.isValidSessionName("pi-abc12345"))
        #expect(RemoteHandoffRunner.isValidSessionName("desk_agent"))
    }

    @Test
    func derivedSessionNameUsesAgentAndSessionPrefix() throws {
        let snapshot = testSnapshot(sessionId: "A1B2C3D4-ignored")
        let name = try RemoteHandoffRunner.resolveSessionName(requested: nil, snapshot: snapshot)
        // kind.rawValue "testagent" + "-" + first 8 chars lowercased.
        #expect(name == "testagent-a1b2c3d4")
    }
}
