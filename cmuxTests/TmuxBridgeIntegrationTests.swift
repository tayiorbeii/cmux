import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    /// Verify that `cmux hooks feed --source tmux-bridge --event bell` sends
    /// the correct notification.create_for_caller payload.
    func testTmuxBridgeFeedBellEventSendsCorrectNotificationPayload() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("tmux-bridge-bell")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            return self.v2Response(id: id, ok: true, result: [:])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "feed", "--source", "tmux-bridge",
                "--event", "bell",
                "--pane-id", "%1",
                "--pane-tty", "/dev/ttys001",
                "--session", "mysession",
                "--window", "0",
                "--pane", "0",
                "--command", "bash",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        // Verify notification payload
        let notificationPayloads = state.commands.filter { $0.contains(#""method":"notification.create_for_caller""#) }
        XCTAssertEqual(notificationPayloads.count, 1, "Expected exactly one notification.create_for_caller call, saw \(state.commands)")

        guard let raw = notificationPayloads.first,
              let payload = jsonObject(raw),
              let params = payload["params"] as? [String: Any] else {
            XCTFail("Expected notification.create_for_caller with params")
            return
        }

        // Title should be "AI alert" for bell event
        XCTAssertEqual(params["title"] as? String, "AI alert")

        // Body should contain the bell default message
        let body = params["body"] as? String ?? ""
        XCTAssertTrue(body.contains("Bell received from tmux"), "Body should contain bell message, got: \(body)")
        XCTAssertTrue(body.contains("Command: bash"), "Body should contain command, got: \(body)")
        XCTAssertTrue(body.contains("Pane: %1"), "Body should contain pane id, got: \(body)")

        // Subtitle should contain tmux session info
        let subtitle = params["subtitle"] as? String ?? ""
        XCTAssertTrue(subtitle.contains("mysession"), "Subtitle should contain session name, got: \(subtitle)")

        // Routing fields
        XCTAssertEqual(params["prefer_tty"] as? Bool, true)
        XCTAssertEqual(params["allow_selected_fallback"] as? Bool, false)

        // Tmux metadata
        XCTAssertEqual(params["tmux_pane_id"] as? String, "%1")
        XCTAssertEqual(params["tmux_pane_tty"] as? String, "/dev/ttys001")
        XCTAssertEqual(params["tmux_session"] as? String, "mysession")
        XCTAssertEqual(params["tmux_window"] as? String, "0")
        XCTAssertEqual(params["tmux_pane"] as? String, "0")
        XCTAssertEqual(params["tmux_command"] as? String, "bash")
    }

    /// Verify that `cmux hooks feed --source tmux-bridge --event silence` sends
    /// the correct localized title and body.
    func testTmuxBridgeFeedSilenceEventSendsWaitingTitle() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("tmux-bridge-silence")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            return self.v2Response(id: id, ok: true, result: [:])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "feed", "--source", "tmux-bridge",
                "--event", "silence",
                "--pane-id", "%1",
                "--session", "mysession",
                "--window", "0",
                "--pane", "0",
                "--command", "sleep",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let notificationPayloads = state.commands.filter { $0.contains(#""method":"notification.create_for_caller""#) }
        XCTAssertEqual(notificationPayloads.count, 1)

        guard let raw = notificationPayloads.first,
              let payload = jsonObject(raw),
              let params = payload["params"] as? [String: Any] else {
            XCTFail("Expected notification.create_for_caller with params")
            return
        }

        // Silence event should have "AI waiting" title
        XCTAssertEqual(params["title"] as? String, "AI waiting")
        let body = params["body"] as? String ?? ""
        XCTAssertTrue(body.contains("No output detected after"), "Body should mention silence threshold, got: \(body)")
    }

    /// Verify that `cmux hooks feed --source tmux-bridge --event activity` sends
    /// the correct localized title and body.
    func testTmuxBridgeFeedActivityEventSendsActiveTitle() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("tmux-bridge-activity")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            return self.v2Response(id: id, ok: true, result: [:])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "feed", "--source", "tmux-bridge",
                "--event", "activity",
                "--pane-id", "%1",
                "--session", "mysession",
                "--window", "0",
                "--pane", "0",
                "--command", "make",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let notificationPayloads = state.commands.filter { $0.contains(#""method":"notification.create_for_caller""#) }
        XCTAssertEqual(notificationPayloads.count, 1)

        guard let raw = notificationPayloads.first,
              let payload = jsonObject(raw),
              let params = payload["params"] as? [String: Any] else {
            XCTFail("Expected notification.create_for_caller with params")
            return
        }

        // Activity event should have "AI active" title
        XCTAssertEqual(params["title"] as? String, "AI active")
        let body = params["body"] as? String ?? ""
        XCTAssertTrue(body.contains("Output resumed"), "Body should mention output resuming, got: \(body)")
    }

    /// Verify unknown event types use a generic fallback title/body.
    func testTmuxBridgeFeedUnknownEventSendsGenericPayload() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("tmux-bridge-unknown")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            return self.v2Response(id: id, ok: true, result: [:])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "feed", "--source", "tmux-bridge",
                "--event", "custom-alert",
                "--pane-id", "%1",
                "--session", "mysession",
                "--window", "0",
                "--pane", "0",
                "--command", "mycmd",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let notificationPayloads = state.commands.filter { $0.contains(#""method":"notification.create_for_caller""#) }
        XCTAssertEqual(notificationPayloads.count, 1)

        guard let raw = notificationPayloads.first,
              let payload = jsonObject(raw),
              let params = payload["params"] as? [String: Any] else {
            XCTFail("Expected notification.create_for_caller with params")
            return
        }

        // Unknown event should use generic title
        XCTAssertEqual(params["title"] as? String, "tmux alert")
        let body = params["body"] as? String ?? ""
        XCTAssertTrue(body.contains("custom-alert"), "Body should contain event name for unknown events, got: \(body)")
    }

    /// Verify feed with explicit --message overrides the default body.
    func testTmuxBridgeFeedExplicitMessageOverridesBody() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("tmux-bridge-message")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            return self.v2Response(id: id, ok: true, result: [:])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "feed", "--source", "tmux-bridge",
                "--event", "bell",
                "--message", "Custom override message",
                "--pane-id", "%1",
                "--session", "mysession",
                "--window", "0",
                "--pane", "0",
                "--command", "bash",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let notificationPayloads = state.commands.filter { $0.contains(#""method":"notification.create_for_caller""#) }
        XCTAssertEqual(notificationPayloads.count, 1)

        guard let raw = notificationPayloads.first,
              let payload = jsonObject(raw),
              let params = payload["params"] as? [String: Any] else {
            XCTFail("Expected notification.create_for_caller with params")
            return
        }

        let body = params["body"] as? String ?? ""
        XCTAssertTrue(body.contains("Custom override message"), "Body should start with custom message, got: \(body)")
    }

    /// Verify that the feed command prints `{}` on success (the standard cmux hooks output).
    func testTmuxBridgeFeedPrintsEmptyJsonOnSuccess() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("tmux-bridge-output")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            return self.v2Response(id: id, ok: true, result: [:])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "feed", "--source", "tmux-bridge",
                "--event", "bell",
                "--pane-id", "%1",
                "--session", "mysession",
                "--window", "0",
                "--pane", "0",
                "--command", "bash",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n", "Expected empty JSON object on success")
    }

    /// Verify the feed noops and prints {} when running inside tmux without cmux
    /// workspace/surface scope (shouldNoopTmuxOnlyHook guard).
    func testTmuxBridgeFeedNoopsOutsideCmuxScope() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("tmux-bridge-noop")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            return self.v2Response(id: id, ok: true, result: [:])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        // Simulate running inside tmux but without cmux workspace/surface scope
        environment["TMUX"] = "/tmp/tmux-9999/default,1234,0"
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "feed", "--source", "tmux-bridge",
                "--event", "bell",
                "--pane-id", "%1",
                "--session", "mysession",
                "--window", "0",
                "--pane", "0",
                "--command", "bash",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        // When the noop guard fires, it prints {} and exits without calling the socket
        XCTAssertEqual(result.stdout, "{}\n", "Should noop and print empty JSON")
    }

    // MARK: - Test helpers are in CLINotifyProcessTestSupport.swift
}
