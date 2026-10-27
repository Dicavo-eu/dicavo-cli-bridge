import Foundation
import XCTest
@testable import BridgeCore

final class CLIAnalysisProviderTests: XCTestCase {
    func testCodexCandidatesPreferTheChatGPTBundleEntrypoint() {
        let paths = AnalysisExecutableResolver.candidates(for: .codex).map(\.path)

        XCTAssertEqual(paths.first, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        XCTAssertTrue(paths.contains("/Applications/ChatGPT.app/Contents/Resources/codex"))
    }

    func testCodexUsesStdinAndStructuredResponseFile() async throws {
        let runner = MockCLICommandRunner(markdown: "## Súhrn\n\nHotovo.")
        let provider = CLIAnalysisProvider(
            tool: .codex,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            model: "gpt-test",
            runner: runner
        )

        let response = try await provider.rawMarkdown(forPromptText: Self.promptText)

        XCTAssertEqual(response, "## Súhrn\n\nHotovo.")
        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.timeout, .seconds(600))
        XCTAssertTrue(command.arguments.contains("--ephemeral"))
        XCTAssertTrue(command.arguments.contains("read-only"))
        XCTAssertTrue(command.arguments.contains("gpt-test"))
        XCTAssertTrue(command.arguments.contains("--ignore-user-config"))
        for feature in CLIAnalysisProvider.codexDisabledFeatures {
            XCTAssertTrue(command.arguments.contains("features.\(feature)=false"), feature)
        }
        XCTAssertTrue(command.arguments.contains(#"web_search="disabled""#))
        XCTAssertFalse(command.arguments.contains("--disable"))
        XCTAssertFalse(command.arguments.contains("Meeting text"))
        let prompt = String(decoding: command.standardInput, as: UTF8.self)
        XCTAssertTrue(prompt.contains("Meeting text"))
    }

    func testClaudeDisablesToolsAndReadsStructuredOutput() async throws {
        let runner = MockCLICommandRunner(markdown: "## Custom\n\nA table can go here.")
        let provider = CLIAnalysisProvider(
            tool: .claude,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            model: "sonnet",
            runner: runner
        )

        let response = try await provider.rawMarkdown(forPromptText: Self.promptText)

        XCTAssertEqual(response, "## Custom\n\nA table can go here.")
        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.timeout, .seconds(600))
        XCTAssertTrue(command.arguments.contains("--no-session-persistence"))
        XCTAssertTrue(command.arguments.contains("--json-schema"))
        XCTAssertTrue(command.arguments.contains("--disable-slash-commands"))
        XCTAssertTrue(command.arguments.contains("--strict-mcp-config"))
        let toolsIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--tools"))
        XCTAssertEqual(command.arguments[toolsIndex + 1], "")
        let mcpIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--mcp-config"))
        XCTAssertEqual(command.arguments[mcpIndex + 1], #"{"mcpServers":{}}"#)
        let settingsIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--setting-sources"))
        XCTAssertEqual(command.arguments[settingsIndex + 1], "")
        let prompt = String(decoding: command.standardInput, as: UTF8.self)
    }

    func testNonzeroExitIncludesBoundedDiagnostic() async {
        let runner = MockCLICommandRunner(
            markdown: "Unused",
            exitCode: 7,
            standardError: "not authenticated"
        )
        let provider = CLIAnalysisProvider(
            tool: .claude,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner
        )

        do {
            _ = try await provider.rawMarkdown(forPromptText: Self.promptText)
            XCTFail("Expected process failure.")
        } catch {
            XCTAssertEqual(
                error as? AnalysisError,
                .processFailed(
                    tool: .claude,
                    exitCode: 7,
                    message: "The command wrote 17 bytes to stderr; its content was not persisted."
                )
            )
        }
    }

    func testClaudeExpiredTokenProvidesLoginInstructions() async {
        for exitCode: Int32 in [0, 1] {
            let provider = CLIAnalysisProvider(
                tool: .claude,
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                runner: RawClaudeResultRunner(
                    exitCode: exitCode,
                    output: #"{"is_error":true,"api_error_status":401,"result":"OAuth access token has expired. private-content"}"#
                )
            )
            do {
                _ = try await provider.rawMarkdown(forPromptText: Self.promptText)
                XCTFail("Expected authentication failure.")
            } catch {
                XCTAssertEqual(error as? AnalysisError, .authenticationRequired(
                    tool: .claude, loginCommand: "'/bin/echo' auth login"
                ))
                XCTAssertFalse(error.localizedDescription.contains("private-content"))
            }
        }
    }

    func testClaudeExpiredOAuthSessionWithoutStatusProvidesLoginInstructions() async {
        let provider = CLIAnalysisProvider(
            tool: .claude,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: RawClaudeResultRunner(
                exitCode: 1,
                output: #"{"is_error":true,"api_error_status":null,"result":"Failed to authenticate: OAuth session expired and could not be refreshed","terminal_reason":"api_error"}"#
            )
        )
        do {
            _ = try await provider.rawMarkdown(forPromptText: Self.promptText)
            XCTFail("Expected authentication failure.")
        } catch {
            XCTAssertEqual(error as? AnalysisError, .authenticationRequired(
                tool: .claude, loginCommand: "'/bin/echo' auth login"
            ))
        }
    }

    func testClaudeOtherAPIErrorDoesNotRequestLoginOrLeakOutput() async {
        let provider = CLIAnalysisProvider(
            tool: .claude,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: RawClaudeResultRunner(
                exitCode: 0,
                output: #"{"is_error":true,"api_error_status":429,"result":"private-content"}"#
            )
        )
        do {
            _ = try await provider.rawMarkdown(forPromptText: Self.promptText)
            XCTFail("Expected API failure.")
        } catch {
            XCTAssertEqual(error as? AnalysisError, .processFailed(
                tool: .claude, exitCode: 0, message: "Claude reported an API error (HTTP 429)."
            ))
        }
    }

    func testClaudeUsageLimitPassesItsOwnReasonOn() async {
        let provider = CLIAnalysisProvider(
            tool: .claude,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: RawClaudeResultRunner(
                exitCode: 0,
                output: #"{"is_error":true,"api_error_status":429,"result":"You've hit your org's monthly spend limit · run /usage-credits to ask your admin for a higher limit"}"#
            )
        )
        do {
            _ = try await provider.rawMarkdown(forPromptText: Self.promptText)
            XCTFail("Expected API failure.")
        } catch {
            XCTAssertEqual(error as? AnalysisError, .processFailed(
                tool: .claude, exitCode: 0,
                message: "Claude reported an API error (HTTP 429): You've hit your org's monthly spend limit · run /usage-credits to ask your admin for a higher limit"
            ))
        }
    }

    func testVersionUsesOnlyVersionArgument() async throws {
        let runner = MockCLICommandRunner(markdown: "Unused", version: "codex-cli 1.2.3")
        let provider = CLIAnalysisProvider(
            tool: .codex,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner
        )

        let version = try await provider.toolVersion()
        XCTAssertEqual(version, "codex-cli 1.2.3")
        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.arguments, ["--version"])
        XCTAssertTrue(command.standardInput.isEmpty)
    }

    func testCodexAuthenticationStatusUsesLoginStatusCommand() async throws {
        let runner = MockCLICommandRunner(
            markdown: "Unused",
            codexAuthenticated: false
        )
        let provider = CLIAnalysisProvider(
            tool: .codex,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner
        )

        let status = try await provider.authenticationStatus()

        XCTAssertEqual(status, .authenticationRequired)
        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.arguments, ["login", "status"])
        XCTAssertTrue(command.standardInput.isEmpty)
    }

    func testClaudeAuthenticationStatusReadsOnlyLoggedInFlag() async throws {
        let runner = MockCLICommandRunner(
            markdown: "Unused",
            claudeLoggedIn: true
        )
        let provider = CLIAnalysisProvider(
            tool: .claude,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner
        )

        let status = try await provider.authenticationStatus()

        XCTAssertEqual(status, .authenticated)
        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.arguments, ["auth", "status"])
        XCTAssertTrue(command.standardInput.isEmpty)
    }

    func testLoginCommandsUseSelectedExecutableWithoutShellInterpolation() {
        XCTAssertEqual(
            AnalysisTool.codex.loginCommand(
                executableURL: URL(fileURLWithPath: "/Applications/Codex CLI/codex")
            ),
            "'/Applications/Codex CLI/codex' login"
        )
        XCTAssertEqual(
            AnalysisTool.claude.loginCommand(
                executableURL: URL(fileURLWithPath: "/Users/test/claude")
            ),
            "'/Users/test/claude' auth login"
        )
    }

    func testProductionRunnerExecutesFakeCodexWithoutShellWrapping() async throws {
        let fixture = try makeExecutableFixture(script: """
        #!/bin/sh
        # Consume the prompt the way the real CLI does. Exiting without
        # draining stdin lets the runner's write race the child's exit, which
        # fails with EPIPE on a loaded machine instead of testing anything.
        /bin/cat > /dev/null
        if [ "$1" = "--version" ]; then
          printf 'fake-codex 1.0'
          exit 0
        fi
        output=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output-last-message" ]; then
            shift
            output="$1"
          fi
          shift
        done
        printf '%s' '{"markdown":"## Fake CLI\\n\\nCompleted."}' > "$output"
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let provider = CLIAnalysisProvider(
            tool: .codex,
            executableURL: fixture.executable,
            runner: AnalysisProcessRunner(),
            // Generous: this test asserts arguments and output, never latency.
            // A tight budget only turns runner contention into a false failure.
            requestTimeout: .seconds(60)
        )

        let response = try await provider.rawMarkdown(forPromptText: Self.promptText)

        XCTAssertEqual(response, "## Fake CLI\n\nCompleted.")
        let version = try await provider.toolVersion()
        XCTAssertEqual(version, "fake-codex 1.0")
    }

    func testProductionRunnerExecutesClaudeWithRequiredSafetyArguments() async throws {
        let fixture = try makeExecutableFixture(script: """
        #!/bin/sh
        # Consume the prompt the way the real CLI does. Exiting without
        # draining stdin lets the runner's write race the child's exit, which
        # fails with EPIPE on a loaded machine instead of testing anything.
        /bin/cat > /dev/null
        saw_print=0
        saw_input=0
        saw_output=0
        saw_schema=0
        saw_no_session=0
        saw_tools=0
        saw_permission=0
        saw_disable_slash=0
        saw_strict_mcp=0
        saw_mcp_config=0
        saw_setting_sources=0
        saw_model=0
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --print) saw_print=1 ;;
            --input-format) shift; [ "$1" = text ] || exit 64; saw_input=1 ;;
            --output-format) shift; [ "$1" = json ] || exit 64; saw_output=1 ;;
            --json-schema) shift; [ -n "$1" ] || exit 64; saw_schema=1 ;;
            --no-session-persistence) saw_no_session=1 ;;
            --tools) shift; [ -z "$1" ] || exit 64; saw_tools=1 ;;
            --permission-mode) shift; [ "$1" = dontAsk ] || exit 64; saw_permission=1 ;;
            --disable-slash-commands) saw_disable_slash=1 ;;
            --strict-mcp-config) saw_strict_mcp=1 ;;
            --mcp-config) shift; [ "$1" = '{"mcpServers":{}}' ] || exit 64; saw_mcp_config=1 ;;
            --setting-sources) shift; [ -z "$1" ] || exit 64; saw_setting_sources=1 ;;
            --model) shift; [ "$1" = sonnet-test ] || exit 64; saw_model=1 ;;
            *) exit 64 ;;
          esac
          shift
        done
        [ "$saw_print$saw_input$saw_output$saw_schema$saw_no_session$saw_tools$saw_permission$saw_disable_slash$saw_strict_mcp$saw_mcp_config$saw_setting_sources$saw_model" = 111111111111 ] || exit 64
        printf '%s' '{"structured_output":{"markdown":"## Fake Claude\\n\\nCompleted."}}'
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let provider = CLIAnalysisProvider(
            tool: .claude,
            executableURL: fixture.executable,
            model: "sonnet-test",
            runner: AnalysisProcessRunner(),
            // Generous: this test asserts arguments and output, never latency.
            // A tight budget only turns runner contention into a false failure.
            requestTimeout: .seconds(60)
        )

        let response = try await provider.rawMarkdown(forPromptText: Self.promptText)

        XCTAssertEqual(response, "## Fake Claude\n\nCompleted.")
    }

    func testProductionRunnerTerminatesTimedOutProcess() async throws {
        let fixture = try makeExecutableFixture(script: """
        #!/bin/sh
        trap '' TERM
        while :; do
          /bin/sleep 0.1
        done
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = AnalysisProcessRunner(terminationGracePeriod: 0.05)

        do {
            _ = try await runner.run(
                AnalysisCommand(
                    executableURL: fixture.executable,
                    arguments: [],
                    standardInput: Data(),
                    currentDirectoryURL: fixture.directory,
                    timeout: .milliseconds(20)
                ),
                tool: .codex
            )
            XCTFail("Expected timeout.")
        } catch {
            XCTAssertEqual(error as? AnalysisError, .processTimedOut(tool: .codex))
        }
    }

    func testProductionRunnerCancellationTerminatesTermIgnoringProcess() async throws {
        let fixture = try makeExecutableFixture(script: """
        #!/bin/sh
        trap '' TERM
        : > ready
        while :; do
          /bin/sleep 0.1
        done
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = AnalysisProcessRunner(terminationGracePeriod: 0.05)
        let task = Task {
            try await runner.run(
                AnalysisCommand(
                    executableURL: fixture.executable,
                    arguments: [],
                    standardInput: Data(repeating: 65, count: 128 * 1_024),
                    currentDirectoryURL: fixture.directory,
                    timeout: .seconds(5)
                ),
                tool: .codex
            )
        }
        try await waitForFile(fixture.directory.appendingPathComponent("ready"))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to terminate the owned process.")
        } catch is CancellationError {}
    }

    /// A tool that leaves a child of its own running: the timeout still ends
    /// the run within the grace period, and the child does not outlive it.
    /// Foundation starts the tool as the leader of its own process group,
    /// and the whole group is signalled.
    func testProductionRunnerTimeoutEndsTheToolsOwnChildToo() async throws {
        let fixture = try makeExecutableFixture(script: """
        #!/bin/sh
        /bin/sleep 30 &
        echo $! > grandchild.pid
        wait
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = AnalysisProcessRunner(terminationGracePeriod: 0.5)
        let started = ContinuousClock.now

        do {
            _ = try await runner.run(
                AnalysisCommand(
                    executableURL: fixture.executable,
                    arguments: [],
                    standardInput: Data(),
                    currentDirectoryURL: fixture.directory,
                    // Long enough for the script to start its child and
                    // record it: a new script took up to about 0.55 s here.
                    timeout: .seconds(2)
                ),
                tool: .codex
            )
            XCTFail("Expected timeout.")
        } catch {
            XCTAssertEqual(error as? AnalysisError, .processTimedOut(tool: .codex))
        }
        // Well short of the child's 30 s.
        XCTAssertLessThan(
            ContinuousClock.now - started, .seconds(10),
            "a child holding the pipes must not keep a timed-out run waiting"
        )

        let recorded = try String(
            contentsOf: fixture.directory.appendingPathComponent("grandchild.pid"), encoding: .utf8
        )
        let pid = try XCTUnwrap(pid_t(recorded.trimmingCharacters(in: .whitespacesAndNewlines)))
        // Orphaned and reaped by launchd; a zombie still answers for a moment.
        var isAlive = true
        for _ in 0..<50 {
            if kill(pid, 0) != 0 {
                isAlive = false
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        if isAlive { kill(pid, SIGKILL) }
        XCTAssertFalse(isAlive, "the tool's own child must not outlive the timeout")
    }

    func testProductionRunnerReportsExitCodeWhenToolExitsWithoutReadingStdin() async throws {
        let fixture = try makeExecutableFixture(script: """
        #!/bin/sh
        echo 'fake-cli: unrecognized arguments' >&2
        exit 64
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let provider = CLIAnalysisProvider(
            tool: .claude,
            executableURL: fixture.executable,
            runner: AnalysisProcessRunner(terminationGracePeriod: 0.05),
            requestTimeout: .seconds(10)
        )

        do {
            // The prompt exceeds the pipe buffer, so the tool exiting without
            // draining stdin always breaks the write the runner is still doing.
            _ = try await provider.rawMarkdown(forPromptText: String(repeating: "[00:00:01] [segment-1] Other: Meeting text\n", count: 8_000))
            XCTFail("Expected the tool's own failure to surface.")
        } catch let error as AnalysisError {
            guard case let .processFailed(tool, exitCode, message) = error else {
                XCTFail("Expected processFailed, got \(error).")
                return
            }
            XCTAssertEqual(tool, .claude)
            XCTAssertEqual(exitCode, 64)
            XCTAssertTrue(message.contains("stderr"), message)
        }
    }

    /// What Dicavo sends the bridge: the prompt it built, transcript included.
    private static let promptText = "Summarize the meeting.\n\n[00:00:01] [segment-1] Other: Meeting text"

    /// A process spawned while Xcode runs several test processes in parallel
    /// can take well over a second to write its first file; one second was
    /// the limit when this failed under load and passed alone.
    private func waitForFile(_ url: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "CLIAnalysisProviderTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for controlled process readiness."]
        )
    }

    func testStdoutArrivingInManyPiecesIsReassembledInOrder() async throws {
        // The captured output used to be read by two readers at once: a
        // readability handler that had been cleared but was still running,
        // and a `readDataToEndOfFile()` on the same descriptor. Both appended
        // under the buffer's lock, so nothing was corrupted — but the order
        // was the scheduler's choice. It showed up as a rare CI failure on
        // `--version`, whose fourteen bytes only occasionally split across
        // two reads.
        //
        // This writes the version in many small pieces with pauses between
        // them, so it is split every time rather than once in a hundred runs.
        let expected = (0..<40).map { "part\($0)" }.joined(separator: "-")
        let fixture = try makeExecutableFixture(script: """
        #!/bin/sh
        /bin/cat > /dev/null
        if [ "$1" = "--version" ]; then
          i=0
          while [ "$i" -lt 40 ]; do
            if [ "$i" -gt 0 ]; then printf -- '-'; fi
            printf 'part%s' "$i"
            i=$((i + 1))
            sleep 0.01
          done
          exit 0
        fi
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let provider = CLIAnalysisProvider(
            tool: .codex,
            executableURL: fixture.executable,
            runner: AnalysisProcessRunner(),
            requestTimeout: .seconds(60)
        )

        // Repeated because an ordering race does not have to lose every time.
        for attempt in 1...5 {
            let version = try await provider.toolVersion()
            XCTAssertEqual(version, expected, "attempt \(attempt)")
        }
    }

    func testCappedDataBufferTailModeKeepsNewestBytes() {
        let tail = CappedDataBuffer(limit: 10, retention: .tail)
        tail.append(Data("0123456789".utf8))
        tail.append(Data("ABCDE".utf8))
        XCTAssertEqual(tail.value, Data("56789ABCDE".utf8))

        let head = CappedDataBuffer(limit: 10)
        head.append(Data("0123456789".utf8))
        head.append(Data("ABCDE".utf8))
        XCTAssertEqual(head.value, Data("0123456789".utf8))
    }

    /// A long NDJSON stream must not push the final `result` line out of the
    /// captured stdout: for .antigravity the buffer keeps the newest bytes.
    /// The tail floor is 4 MB, so the stream has to exceed that.
    func testProductionRunnerKeepsTailOfAntigravityOutput() async throws {
        let script = """
        #!/bin/sh
        /usr/bin/yes "event line padding padding" | /usr/bin/head -n 200000
        echo '{"event":"result","status":"SUCCESS"}'
        """
        let fixture = try makeExecutableFixture(script: script)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = AnalysisProcessRunner(maximumCapturedBytes: 1_024)

        let result = try await runner.run(
            AnalysisCommand(
                executableURL: fixture.executable,
                arguments: [],
                standardInput: Data(),
                currentDirectoryURL: fixture.directory,
                timeout: .seconds(30)
            ),
            tool: .antigravity
        )

        let output = String(decoding: result.standardOutput, as: UTF8.self)
        XCTAssertTrue(
            output.contains(#"{"event":"result","status":"SUCCESS"}"#),
            "the final result line was dropped from a stream over the cap"
        )
        // The tail keeps the end within the 4 MB floor, not the whole stream.
        XCTAssertLessThanOrEqual(result.standardOutput.count, 4_000_000)
    }

    /// Every other tool keeps the head of the stream, as before.
    func testProductionRunnerKeepsHeadOfNonAntigravityOutput() async throws {
        let script = """
        #!/bin/sh
        i=0
        while [ $i -lt 3000 ]; do
          echo "event line $i padding padding"
          i=$((i+1))
        done
        echo '{"event":"result","status":"SUCCESS"}'
        """
        let fixture = try makeExecutableFixture(script: script)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = AnalysisProcessRunner(maximumCapturedBytes: 1_024)

        let result = try await runner.run(
            AnalysisCommand(
                executableURL: fixture.executable,
                arguments: [],
                standardInput: Data(),
                currentDirectoryURL: fixture.directory,
                timeout: .seconds(30)
            ),
            tool: .codex
        )

        let output = String(decoding: result.standardOutput, as: UTF8.self)
        XCTAssertTrue(output.contains("event line 0 padding"))
        XCTAssertFalse(
            output.contains(#"{"event":"result","status":"SUCCESS"}"#),
            "a non-antigravity tool must still keep the head of the stream"
        )
    }

    private func makeExecutableFixture(
        script: String
    ) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DicavoFakeCLI-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let executable = directory.appendingPathComponent("fake-cli")
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        return (directory, executable)
    }
}

private actor MockCLICommandRunner: AnalysisCommandRunning {
    private let markdown: String
    private let exitCode: Int32
    private let standardError: String
    private let version: String
    private let codexAuthenticated: Bool
    private let claudeLoggedIn: Bool
    private(set) var commands: [AnalysisCommand] = []

    init(
        markdown: String,
        exitCode: Int32 = 0,
        standardError: String = "",
        version: String = "test-cli 1.0",
        codexAuthenticated: Bool = true,
        claudeLoggedIn: Bool = true
    ) {
        self.markdown = markdown
        self.exitCode = exitCode
        self.standardError = standardError
        self.version = version
        self.codexAuthenticated = codexAuthenticated
        self.claudeLoggedIn = claudeLoggedIn
    }

    func run(
        _ command: AnalysisCommand,
        tool: AnalysisTool
    ) async throws -> AnalysisCommandResult {
        commands.append(command)
        if command.arguments == ["--version"] {
            return AnalysisCommandResult(
                exitCode: exitCode,
                standardOutput: Data(version.utf8),
                standardError: Data(standardError.utf8)
            )
        }
        if command.arguments == ["login", "status"] {
            return AnalysisCommandResult(
                exitCode: codexAuthenticated ? 0 : 1,
                standardOutput: Data(),
                standardError: Data()
            )
        }
        if command.arguments == ["auth", "status"] {
            let output = try JSONSerialization.data(
                withJSONObject: [
                    "loggedIn": claudeLoggedIn,
                    "email": "must-not-be-used@example.com",
                ]
            )
            return AnalysisCommandResult(
                exitCode: 0,
                standardOutput: output,
                standardError: Data()
            )
        }

        let response = try JSONEncoder().encode(AnalysisMarkdown(markdown: markdown))
        if tool == .codex,
           let index = command.arguments.firstIndex(of: "--output-last-message"),
           command.arguments.indices.contains(index + 1) {
            try response.write(
                to: URL(fileURLWithPath: command.arguments[index + 1]),
                options: .atomic
            )
        }
        let output: Data
        if tool == .claude {
            output = try JSONSerialization.data(
                withJSONObject: [
                    "structured_output": ["markdown": markdown],
                ]
            )
        } else {
            output = Data()
        }
        return AnalysisCommandResult(
            exitCode: exitCode,
            standardOutput: output,
            standardError: Data(standardError.utf8)
        )
    }
}


private struct RawClaudeResultRunner: AnalysisCommandRunning {
    let exitCode: Int32
    let output: String

    func run(_ command: AnalysisCommand, tool: AnalysisTool) async throws -> AnalysisCommandResult {
        AnalysisCommandResult(
            exitCode: exitCode, standardOutput: Data(output.utf8), standardError: Data()
        )
    }
}
