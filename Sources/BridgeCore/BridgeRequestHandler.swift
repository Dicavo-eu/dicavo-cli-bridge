import Foundation

/// One command-line tool as the bridge found it.
struct BridgeToolStatus: Equatable, Sendable {
    let tool: AnalysisTool
    let executablePath: String?
    let version: String?
    /// `nil` when the executable is missing; otherwise whether the cached
    /// sign-in is usable.
    let isAuthenticated: Bool?
    let loginCommand: String?
    /// Only for the local command, which has no sign-in and is reported even
    /// when it cannot run, so the menu can say why; its `executablePath` is
    /// then the configured path whether or not anything is there. `nil` for
    /// Claude Code and Codex.
    var localCommand: BridgeLocalCommandAvailability? = nil

    var isUsable: Bool {
        if let localCommand { return localCommand == .ready }
        return executablePath != nil && isAuthenticated == true
    }
}

/// What the handler asks of the machine: which tools exist, and run one.
/// A stub in tests; `CLIBridgeToolRunner` in the bridge.
protocol BridgeToolRunning: Sendable {
    func toolStatuses() async -> [BridgeToolStatus]
    func run(tool: AnalysisTool, model: String?, promptText: String) async throws -> String
}

/// Turns HTTP requests in the OpenAI chat-completions shape into runs of the
/// local command-line tools, and their outcomes back into responses Dicavo's
/// `HTTPAnalysisProvider` already understands.
///
/// The dialect is borrowed, not the semantics: there is no streaming, no
/// temperature, no tools, no system role of its own. The messages are
/// concatenated in order into one prompt, because that is what Dicavo sends
/// and what the CLI tools read from standard input.
struct BridgeRequestHandler: Sendable {
    /// The tools this bridge exists for: the two command-line tools and the
    /// one command the user set up in the bridge. The API tools do not need
    /// a bridge and the on-device model has no CLI.
    static let bridgedTools: [AnalysisTool] = [.claude, .codex, .antigravity, .localCommand]

    let token: String
    let runner: any BridgeToolRunning

    init(token: String, runner: any BridgeToolRunning) {
        self.token = token
        self.runner = runner
    }

    /// Whether a request presents this launch's token. Used on the headers
    /// alone, before any body is read.
    func isAuthorized(_ request: BridgeHTTPRequest) -> Bool {
        guard let presented = request.bearerToken else { return false }
        return Self.tokensMatch(presented, token)
    }

    func handle(_ request: BridgeHTTPRequest) async -> BridgeHTTPResponse {
        guard isAuthorized(request) else {
            return Self.error(status: 401, type: "authentication_error", message: "Missing or invalid bridge token.")
        }
        switch (request.method, request.path) {
        case ("GET", "/v1/models"), ("GET", "/models"):
            return await listModels()
        case ("POST", "/v1/chat/completions"), ("POST", "/chat/completions"):
            return await complete(request)
        case (_, "/v1/models"), (_, "/models"), (_, "/v1/chat/completions"), (_, "/chat/completions"):
            return Self.error(status: 405, type: "invalid_request_error", message: "Method not allowed.")
        default:
            return Self.error(status: 404, type: "not_found_error", message: "Unknown path.")
        }
    }

    // MARK: Routes

    private func listModels() async -> BridgeHTTPResponse {
        let statuses = await runner.toolStatuses()
        let models: [[String: Any]] = statuses.filter(\.isUsable).map { status in
            [
                "id": status.tool.rawValue,
                "object": "model",
                "owned_by": "dicavo-bridge",
                "version": status.version ?? "",
            ]
        }
        return .json(status: 200, object: ["object": "list", "data": models])
    }

    private func complete(_ request: BridgeHTTPRequest) async -> BridgeHTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return Self.error(status: 400, type: "invalid_request_error", message: "The body is not a JSON object.")
        }
        if let stream = object["stream"] as? Bool, stream {
            return Self.error(status: 400, type: "invalid_request_error", message: "Streaming is not supported.")
        }
        guard let modelName = object["model"] as? String,
              let selection = Self.parseModel(modelName) else {
            return Self.error(
                status: 400,
                type: "invalid_request_error",
                message: "Unknown model. Use \"claude\", \"codex\", \"local\", or \"claude:<model>\" / \"codex:<model>\"."
            )
        }
        guard let messages = object["messages"] as? [[String: Any]], !messages.isEmpty else {
            return Self.error(status: 400, type: "invalid_request_error", message: "messages must be a non-empty array.")
        }
        let prompt = Self.promptText(from: messages)
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.error(status: 400, type: "invalid_request_error", message: "messages carry no text.")
        }

        do {
            let markdown = try await runner.run(
                tool: selection.tool,
                model: selection.model,
                promptText: prompt
            )
            return .json(status: 200, object: [
                "id": "chatcmpl-\(UUID().uuidString.lowercased())",
                "object": "chat.completion",
                "created": Int(Date().timeIntervalSince1970),
                "model": modelName,
                "choices": [[
                    "index": 0,
                    "message": ["role": "assistant", "content": markdown],
                    "finish_reason": "stop",
                ]],
            ])
        } catch is CancellationError {
            return Self.error(status: 499, type: "cancelled", message: "The request was cancelled.")
        } catch let error as AnalysisError {
            return Self.response(for: error)
        } catch let error as BridgeLocalCommandError {
            return Self.error(
                status: 503,
                type: "tool_unavailable",
                message: error.errorDescription ?? "The local command is not set up."
            )
        } catch {
            return Self.error(status: 502, type: "cli_error", message: "The tool failed: \(type(of: error))")
        }
    }

    // MARK: Mapping

    struct ModelSelection: Equatable {
        let tool: AnalysisTool
        let model: String?
    }

    /// `claude`, `codex`, or either followed by `:` and the tool's own model
    /// name (`claude:opus`, `codex:gpt-5.6-sol`); or `local`, alone.
    static func parseModel(_ name: String) -> ModelSelection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = parts.first, let tool = AnalysisTool(rawValue: first), bridgedTools.contains(tool) else {
            return nil
        }
        let model = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        // The model goes to the tool's CLI as a single argv value; a leading
        // dash or a whitespace/control character could be read there as an
        // extra flag or split argument.
        if model.hasPrefix("-") {
            return nil
        }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        if model.unicodeScalars.contains(where: { forbidden.contains($0) }) {
            return nil
        }
        // The local command runs exactly as it was set up in the bridge.
        // Nothing Dicavo sends may add to it, not even a model name.
        if tool == .localCommand, !model.isEmpty { return nil }
        return ModelSelection(tool: tool, model: model.isEmpty ? nil : model)
    }

    /// Concatenates message contents in order. A content may be a string or
    /// the array-of-parts form; only `text` parts are read.
    static func promptText(from messages: [[String: Any]]) -> String {
        messages.compactMap { message -> String? in
            if let text = message["content"] as? String { return text }
            if let parts = message["content"] as? [[String: Any]] {
                let texts = parts.compactMap { part -> String? in
                    guard (part["type"] as? String) == "text" || part["type"] == nil else { return nil }
                    return part["text"] as? String
                }
                return texts.isEmpty ? nil : texts.joined(separator: "\n")
            }
            return nil
        }
        .joined(separator: "\n\n")
    }

    static func response(for error: AnalysisError) -> BridgeHTTPResponse {
        switch error {
        case .executableNotFound, .executableNotRunnable, .localToolUnavailableOnThisPlatform:
            return Self.error(status: 503, type: "tool_unavailable", message: error.errorDescription ?? "The tool is unavailable.")
        case let .authenticationRequired(tool, loginCommand):
            return Self.error(
                status: 503,
                type: "authentication_required",
                message: "\(tool.displayName) is not signed in. Run in Terminal: \(loginCommand)"
            )
        case .processTimedOut:
            return Self.error(status: 504, type: "timeout", message: error.errorDescription ?? "The tool timed out.")
        case .transcriptChunkTooLarge, .outputTooLarge:
            return Self.error(status: 413, type: "payload_too_large", message: error.errorDescription ?? "Too large.")
        default:
            return Self.error(status: 502, type: "cli_error", message: error.errorDescription ?? "The tool failed.")
        }
    }

    static func error(status: Int, type: String, message: String) -> BridgeHTTPResponse {
        .json(status: status, object: ["error": ["type": type, "message": message]])
    }

    /// Compares without leaking where the strings diverge. The threat is a
    /// local process guessing the token, not a network timing attacker, but
    /// the constant-time form costs nothing.
    static func tokensMatch(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in x.indices { difference |= x[i] ^ y[i] }
        return difference == 0
    }
}

#if os(macOS)
/// Runs the command-line tools the way Dicavo itself does, through the same
/// `CLIAnalysisProvider`, so a prompt gives the same answer whichever
/// process asked for it. The local command goes through the same process
/// runner (`BridgeLocalCommandRunner`) and is read from the bridge's own
/// settings on every call, so a change applies to the next request.
struct CLIBridgeToolRunner: BridgeToolRunning {
    private let runner: any AnalysisCommandRunning
    private let localCommands: BridgeLocalCommandStore

    init(
        runner: any AnalysisCommandRunning = CLIAnalysisProvider.defaultRunner(),
        localCommands: BridgeLocalCommandStore = BridgeLocalCommandStore()
    ) {
        self.runner = runner
        self.localCommands = localCommands
    }

    func toolStatuses() async -> [BridgeToolStatus] {
        var statuses: [BridgeToolStatus] = []
        for tool in BridgeRequestHandler.bridgedTools where tool != .localCommand {
            guard let executableURL = AnalysisExecutableResolver.resolve(tool: tool, configuredPath: "") else {
                statuses.append(BridgeToolStatus(
                    tool: tool, executablePath: nil, version: nil, isAuthenticated: nil, loginCommand: nil
                ))
                continue
            }
            let provider = CLIAnalysisProvider(tool: tool, executableURL: executableURL, runner: runner)
            let version = try? await provider.toolVersion()
            let authenticated: Bool?
            if let status = try? await provider.authenticationStatus() {
                authenticated = status == .authenticated
            } else {
                authenticated = false
            }
            statuses.append(BridgeToolStatus(
                tool: tool,
                executablePath: executableURL.path,
                version: version,
                isAuthenticated: authenticated,
                loginCommand: tool.loginCommand(executableURL: executableURL)
            ))
        }
        let configuration = localCommands.configuration
        let availability = configuration.availability()
        // Listed once a path is entered, so the menu can say what is wrong
        // with it; offered to Dicavo only when `isUsable`.
        if availability != .notSetUp {
            statuses.append(BridgeToolStatus(
                tool: .localCommand,
                executablePath: configuration.executablePath,
                version: nil,
                isAuthenticated: nil,
                loginCommand: nil,
                localCommand: availability
            ))
        }
        return statuses
    }

    func run(tool: AnalysisTool, model: String?, promptText: String) async throws -> String {
        if tool == .localCommand {
            return try await BridgeLocalCommandRunner(
                configuration: localCommands.configuration,
                runner: runner
            ).run(promptText: promptText)
        }
        guard let executableURL = AnalysisExecutableResolver.resolve(tool: tool, configuredPath: "") else {
            throw AnalysisError.executableNotFound(path: tool.executableName)
        }
        let provider = CLIAnalysisProvider(
            tool: tool,
            executableURL: executableURL,
            model: model,
            runner: runner
        )
        return try await provider.rawMarkdown(forPromptText: promptText)
    }
}
#endif
