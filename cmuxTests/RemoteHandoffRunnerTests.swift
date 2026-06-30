import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

// MARK: - Test seams

/// Records tmux executable resolution instead of depending on a real process.
/// Single-threaded in tests, hence `@unchecked Sendable`.
private final class RecordingTmux: TmuxExecutableResolving, @unchecked Sendable {
    var executable: String
    var error: Error?
    private(set) var resolveCount = 0

    init(executable: String = "/opt/homebrew/bin/tmux", error: Error? = nil) {
        self.executable = executable
        self.error = error
    }

    func resolveExecutable() throws -> String {
        resolveCount += 1
        if let error { throw error }
        return executable
    }
}

// MARK: - Helpers

private extension RemoteHandoffRunner {
    static func make(
        request: RemoteHandoffRequest,
        tmux: RecordingTmux,
        homeDirectory: String = "/tmp/cmux-handoff-home"
    ) -> RemoteHandoffRunner {
        RemoteHandoffRunner(
            request: request,
            tmux: tmux,
            homeDirectory: homeDirectory
        )
    }
}

private let testWorkspace = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let testPanel = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
private let expectedSessionName = "cmux-11111111-22222222"

// MARK: - Tests

@Suite
struct RemoteHandoffRunnerTests {

    @Test
    func localFlowBuildsTmuxRelaunchCommandWithoutAgentSnapshot() async throws {
        let tmux = RecordingTmux()
        let runner = RemoteHandoffRunner.make(
            request: RemoteHandoffRequest(
                workspaceId: testWorkspace,
                panelId: testPanel,
                mode: .fork,
                workingDirectory: "/tmp/proj"
            ),
            tmux: tmux
        )

        let result = try await runner.run()

        #expect(tmux.resolveCount == 1)
        #expect(result.sessionName == expectedSessionName)
        #expect(result.workingDirectory == "/tmp/proj")
        #expect(result.localCommand == "exec /opt/homebrew/bin/tmux new-session -A -s \(expectedSessionName)")
        #expect(result.startupInput == result.localCommand)
        #expect(result.agentDisplayName == "tmux")
        #expect(result.sshCommand == nil)
    }

    @Test
    func handoffModeIsAcceptedAsCompatibilityNoOp() async throws {
        let tmux = RecordingTmux()
        let forkRunner = RemoteHandoffRunner.make(
            request: RemoteHandoffRequest(
                workspaceId: testWorkspace,
                panelId: testPanel,
                mode: .fork,
                workingDirectory: "/tmp/proj"
            ),
            tmux: tmux
        )
        let handoffRunner = RemoteHandoffRunner.make(
            request: RemoteHandoffRequest(
                workspaceId: testWorkspace,
                panelId: testPanel,
                mode: .handoff,
                workingDirectory: "/tmp/proj"
            ),
            tmux: tmux
        )

        let fork = try await forkRunner.run()
        let handoff = try await handoffRunner.run()

        #expect(fork.localCommand == handoff.localCommand)
        #expect(fork.sessionName == handoff.sessionName)
    }

    @Test
    func customSessionNameIsHonored() async throws {
        let tmux = RecordingTmux()
        let runner = RemoteHandoffRunner.make(
            request: RemoteHandoffRequest(
                workspaceId: testWorkspace,
                panelId: testPanel,
                mode: .fork,
                sessionName: "desk-agent",
                workingDirectory: "/tmp/proj"
            ),
            tmux: tmux
        )

        let result = try await runner.run()

        #expect(result.sessionName == "desk-agent")
        #expect(result.localCommand == "exec /opt/homebrew/bin/tmux new-session -A -s desk-agent")
    }

    @Test
    func sshHostAppearsOnlyWhenExplicitlyPassed() async throws {
        let tmux = RecordingTmux()
        let runner = RemoteHandoffRunner.make(
            request: RemoteHandoffRequest(
                workspaceId: testWorkspace,
                panelId: testPanel,
                mode: .fork,
                workingDirectory: "/tmp/proj",
                sshHost: "desktop.local"
            ),
            tmux: tmux
        )

        let result = try await runner.run()

        #expect(result.sshCommand == "ssh desktop.local -t tmux attach -t \(expectedSessionName)")
    }

    @Test
    func workingDirectoryFallsBackToHomeWhenUnknown() async throws {
        let tmux = RecordingTmux()
        let runner = RemoteHandoffRunner.make(
            request: RemoteHandoffRequest(workspaceId: testWorkspace, panelId: testPanel, mode: .fork),
            tmux: tmux,
            homeDirectory: "/tmp/home"
        )

        let result = try await runner.run()

        #expect(result.workingDirectory == "/tmp/home")
    }

    @Test
    func tmuxNotFoundThrowsBeforeCommandIsBuilt() async {
        let tmux = RecordingTmux(error: RemoteHandoffError.tmuxNotFound)
        let runner = RemoteHandoffRunner.make(
            request: RemoteHandoffRequest(workspaceId: testWorkspace, panelId: testPanel, mode: .fork),
            tmux: tmux
        )

        await #expect(throws: RemoteHandoffError.self) {
            _ = try await runner.run()
        }
        #expect(tmux.resolveCount == 1)
    }

    @Test
    func invalidRequestedSessionNameThrows() async {
        let tmux = RecordingTmux()
        let runner = RemoteHandoffRunner.make(
            request: RemoteHandoffRequest(
                workspaceId: testWorkspace,
                panelId: testPanel,
                mode: .fork,
                sessionName: "bad.name"
            ),
            tmux: tmux
        )

        await #expect(throws: RemoteHandoffError.self) {
            _ = try await runner.run()
        }
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
    func derivedSessionNameUsesWorkspaceAndPanelPrefixes() throws {
        let name = try RemoteHandoffRunner.resolveSessionName(
            requested: nil,
            workspaceId: testWorkspace,
            panelId: testPanel
        )
        #expect(name == expectedSessionName)
    }

    @Test
    func shellQuotingHandlesSpacesAndQuotes() {
        #expect(RemoteHandoffRunner.shellQuoted("/opt/homebrew/bin/tmux") == "/opt/homebrew/bin/tmux")
        #expect(RemoteHandoffRunner.shellQuoted("/tmp/tmux copy") == "'/tmp/tmux copy'")
        #expect(RemoteHandoffRunner.shellQuoted("it's") == "'it'\\''s'")
    }
}
