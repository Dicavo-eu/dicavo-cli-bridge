import Foundation

/// The one command the user set up in the Dicavo CLI Bridge for analysis:
/// `llm`, `ollama run <model>`, an MLX script, or a tool that does not exist
/// yet. Dicavo's whole request goes to its standard input; its standard
/// output is the Markdown that comes back.
///
/// It is configured in the bridge and nowhere else (`BridgeLocalCommandStore`).
/// Dicavo only ever names it by its model name, `local`; nothing in a request
/// can change what runs or with which arguments.
struct BridgeLocalCommandConfiguration: Equatable, Sendable {
    static let defaultTimeoutSeconds = Int(CLIAnalysisProvider.defaultRequestTimeout.components.seconds)
    /// Capped at the limit Claude Code and Codex get. Dicavo waits only a
    /// little longer than that for any bridge answer
    /// (`AnalysisService.bridgeRequestTimeout`), so a longer limit would leave
    /// a command running that nobody waits for any more.
    static let timeoutRange = 10...defaultTimeoutSeconds

    /// An absolute path; the command is never looked up on `PATH`.
    var executablePath: String
    /// Passed to the process as they are, one element each: no shell ever
    /// sees them, so quotes, `$`, `;` and `*` mean nothing special.
    var arguments: [String]
    var timeoutSeconds: Int
    var isEnabled: Bool

    init(
        executablePath: String = "",
        arguments: [String] = [],
        timeoutSeconds: Int = BridgeLocalCommandConfiguration.defaultTimeoutSeconds,
        isEnabled: Bool = false
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.timeoutSeconds = min(max(timeoutSeconds, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
        self.isEnabled = isEnabled
    }

    var timeout: Duration { .seconds(timeoutSeconds) }

    /// The arguments as typed in the bridge: each line is one argument,
    /// exactly as written. There are no quoting rules to get wrong; the one
    /// thing dropped is a line with nothing on it, which is what a trailing
    /// newline or a gap between lines leaves behind, never a real argument.
    static func arguments(fromLines text: String) -> [String] {
        // `isNewline`, not "\n": a pasted "\r\n" is one Character in Swift.
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func lines(from arguments: [String]) -> String {
        arguments.joined(separator: "\n")
    }

    /// What the bridge finds at the configured path. Checked on every run and
    /// every tool check, so a command removed or replaced since it was set up
    /// is reported instead of attempted.
    func availability(fileManager: FileManager = .default) -> BridgeLocalCommandAvailability {
        let path = executablePath
        guard !path.isEmpty else { return .notSetUp }
        guard path.hasPrefix("/") else { return .notFound }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return .notFound }
        // A directory carries the execute bit too; it is still not a program.
        guard !isDirectory.boolValue, fileManager.isExecutableFile(atPath: path) else { return .notExecutable }
        return isEnabled ? .ready : .disabled
    }
}

enum BridgeLocalCommandAvailability: Equatable, Sendable {
    /// No path entered.
    case notSetUp
    /// No file at the path, or the path is not absolute.
    case notFound
    /// A file, but not one that can be run.
    case notExecutable
    /// Runnable, but switched off in the bridge.
    case disabled
    case ready
}

/// The local command's settings, in the bridge's own preferences.
///
/// Deliberately not in the App Group Dicavo shares: the bridge is not
/// sandboxed, so a value the sandboxed app could write would let it make the
/// bridge run any program. `UserDefaults` is documented as thread-safe, which
/// is what makes the unchecked conformance sound.
struct BridgeLocalCommandStore: @unchecked Sendable {
    private enum Key {
        static let executablePath = "BridgeLocalCommandExecutablePath"
        static let arguments = "BridgeLocalCommandArguments"
        static let timeoutSeconds = "BridgeLocalCommandTimeoutSeconds"
        static let enabled = "BridgeLocalCommandEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Read field by field: a value of the wrong type reads as that field's
    /// default instead of losing the whole command.
    var configuration: BridgeLocalCommandConfiguration {
        BridgeLocalCommandConfiguration(
            executablePath: defaults.string(forKey: Key.executablePath) ?? "",
            arguments: defaults.stringArray(forKey: Key.arguments) ?? [],
            timeoutSeconds: (defaults.object(forKey: Key.timeoutSeconds) as? Int)
                ?? BridgeLocalCommandConfiguration.defaultTimeoutSeconds,
            isEnabled: defaults.bool(forKey: Key.enabled)
        )
    }

    func save(_ configuration: BridgeLocalCommandConfiguration) {
        defaults.set(
            configuration.executablePath.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Key.executablePath
        )
        defaults.set(configuration.arguments, forKey: Key.arguments)
        defaults.set(configuration.timeoutSeconds, forKey: Key.timeoutSeconds)
        defaults.set(configuration.isEnabled, forKey: Key.enabled)
    }
}

/// Dicavo asked for the local command and the bridge has none it may run.
/// Answered like a missing Claude Code: the tool is unavailable, nothing ran.
enum BridgeLocalCommandError: Error, Equatable, LocalizedError {
    case notSetUp

    var errorDescription: String? {
        switch self {
        case .notSetUp:
            // Dicavo shows this with the recording; the bridge speaks
            // Dicavo's language, so it is written in it.
            return InterfaceLanguage.text("No local command is set up and turned on in Dicavo CLI Bridge. Set one up with Local command… in the bridge's menu.")
        }
    }
}

/// Runs the local command once, through the same `AnalysisCommandRunning`
/// as Claude Code and Codex: no shell, the prompt on standard input, output
/// capped, the process group terminated on timeout or cancellation.
struct BridgeLocalCommandRunner: Sendable {
    /// How much of the command's last line on standard error an exit
    /// failure carries.
    static let maximumDiagnosticCharacters = 200
    /// A diagnostic sharing this many consecutive characters with the prompt
    /// is taken for an echo of the meeting and withheld.
    static let echoWindow = 16

    let configuration: BridgeLocalCommandConfiguration
    let runner: any AnalysisCommandRunning

    /// The command's answer as Markdown. Dicavo validates it as it does every
    /// tool's (`AnalysisMarkdownSchema.validate`); here it is only cleaned of
    /// terminal formatting and checked for being empty or too large.
    func run(promptText: String) async throws -> String {
        let path = configuration.executablePath
        switch configuration.availability() {
        case .notSetUp, .disabled:
            throw BridgeLocalCommandError.notSetUp
        case .notFound:
            throw AnalysisError.executableNotFound(path: path)
        case .notExecutable:
            throw AnalysisError.executableNotRunnable(path: path)
        case .ready:
            break
        }

        // A fresh, private working directory: the command has nothing of
        // the bridge's around it, and whatever it leaves there goes away.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Dicavo-Local-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await runner.run(
            AnalysisCommand(
                executableURL: URL(fileURLWithPath: path),
                arguments: configuration.arguments,
                standardInput: Data(promptText.utf8),
                currentDirectoryURL: directory,
                timeout: configuration.timeout
            ),
            tool: .localCommand
        )
        guard result.exitCode == 0 else {
            throw AnalysisError.processFailed(
                tool: .localCommand,
                exitCode: result.exitCode,
                message: Self.diagnostic(fromStandardError: result.standardError, promptText: promptText)
            )
        }
        guard result.standardOutput.count <= AnalysisTransport.maximumMarkdownBytes + 100_000 else {
            throw AnalysisError.outputTooLarge
        }
        let markdown = Self.markdown(fromStandardOutput: result.standardOutput)
        guard !markdown.isEmpty else { throw AnalysisError.emptyOutput }
        guard markdown.utf8.count <= AnalysisTransport.maximumMarkdownBytes else {
            throw AnalysisError.outputTooLarge
        }
        return markdown
    }

    /// Standard output as plain Markdown: escape sequences removed (`ollama
    /// run` and other tools colour or position their output even into a
    /// pipe), line endings unified, surrounding whitespace trimmed.
    static func markdown(fromStandardOutput data: Data) -> String {
        strippingTerminalEscapes(String(decoding: data, as: UTF8.self))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// CSI sequences (colours, cursor moves, `?25l`), OSC sequences (titles,
    /// links) and the remaining two-character escapes.
    static func strippingTerminalEscapes(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text.replacingOccurrences(
            of: #"\x{1B}\[[0-?]*[ -/]*[@-~]|\x{1B}\][^\x{07}\x{1B}]*(?:\x{07}|\x{1B}\\)|\x{1B}[@-Z\\-_]"#,
            with: "",
            options: .regularExpression
        )
    }

    /// The reason an exit failure shows in Dicavo: the last line the command
    /// wrote to standard error, which is where `ollama`, `llm` and a Python
    /// traceback all put it. Bounded, and withheld when it repeats part of
    /// the prompt, because the reason is stored with the recording and must
    /// never carry the meeting itself; then only its size is reported, as for
    /// Claude Code and Codex.
    static func diagnostic(fromStandardError data: Data, promptText: String) -> String {
        guard !data.isEmpty else { return "No diagnostic output." }
        let withheld = "The command wrote \(data.count) bytes to stderr; its content was not persisted."
        let text = strippingTerminalEscapes(String(decoding: data, as: UTF8.self))
        let lastLine = text.split(whereSeparator: \.isNewline)
            .map { line in
                String(String.UnicodeScalarView(line.unicodeScalars.filter {
                    !CharacterSet.controlCharacters.contains($0)
                }))
                .trimmingCharacters(in: .whitespaces)
            }
            .last { !$0.isEmpty }
        guard let lastLine else { return withheld }
        let bounded = lastLine.count > maximumDiagnosticCharacters
            ? String(lastLine.prefix(maximumDiagnosticCharacters)) + "…"
            : lastLine
        return echoesPrompt(bounded, promptText: promptText) ? withheld : bounded
    }

    /// Whether `line` shares a run of `echoWindow` characters with the
    /// prompt, ignoring case and how whitespace is laid out. A shorter line
    /// counts when the prompt contains all of it.
    static func echoesPrompt(_ line: String, promptText: String) -> Bool {
        func normalized(_ text: String) -> String {
            text.lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }
        let prompt = normalized(promptText)
        let characters = Array(normalized(line))
        guard !characters.isEmpty, !prompt.isEmpty else { return false }
        guard characters.count > echoWindow else { return prompt.contains(String(characters)) }
        for start in 0...(characters.count - echoWindow) {
            if prompt.contains(String(characters[start..<(start + echoWindow)])) { return true }
        }
        return false
    }
}
