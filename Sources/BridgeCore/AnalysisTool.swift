import Foundation

// The analysis vocabulary that needs nothing but Foundation. It is shared
// with the CLI bridge, which speaks about tools and errors but knows nothing
// about sessions, transcripts or renderers, so nothing in this file may
// reach for those.

/// How an analysis tool reaches a model. The kind decides what Settings asks
/// for (an executable, an API key, nothing) and whether the transcript leaves
/// the device at all.
enum AnalysisToolKind: Sendable {
    /// A locally installed command-line tool the app launches as a subprocess.
    /// Needs a non-sandboxed process; this kind is absent from the App Store
    /// build.
    case commandLine
    /// Apple's on-device model. Nothing leaves the Mac.
    case onDevice
    /// A hosted API the user holds their own key for. The transcript is sent
    /// to that provider, so this kind is gated behind explicit consent.
    case cloudAPI
}

enum AnalysisTool: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude
    /// Google's Antigravity CLI. Like Claude Code and Codex it runs only
    /// behind the bridge; its raw value is the model name the bridge lists
    /// it under.
    case antigravity = "agy"
    /// Apple Intelligence through the Foundation Models framework.
    case appleIntelligence
    /// The Anthropic Messages API, called directly with the user's key.
    case claudeAPI
    /// Any endpoint speaking the OpenAI chat-completions dialect, with the
    /// user's key and base URL.
    case openAICompatibleAPI
    /// The Dicavo CLI Bridge: a separate, unsandboxed helper on this Mac that
    /// runs Claude Code or Codex on Dicavo's behalf and answers over
    /// loopback in the OpenAI dialect. Found through the shared App Group.
    case dicavoBridge
    /// The one command the user set up in the Dicavo CLI Bridge (`llm`,
    /// `ollama run <model>`, an MLX script …). Like Claude Code and Codex it
    /// exists only behind the bridge, which also owns its configuration, and
    /// its raw value is the model name the bridge lists it under.
    case localCommand = "local"
    /// A value written by a build that knew a tool this one does not. A
    /// manifest naming it stays readable; the tool itself is never offered.
    case unrecognized

    /// The tools a user can pick. `unrecognized` exists only to keep old
    /// manifests decodable and is never offered. `codex` and `claude` are
    /// not offered either: a sandboxed Dicavo cannot launch them, so the
    /// bridge runs them instead. The cases stay so manifests and settings
    /// written before the bridge still decode and can be migrated.
    /// `localCommand` is reached the same way, through the bridge.
    static let allCases: [AnalysisTool] = [
        .appleIntelligence, .claudeAPI, .openAICompatibleAPI, .dicavoBridge,
    ]

    /// The bridge model that runs the same tool a direct selection named.
    var bridgeEquivalent: AnalysisModelSelection? {
        switch self {
        case .codex: return .bridgeCodex
        case .claude: return .bridgeClaude
        case .antigravity: return .bridgeAntigravity
        case .localCommand: return .bridgeLocal
        case .appleIntelligence, .claudeAPI, .openAICompatibleAPI, .dicavoBridge, .unrecognized: return nil
        }
    }

    init(from decoder: any Decoder) throws {
        self = try Self.decodedFromManifest(decoder, fallback: .unrecognized)
    }

    var id: String { rawValue }

    var kind: AnalysisToolKind {
        switch self {
        case .codex, .claude, .antigravity, .localCommand, .unrecognized: return .commandLine
        case .appleIntelligence: return .onDevice
        case .claudeAPI, .openAICompatibleAPI, .dicavoBridge: return .cloudAPI
        }
    }

    /// The Pro feature this tool needs, or nil when it stays free. The
    /// processor checks the gate with it and Settings shows the same notice.
    /// Every analysis tool is free since 2.2: the bridge and an own API
    /// key run on the user's tool and account and cost Dicavo nothing. The
    /// cases `cloudAnalysis` and `bridgeAnalysis` stay for older manifests.
    var proFeature: ProFeature? { nil }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        case .appleIntelligence: return "Apple Intelligence"
        case .claudeAPI: return "Claude API"
        case .openAICompatibleAPI: return "OpenAI-compatible API"
        case .dicavoBridge: return "Dicavo CLI Bridge"
        case .localCommand: return "Local command"
        case .unrecognized: return "Unknown tool"
        }
    }

    /// The transcript leaves the device with this tool. Drives the consent
    /// requirement and the wording in Settings.
    var sendsMeetingContentOffDevice: Bool {
        kind == .cloudAPI || kind == .commandLine
    }

    /// Only the command-line tools have one; the others return an empty name
    /// so a caller that reaches here for the wrong kind produces a visible
    /// "not found" rather than a crash.
    var executableName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .antigravity: return "agy"
        // The local command has a configured path, never a name to look up.
        case .appleIntelligence, .claudeAPI, .openAICompatibleAPI, .dicavoBridge, .localCommand, .unrecognized: return ""
        }
    }

    var authenticationStatusArguments: [String] {
        switch self {
        case .codex: return ["login", "status"]
        case .claude: return ["auth", "status"]
        // `agy` has no status command; `agy models` exits 1 when signed out.
        case .antigravity: return ["models"]
        case .appleIntelligence, .claudeAPI, .openAICompatibleAPI, .dicavoBridge, .localCommand, .unrecognized: return []
        }
    }

    var loginArguments: [String] {
        switch self {
        case .codex: return ["login"]
        case .claude: return ["auth", "login"]
        // Signing in to `agy` means running it alone in a Terminal.
        case .antigravity: return []
        case .appleIntelligence, .claudeAPI, .openAICompatibleAPI, .dicavoBridge, .localCommand, .unrecognized: return []
        }
    }

    /// The Anthropic API's default endpoint. The OpenAI-compatible tool has
    /// no default: every such provider has its own host, and guessing one
    /// would send the key to the wrong place.
    var defaultEndpoint: URL? {
        switch self {
        case .claudeAPI: return URL(string: "https://api.anthropic.com")
        case .codex, .claude, .antigravity, .appleIntelligence, .openAICompatibleAPI, .dicavoBridge, .localCommand, .unrecognized: return nil
        }
    }

    func loginCommand(executableURL: URL) -> String {
        let quotedPath = "'\(executableURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        return ([quotedPath] + loginArguments).joined(separator: " ")
    }
}

enum AnalysisModelSelection: String, Codable, Identifiable, Sendable {
    case automatic
    case codexTerra
    case codexSol
    case codexLuna
    case claudeSonnet
    case claudeOpus
    /// The Claude API presets. The raw values keep the names 2.1 stored, so a
    /// stored preset follows its model family to the current version on its
    /// own; a model typed as a custom one stays exactly as typed.
    case claudeAPIOpus = "claudeAPIOpus5"
    case claudeAPISonnet = "claudeAPISonnet5"
    /// The bridge's tools, by the names the bridge lists them under.
    case bridgeClaude
    case bridgeCodex
    case bridgeAntigravity
    /// The command set up in the bridge itself. An older Dicavo does not
    /// know this value and reads it as its tool's first option.
    case bridgeLocal
    case custom

    var id: String { rawValue }

    static func options(for tool: AnalysisTool) -> [AnalysisModelSelection] {
        switch tool {
        case .codex:
            return [.automatic, .codexTerra, .codexSol, .codexLuna, .custom]
        case .claude:
            return [.automatic, .claudeSonnet, .claudeOpus, .custom]
        case .localCommand:
            // Runs exactly as set up in the bridge; it has no models to pick.
            return [.automatic]
        case .antigravity:
            // Runs behind the bridge with its own default model.
            return [.automatic]
        case .claudeAPI:
            // The API has no "tool default": a model must be named. Opus
            // first, because analysis quality is what the user is paying for.
            return [.claudeAPIOpus, .claudeAPISonnet, .custom]
        case .openAICompatibleAPI:
            // Every compatible provider has its own model names; only the
            // user knows them.
            return [.custom]
        case .dicavoBridge:
            // Which of the bridge's tools should run: the command-line tools
            // or the command set up in the bridge. The custom form is
            // `claude:<model>`, `codex:<model>` or `agy:<model>`.
            return [.bridgeClaude, .bridgeCodex, .bridgeAntigravity, .bridgeLocal, .custom]
        case .appleIntelligence:
            // One system model, chosen by the OS.
            return [.automatic]
        case .unrecognized:
            return [.automatic]
        }
    }

    /// The first option for a tool — what a freshly selected tool starts
    /// with, and what a stored selection falls back to when it does not fit.
    static func defaultSelection(for tool: AnalysisTool) -> AnalysisModelSelection {
        options(for: tool).first ?? .automatic
    }

    /// The bridge model Dicavo moves to on its own: only away from the
    /// untouched default (Claude Code), only when the running bridge does not
    /// list that tool as usable and lists another one. Nil keeps the current
    /// selection.
    static func bridgeSelection(
        replacingDefault current: AnalysisModelSelection,
        availableTools: [String]
    ) -> AnalysisModelSelection? {
        let fallback = defaultSelection(for: .dicavoBridge)
        guard current == fallback,
              let fallbackTool = fallback.modelIdentifier,
              !availableTools.contains(fallbackTool) else { return nil }
        return options(for: .dicavoBridge).first { option in
            guard let tool = option.modelIdentifier else { return false }
            return availableTools.contains(tool)
        }
    }

    func isAvailable(for tool: AnalysisTool) -> Bool {
        Self.options(for: tool).contains(self)
    }

    var titleLocalizationKey: String {
        switch self {
        case .automatic: return "Automatic (tool default)"
        case .codexTerra: return "GPT-5.6 Terra — recommended"
        case .codexSol: return "GPT-5.6 Sol — highest quality"
        case .codexLuna: return "GPT-5.6 Luna — fastest"
        case .claudeSonnet: return "Claude Sonnet — recommended"
        case .claudeOpus: return "Claude Opus — highest quality"
        case .claudeAPIOpus: return "Claude Opus 5.5 — recommended"
        case .claudeAPISonnet: return "Claude Sonnet 5.5 — faster"
        case .bridgeClaude: return "Claude Code via bridge"
        case .bridgeCodex: return "Codex via bridge"
        case .bridgeAntigravity: return "Antigravity via bridge"
        case .bridgeLocal: return "Local command via bridge"
        case .custom: return "Custom model…"
        }
    }

    var detailLocalizationKey: String {
        switch self {
        case .automatic:
            return "The selected tool chooses its configured or recommended model."
        case .codexTerra:
            return "Balanced quality, speed, and cost for meeting analysis."
        case .codexSol, .claudeOpus, .claudeAPIOpus:
            return "Highest quality for complex or long meetings."
        case .codexLuna:
            return "Fast and efficient for repeatable analysis."
        case .claudeSonnet, .claudeAPISonnet:
            return "Balanced quality and speed for meeting analysis."
        case .bridgeClaude, .bridgeCodex:
            return "The bridge runs the tool installed and signed in on this Mac, with its own default model."
        case .bridgeAntigravity:
            return "The bridge runs Antigravity installed and signed in on this Mac, with its own default model. Antigravity keeps a title it generates for each analysis in its own history; the bridge deletes the rest of each run and blocks Antigravity's tools."
        case .bridgeLocal:
            return "The bridge runs the command you set up in its menu. Dicavo cannot check where that command sends the transcript, so it needs the same consent as the other tools."
        case .custom:
            return "Enter a model identifier supported by the selected tool."
        }
    }

    var modelIdentifier: String? {
        switch self {
        case .automatic, .custom: return nil
        case .codexTerra: return "gpt-5.6-terra"
        case .codexSol: return "gpt-5.6-sol"
        case .codexLuna: return "gpt-5.6-luna"
        case .claudeSonnet: return "sonnet"
        case .claudeOpus: return "opus"
        case .claudeAPIOpus: return "claude-opus-5-5"
        case .claudeAPISonnet: return "claude-sonnet-5-5"
        case .bridgeClaude: return "claude"
        case .bridgeCodex: return "codex"
        case .bridgeAntigravity: return AnalysisTool.antigravity.rawValue
        case .bridgeLocal: return AnalysisTool.localCommand.rawValue
        }
    }

    func resolvedModel(customModel: String) -> String? {
        if let modelIdentifier { return modelIdentifier }
        guard self == .custom else { return nil }
        let normalized = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func selection(for model: String, tool: AnalysisTool) -> AnalysisModelSelection {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .automatic }
        switch (tool, normalized) {
        case (.codex, "gpt-5.6-terra"): return .codexTerra
        case (.codex, "gpt-5.6-sol"), (.codex, "gpt-5.6"): return .codexSol
        case (.codex, "gpt-5.6-luna"): return .codexLuna
        case (.claude, "sonnet"): return .claudeSonnet
        case (.claude, "opus"): return .claudeOpus
        case (.claudeAPI, "claude-opus-5-5"): return .claudeAPIOpus
        case (.claudeAPI, "claude-sonnet-5-5"): return .claudeAPISonnet
        case (.dicavoBridge, "claude"): return .bridgeClaude
        case (.dicavoBridge, "codex"): return .bridgeCodex
        case (.dicavoBridge, "agy"): return .bridgeAntigravity
        case (.dicavoBridge, "local"): return .bridgeLocal
        case (.appleIntelligence, _): return .automatic
        default: return .custom
        }
    }
}

struct AnalysisMarkdown: Codable, Equatable, Sendable {
    let markdown: String

    static let empty = AnalysisMarkdown(markdown: "")
}

/// The transport limits and the JSON schema the command-line tools are asked
/// to fill. Owned here rather than by the renderer-aware schema type so the
/// bridge can compile without the renderer.
enum AnalysisTransport {
    static let maximumMarkdownBytes = 1_000_000

    static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "markdown": ["type": "string"],
            ],
            "required": ["markdown"],
            "additionalProperties": false,
        ]
    }
}
