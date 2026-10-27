import Foundation
import XCTest
@testable import BridgeCore

/// The command the user sets up in the bridge receives the meeting, so what
/// is tested first is that it runs exactly as configured — no shell, no
/// argument from Dicavo — and that its failures reach Dicavo the way Claude
/// Code's do, without the meeting in them.
final class BridgeLocalCommandTests: XCTestCase {
    // MARK: Configuration

    func testEachLineIsOneArgumentExactlyAsWritten() {
        let lines = "run\nllama3.2\r\n\n   \n--flag=a b;c\n$(touch pwned)\n'quoted' \"too\"\n"

        XCTAssertEqual(
            BridgeLocalCommandConfiguration.arguments(fromLines: lines),
            ["run", "llama3.2", "--flag=a b;c", "$(touch pwned)", "'quoted' \"too\""]
        )
        let arguments = ["run", " leading space", "x"]
        XCTAssertEqual(
            BridgeLocalCommandConfiguration.arguments(
                fromLines: BridgeLocalCommandConfiguration.lines(from: arguments)
            ),
            arguments
        )
    }

    func testTimeoutStaysWithinWhatDicavoWaitsFor() {
        XCTAssertEqual(BridgeLocalCommandConfiguration().timeoutSeconds, 600)
        XCTAssertEqual(BridgeLocalCommandConfiguration(timeoutSeconds: 1).timeoutSeconds, 10)
        XCTAssertEqual(BridgeLocalCommandConfiguration(timeoutSeconds: 5_000).timeoutSeconds, 600)
        XCTAssertEqual(BridgeLocalCommandConfiguration(timeoutSeconds: 120).timeout, .seconds(120))
    }

    func testAvailabilityLooksAtTheConfiguredPathItself() throws {
        let fixture = try makeExecutableFixture(script: "#!/bin/sh\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let plainFile = fixture.directory.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: plainFile)

        XCTAssertEqual(configuration(path: "").availability(), .notSetUp)
        XCTAssertEqual(configuration(path: "fake-cli").availability(), .notFound, "relative paths are never looked up")
        XCTAssertEqual(configuration(path: fixture.directory.appendingPathComponent("missing").path).availability(), .notFound)
        XCTAssertEqual(configuration(path: fixture.directory.path).availability(), .notExecutable)
        XCTAssertEqual(configuration(path: plainFile.path).availability(), .notExecutable)
        XCTAssertEqual(configuration(path: fixture.executable.path, enabled: false).availability(), .disabled)
        XCTAssertEqual(configuration(path: fixture.executable.path).availability(), .ready)
    }

    func testSettingsPersistInTheGivenDefaultsAndReadTolerantly() throws {
        let suiteName = "DicavoTests.BridgeLocalCommand.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BridgeLocalCommandStore(defaults: defaults)

        XCTAssertEqual(store.configuration, BridgeLocalCommandConfiguration())
        XCTAssertFalse(store.configuration.isEnabled, "a command is off until the user turns it on")

        store.save(BridgeLocalCommandConfiguration(
            executablePath: "  /opt/homebrew/bin/ollama\n",
            arguments: ["run", "llama3.2"],
            timeoutSeconds: 300,
            isEnabled: true
        ))
        XCTAssertEqual(
            BridgeLocalCommandStore(defaults: defaults).configuration,
            BridgeLocalCommandConfiguration(
                executablePath: "/opt/homebrew/bin/ollama",
                arguments: ["run", "llama3.2"],
                timeoutSeconds: 300,
                isEnabled: true
            )
        )

        // A value of the wrong shape costs that field only.
        defaults.set("not a list", forKey: "BridgeLocalCommandArguments")
        defaults.set("soon", forKey: "BridgeLocalCommandTimeoutSeconds")
        let tolerant = store.configuration
        XCTAssertEqual(tolerant.executablePath, "/opt/homebrew/bin/ollama")
        XCTAssertEqual(tolerant.arguments, [])
        XCTAssertEqual(tolerant.timeoutSeconds, 600)
        XCTAssertTrue(tolerant.isEnabled)
    }

    // MARK: Running, with a recorded runner

    func testTheCommandRunsAsConfiguredWithThePromptOnStandardInput() async throws {
        let fixture = try makeExecutableFixture(script: "#!/bin/sh\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = RecordingCommandRunner(result: AnalysisCommandResult(
            exitCode: 0,
            standardOutput: Data("\u{1B}[?25l\u{1B}[1m## Summary\u{1B}[0m\r\n- done\u{1B}]0;title\u{07}\n\n".utf8),
            standardError: Data()
        ))
        let configured = configuration(
            path: fixture.executable.path,
            arguments: ["run", "llama3.2", "a;b"],
            timeoutSeconds: 120
        )

        let markdown = try await BridgeLocalCommandRunner(configuration: configured, runner: runner)
            .run(promptText: "PROMPT\n[00:00:01] hello")

        XCTAssertEqual(markdown, "## Summary\n- done")
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.tool, .localCommand)
        XCTAssertEqual(call.command.executableURL.path, fixture.executable.path)
        XCTAssertEqual(call.command.arguments, ["run", "llama3.2", "a;b"])
        XCTAssertEqual(String(decoding: call.command.standardInput, as: UTF8.self), "PROMPT\n[00:00:01] hello")
        XCTAssertEqual(call.command.timeout, .seconds(120))
        XCTAssertNotEqual(call.command.currentDirectoryURL, fixture.directory)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: call.command.currentDirectoryURL.path),
            "the working directory is private to the run and removed after it"
        )
    }

    func testEmptyOrFormattingOnlyOutputIsAnEmptyAnalysis() async throws {
        let fixture = try makeExecutableFixture(script: "#!/bin/sh\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for output in ["", "\n  \n", "\u{1B}[?25l\n \u{1B}[?25h\n"] {
            let runner = RecordingCommandRunner(result: AnalysisCommandResult(
                exitCode: 0, standardOutput: Data(output.utf8), standardError: Data()
            ))
            do {
                _ = try await BridgeLocalCommandRunner(
                    configuration: configuration(path: fixture.executable.path), runner: runner
                ).run(promptText: "p")
                XCTFail("Expected an empty analysis for \(output.debugDescription).")
            } catch {
                XCTAssertEqual(error as? AnalysisError, .emptyOutput)
            }
        }
    }

    func testOversizedOutputIsRejected() async throws {
        let fixture = try makeExecutableFixture(script: "#!/bin/sh\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = RecordingCommandRunner(result: AnalysisCommandResult(
            exitCode: 0,
            standardOutput: Data(repeating: UInt8(ascii: "a"), count: AnalysisTransport.maximumMarkdownBytes + 1),
            standardError: Data()
        ))

        do {
            _ = try await BridgeLocalCommandRunner(
                configuration: configuration(path: fixture.executable.path), runner: runner
            ).run(promptText: "p")
            XCTFail("Expected the output to be too large.")
        } catch {
            XCTAssertEqual(error as? AnalysisError, .outputTooLarge)
        }
    }

    func testANonZeroExitCarriesTheLastErrorLineBounded() async throws {
        let fixture = try makeExecutableFixture(script: "#!/bin/sh\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let stderr = "\u{1B}[?25l⠙ pulling manifest\r⠹ pulling manifest\n\u{1B}[31mError: model 'llama9' not found\u{1B}[0m\n\n"
        let runner = RecordingCommandRunner(result: AnalysisCommandResult(
            exitCode: 1, standardOutput: Data("partial".utf8), standardError: Data(stderr.utf8)
        ))

        do {
            _ = try await BridgeLocalCommandRunner(
                configuration: configuration(path: fixture.executable.path), runner: runner
            ).run(promptText: "Summarize the meeting.")
            XCTFail("Expected the exit failure.")
        } catch {
            XCTAssertEqual(
                error as? AnalysisError,
                .processFailed(tool: .localCommand, exitCode: 1, message: "Error: model 'llama9' not found")
            )
        }

        let long = String(repeating: "x", count: 500)
        let bounded = BridgeLocalCommandRunner.diagnostic(fromStandardError: Data(long.utf8), promptText: "p")
        XCTAssertEqual(bounded, String(repeating: "x", count: 200) + "…")
        XCTAssertEqual(
            BridgeLocalCommandRunner.diagnostic(fromStandardError: Data(), promptText: "p"),
            "No diagnostic output."
        )
    }

    func testAnErrorLineThatRepeatsTheMeetingIsWithheld() {
        let prompt = "TRANSCRIPT\n[00:00:01] [segment-1] Other: The budget for Project Falcon is final.\n"
        for stderr in [
            "Traceback (most recent call last):\nValueError: cannot parse '[00:00:01] [segment-1] Other: The budget for'\n",
            "warning: the  BUDGET for project   falcon is final\n",
            "Project Falcon\n",
        ] {
            let message = BridgeLocalCommandRunner.diagnostic(fromStandardError: Data(stderr.utf8), promptText: prompt)
            XCTAssertEqual(
                message,
                "The command wrote \(Data(stderr.utf8).count) bytes to stderr; its content was not persisted.",
                stderr
            )
        }
        XCTAssertEqual(
            BridgeLocalCommandRunner.diagnostic(
                fromStandardError: Data("Error: connection refused\n".utf8), promptText: prompt
            ),
            "Error: connection refused"
        )
    }

    func testACommandThatCannotRunIsReportedBeforeAnythingStarts() async throws {
        let fixture = try makeExecutableFixture(script: "#!/bin/sh\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let plainFile = fixture.directory.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: plainFile)
        let missing = fixture.directory.appendingPathComponent("missing").path
        let cases: [(BridgeLocalCommandConfiguration, any Error & Equatable)] = [
            (configuration(path: ""), BridgeLocalCommandError.notSetUp),
            (configuration(path: fixture.executable.path, enabled: false), BridgeLocalCommandError.notSetUp),
            (configuration(path: missing), AnalysisError.executableNotFound(path: missing)),
            (configuration(path: plainFile.path), AnalysisError.executableNotRunnable(path: plainFile.path)),
        ]
        for (configured, expected) in cases {
            let runner = RecordingCommandRunner(result: AnalysisCommandResult(
                exitCode: 0, standardOutput: Data("ok".utf8), standardError: Data()
            ))
            do {
                _ = try await BridgeLocalCommandRunner(configuration: configured, runner: runner).run(promptText: "p")
                XCTFail("Expected \(expected).")
            } catch {
                XCTAssertEqual(String(describing: error), String(describing: expected))
            }
            let calls = await runner.calls
            XCTAssertTrue(calls.isEmpty, "nothing may start for \(expected)")
        }
    }

    // MARK: Running real processes

    func testArgumentsReachTheProcessVerbatimWithoutAShell() async throws {
        let fixture = try makeExecutableFixture(script: """
        #!/bin/sh
        /bin/cat > /dev/null
        for argument in "$@"; do
          printf '%s\\n' "$argument"
        done
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let marker = fixture.directory.appendingPathComponent("pwned").path
        let arguments = [
            "a;b", "$(touch \(marker))", "`touch \(marker)`", "*", "two words", "'single'", "\"double\"",
            "$HOME", "x|y", "> \(marker)",
        ]

        let output = try await BridgeLocalCommandRunner(
            configuration: configuration(path: fixture.executable.path, arguments: arguments),
            runner: AnalysisProcessRunner()
        ).run(promptText: "prompt")

        XCTAssertEqual(output, arguments.joined(separator: "\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "no shell may have interpreted an argument")
    }

    func testThePromptGoesInOnStandardInputAndTheAnswerComesFromStandardOutput() async throws {
        let output = try await BridgeLocalCommandRunner(
            configuration: configuration(path: "/usr/bin/tr", arguments: ["a-z", "A-Z"]),
            runner: AnalysisProcessRunner()
        ).run(promptText: "## summary\n- done\n")

        XCTAssertEqual(output, "## SUMMARY\n- DONE")
    }

    func testATimedOutCommandIsStoppedAndReportedAsTimedOut() async throws {
        let fixture = try makeExecutableFixture(script: """
        #!/bin/sh
        trap '' TERM
        while :; do
          /bin/sleep 0.1
        done
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await BridgeLocalCommandRunner(
                configuration: configuration(path: fixture.executable.path),
                runner: ShortTimeoutRunner(base: AnalysisProcessRunner(terminationGracePeriod: 0.05))
            ).run(promptText: "prompt")
            XCTFail("Expected a timeout.")
        } catch {
            XCTAssertEqual(error as? AnalysisError, .processTimedOut(tool: .localCommand))
        }
    }

    func testOutputBeyondTheCaptureCapIsRejected() async throws {
        let fixture = try makeExecutableFixture(script: """
        #!/bin/sh
        /bin/cat > /dev/null
        /usr/bin/head -c 1200000 /dev/zero | /usr/bin/tr '\\000' a
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await BridgeLocalCommandRunner(
                configuration: configuration(path: fixture.executable.path),
                runner: AnalysisProcessRunner()
            ).run(promptText: "prompt")
            XCTFail("Expected the output to be too large.")
        } catch {
            XCTAssertEqual(error as? AnalysisError, .outputTooLarge)
        }
    }

    func testAFailingCommandReportsItsExitCodeAndReason() async throws {
        let fixture = try makeExecutableFixture(script: """
        #!/bin/sh
        /bin/cat > /dev/null
        echo "Error: model 'nope' not found" >&2
        exit 3
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await BridgeLocalCommandRunner(
                configuration: configuration(path: fixture.executable.path),
                runner: AnalysisProcessRunner()
            ).run(promptText: "prompt")
            XCTFail("Expected the exit failure.")
        } catch {
            XCTAssertEqual(
                error as? AnalysisError,
                .processFailed(tool: .localCommand, exitCode: 3, message: "Error: model 'nope' not found")
            )
        }
    }

    // MARK: The bridge's tool runner

    func testTheBridgeListsTheCommandOnceSetUpAndOffersItOnlyWhenReady() async throws {
        let fixture = try makeExecutableFixture(script: "#!/bin/sh\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let suiteName = "DicavoTests.BridgeLocalCommand.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BridgeLocalCommandStore(defaults: defaults)
        // Claude Code and Codex, if installed here, are asked through this
        // runner and never actually started.
        let tools = CLIBridgeToolRunner(runner: FailingCommandRunner(), localCommands: store)

        var statuses = await tools.toolStatuses()
        XCTAssertNil(statuses.first { $0.tool == .localCommand }, "nothing to show until a path is entered")

        store.save(configuration(path: fixture.executable.path, enabled: false))
        statuses = await tools.toolStatuses()
        var local = try XCTUnwrap(statuses.first { $0.tool == .localCommand })
        XCTAssertEqual(local.localCommand, .disabled)
        XCTAssertEqual(local.executablePath, fixture.executable.path)
        XCTAssertFalse(local.isUsable)

        store.save(configuration(path: fixture.executable.path))
        statuses = await tools.toolStatuses()
        local = try XCTUnwrap(statuses.first { $0.tool == .localCommand })
        XCTAssertEqual(local.localCommand, .ready)
        XCTAssertTrue(local.isUsable)
        XCTAssertEqual(local.tool.rawValue, "local", "the name it is offered to Dicavo under")

        store.save(configuration(path: fixture.directory.appendingPathComponent("gone").path))
        statuses = await tools.toolStatuses()
        local = try XCTUnwrap(statuses.first { $0.tool == .localCommand })
        XCTAssertEqual(local.localCommand, .notFound)
        XCTAssertFalse(local.isUsable)
    }

    func testTheBridgeRunsTheSavedCommand() async throws {
        let suiteName = "DicavoTests.BridgeLocalCommand.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BridgeLocalCommandStore(defaults: defaults)
        let tools = CLIBridgeToolRunner(runner: AnalysisProcessRunner(), localCommands: store)

        do {
            _ = try await tools.run(tool: .localCommand, model: nil, promptText: "p")
            XCTFail("Expected the missing command to be reported.")
        } catch {
            XCTAssertEqual(error as? BridgeLocalCommandError, .notSetUp)
        }

        store.save(configuration(path: "/usr/bin/tr", arguments: ["a-z", "A-Z"]))
        let output = try await tools.run(tool: .localCommand, model: nil, promptText: "local answer")
        XCTAssertEqual(output, "LOCAL ANSWER")
    }

    // MARK: Routing and HTTP

    func testTheLocalModelIsRoutedToTheCommandAndTakesNoModelName() async throws {
        let runner = StubToolRunner(result: "## Local")
        let handler = BridgeRequestHandler(token: "secret", runner: runner)

        let response = await handler.handle(completionRequest(model: " local "))
        XCTAssertEqual(response.status, 200)
        var calls = await runner.calls
        XCTAssertEqual(calls.map(\.tool), [.localCommand])
        XCTAssertEqual(calls.map(\.model), [nil])

        let withModel = await handler.handle(completionRequest(model: "local:llama3.2"))
        XCTAssertEqual(withModel.status, 400, "nothing Dicavo sends may add to the configured command")
        calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(BridgeRequestHandler.parseModel("local:--evil"))
        XCTAssertEqual(BridgeRequestHandler.parseModel("local"), .init(tool: .localCommand, model: nil))
    }

    func testModelNameCannotCarryFlagsOrSplitArguments() {
        // A model that the CLI could read as another flag or a second argument.
        XCTAssertNil(BridgeRequestHandler.parseModel("agy:--x"))
        XCTAssertNil(BridgeRequestHandler.parseModel("claude:-m"))
        XCTAssertNil(BridgeRequestHandler.parseModel("codex:a b"))
        XCTAssertNil(BridgeRequestHandler.parseModel("codex:a\tb"))
        // Real model names still parse.
        XCTAssertEqual(BridgeRequestHandler.parseModel("claude:opus"), .init(tool: .claude, model: "opus"))
        XCTAssertEqual(BridgeRequestHandler.parseModel("codex:gpt-5.6-sol"), .init(tool: .codex, model: "gpt-5.6-sol"))
        XCTAssertEqual(BridgeRequestHandler.parseModel("agy:gemini-3-pro"), .init(tool: .antigravity, model: "gemini-3-pro"))
    }

    func testModelsListTheCommandOnlyWhenItCanRun() async throws {
        for (availability, expected) in [
            (BridgeLocalCommandAvailability.ready, ["claude", "local"]),
            (.disabled, ["claude"]),
            (.notFound, ["claude"]),
            (.notExecutable, ["claude"]),
        ] {
            let runner = StubToolRunner(statuses: [
                BridgeToolStatus(tool: .claude, executablePath: "/x/claude", version: "2.1", isAuthenticated: true, loginCommand: nil),
                BridgeToolStatus(
                    tool: .localCommand, executablePath: "/x/ollama", version: nil,
                    isAuthenticated: nil, loginCommand: nil, localCommand: availability
                ),
            ])
            let handler = BridgeRequestHandler(token: "secret", runner: runner)

            let response = await handler.handle(BridgeHTTPRequest(
                method: "GET", path: "/v1/models", headers: ["authorization": "Bearer secret"], body: Data()
            ))

            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            let data = try XCTUnwrap(object["data"] as? [[String: Any]])
            XCTAssertEqual(data.compactMap { $0["id"] as? String }, expected, "\(availability)")
        }
    }

    // MARK: Dicavo's side

    func testDicavoOffersTheLocalCommandAsABridgedModel() throws {
        XCTAssertEqual(
            AnalysisModelSelection.options(for: .dicavoBridge),
            [.bridgeClaude, .bridgeCodex, .bridgeAntigravity, .bridgeLocal, .custom]
        )
        XCTAssertEqual(AnalysisModelSelection.bridgeLocal.modelIdentifier, "local")
        XCTAssertEqual(AnalysisModelSelection.bridgeLocal.resolvedModel(customModel: "ignored"), "local")
        XCTAssertEqual(AnalysisModelSelection.selection(for: "local", tool: .dicavoBridge), .bridgeLocal)
        XCTAssertEqual(AnalysisTool(rawValue: "local"), .localCommand)
        XCTAssertFalse(AnalysisTool.allCases.contains(.localCommand), "reached only through the bridge")
        XCTAssertNil(AnalysisTool.dicavoBridge.proFeature, "free since 2.2")

        let decoded = try JSONDecoder().decode([AnalysisTool].self, from: Data(#"["local","fromTheFuture"]"#.utf8))
        XCTAssertEqual(decoded, [.localCommand, .unrecognized])
    }

    @MainActor
    func testTheNewTextsAreTranslated() throws {
        let bridgeKeys = [
            "Local command…", "Local command",
            "Local command: ready", "Local command: off", "Local command: not found",
            "Local command: not executable", "Local command: not set up",
            "Dicavo CLI Bridge can run one command of your choice for Dicavo, for example llm or ollama run with a model. The command receives the meeting transcript, notes and instructions on standard input and writes the analysis as Markdown to standard output. Dicavo cannot see what the command does with the transcript: if the command sends it to a server, that is where it goes.",
            "Enabled", "Executable", "Choose…", "Arguments",
            "One argument per line, passed exactly as written. There is no shell: quotes, variables and redirections have no special meaning.",
            "Timeout (seconds)", "At most %lld seconds, the longest Dicavo waits for one answer.",
            "Cancel", "Save",
            "Enter the full path of the program, for example /opt/homebrew/bin/ollama.",
            "There is no program at this path. Enter the full path, starting with /.",
            "This file cannot be run. Choose the program itself.",
            "Found and executable.",
            "No local command is set up and turned on in Dicavo CLI Bridge. Set one up with Local command… in the bridge's menu.",
        ]
        try assertTranslated(bridgeKeys, in: "Sources/DicavoBridge/Localizable.xcstrings")
    }

    // MARK: Helpers

    private func configuration(
        path: String,
        arguments: [String] = [],
        timeoutSeconds: Int = 60,
        enabled: Bool = true
    ) -> BridgeLocalCommandConfiguration {
        BridgeLocalCommandConfiguration(
            executablePath: path, arguments: arguments, timeoutSeconds: timeoutSeconds, isEnabled: enabled
        )
    }

    private func completionRequest(model: String) -> BridgeHTTPRequest {
        let body = try! JSONSerialization.data(withJSONObject: [
            "model": model, "messages": [["role": "user", "content": "x"]],
        ])
        return BridgeHTTPRequest(
            method: "POST", path: "/v1/chat/completions",
            headers: ["authorization": "Bearer secret", "content-type": "application/json"], body: body
        )
    }

    private func assertTranslated(_ keys: [String], in path: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = Self.repositoryRoot.appendingPathComponent(path)
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        for key in keys {
            let entry = strings[key] as? [String: Any]
            XCTAssertNotNil(entry, "\(path) has no entry for \(key)", file: file, line: line)
            let localizations = entry?["localizations"] as? [String: Any] ?? [:]
            for language in ["sk", "cs", "pl"] {
                let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String ?? ""
                XCTAssertFalse(value.isEmpty, "\(path): \(language) is missing for \(key)", file: file, line: line)
            }
        }
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func makeExecutableFixture(script: String) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DicavoLocalCommand-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let executable = directory.appendingPathComponent("fake-cli")
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (directory, executable)
    }
}

/// Records each command and answers with one canned result.
private actor RecordingCommandRunner: AnalysisCommandRunning {
    struct Call { let command: AnalysisCommand; let tool: AnalysisTool }

    private let result: AnalysisCommandResult
    private(set) var calls: [Call] = []

    init(result: AnalysisCommandResult) {
        self.result = result
    }

    func run(_ command: AnalysisCommand, tool: AnalysisTool) async throws -> AnalysisCommandResult {
        calls.append(Call(command: command, tool: tool))
        return result
    }
}

/// Fails every command, so a tool check finds Claude Code and Codex unusable
/// without starting either.
private struct FailingCommandRunner: AnalysisCommandRunning {
    func run(_ command: AnalysisCommand, tool: AnalysisTool) async throws -> AnalysisCommandResult {
        AnalysisCommandResult(exitCode: 1, standardOutput: Data(), standardError: Data())
    }
}

/// The production runner, with the command's timeout cut short: the local
/// command's own minimum is ten seconds.
private struct ShortTimeoutRunner: AnalysisCommandRunning {
    let base: AnalysisProcessRunner

    func run(_ command: AnalysisCommand, tool: AnalysisTool) async throws -> AnalysisCommandResult {
        try await base.run(
            AnalysisCommand(
                executableURL: command.executableURL,
                arguments: command.arguments,
                standardInput: command.standardInput,
                currentDirectoryURL: command.currentDirectoryURL,
                timeout: .milliseconds(200)
            ),
            tool: tool
        )
    }
}

private actor StubToolRunner: BridgeToolRunning {
    struct Call { let tool: AnalysisTool; let model: String?; let promptText: String }

    private let statuses: [BridgeToolStatus]
    private let result: String
    private let error: (any Error & Sendable)?
    private(set) var calls: [Call] = []

    init(statuses: [BridgeToolStatus] = [], result: String = "ok", error: (any Error & Sendable)? = nil) {
        self.statuses = statuses
        self.result = result
        self.error = error
    }

    func toolStatuses() async -> [BridgeToolStatus] { statuses }

    func run(tool: AnalysisTool, model: String?, promptText: String) async throws -> String {
        calls.append(Call(tool: tool, model: model, promptText: promptText))
        if let error { throw error }
        return result
    }
}
