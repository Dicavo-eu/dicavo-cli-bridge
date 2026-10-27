import Foundation

enum AnalysisError: Error, Equatable, LocalizedError {
    case executableNotFound(path: String)
    case executableNotRunnable(path: String)
    case processLaunchFailed(tool: AnalysisTool, message: String)
    case processFailed(tool: AnalysisTool, exitCode: Int32, message: String)
    case authenticationRequired(tool: AnalysisTool, loginCommand: String)
    case processTimedOut(tool: AnalysisTool)
    case transcriptChunkTooLarge
    case emptyOutput
    case outputTooLarge
    case reservedMarkerInOutput
    case invalidStructuredOutput(String)
    /// This platform has no way to run a local command-line tool. The one
    /// answer that is never given here is a quiet fallback to a cloud
    /// provider: the recording stays local and the analysis simply does not
    /// happen on this device.
    case localToolUnavailableOnThisPlatform
    /// A cloud tool is selected but the user has not yet agreed that the
    /// transcript may be sent to it. Nothing was sent.
    case cloudConsentRequired(tool: AnalysisTool)
    /// The selected tool needs Dicavo Pro and this installation does not have
    /// it. Nothing was sent; the transcript and Markdown are still written.
    case proRequired(feature: ProFeature, state: LicenseState)
    /// No key in the keychain for this tool. Nothing was sent.
    case apiKeyMissing(tool: AnalysisTool)
    /// The provider answered 401 or 403: the key is wrong, expired or lacks
    /// access to the model.
    case apiKeyRejected(tool: AnalysisTool)
    /// The OpenAI-compatible tool has no base URL, or the stored one is not a
    /// URL.
    case endpointMissing(tool: AnalysisTool)
    /// The provider answered with a non-success status. The message is the
    /// provider's own error text, bounded, never meeting content.
    case httpRequestFailed(tool: AnalysisTool, statusCode: Int, message: String)
    /// The request never got an answer: no network, DNS, TLS, timeout.
    case networkFailure(tool: AnalysisTool, message: String)
    /// The provider, or the Claude Code or Codex account behind the Bridge,
    /// is over its usage limit (HTTP 429). Nothing is wrong with the key or
    /// the recording; the same request works again later. `service` names
    /// who set the limit; `detail` is that service's own one-line reason
    /// (for example an organization's monthly spend limit), when it gave one.
    case rateLimited(tool: AnalysisTool, service: String, detail: String?)
    /// The model declined to answer (a safety refusal or a guardrail), so
    /// there is no analysis for this recording. Retrying the same content
    /// will not help.
    case responseRefused(tool: AnalysisTool)
    /// Apple Intelligence is not usable on this device right now. The reason
    /// is the system's own, already localized.
    case onDeviceModelUnavailable(reason: String)
    /// The on-device model does not support the requested output language.
    case onDeviceModelLanguageUnsupported(language: String)
    /// No running Dicavo CLI Bridge published itself in the shared container.
    case bridgeNotRunning
    /// The Bridge runs, but not the tool the selected model names (HTTP 503
    /// `tool_unavailable`): typically Claude Code on a Mac that has only
    /// Codex. `service` names that tool.
    case bridgeToolUnavailable(service: String)

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(path):
            return "The AI tool executable was not found at \(path)."
        case let .executableNotRunnable(path):
            return "The selected AI tool is not executable: \(path)."
        case let .processLaunchFailed(tool, message):
            return "\(tool.displayName) could not be started: \(message)"
        case let .processFailed(tool, exitCode, message):
            let detail = message.isEmpty ? "No diagnostic output." : message
            return "\(tool.displayName) failed with exit code \(exitCode): \(detail)"
        case let .authenticationRequired(tool, loginCommand):
            return "\(tool.displayName) sign-in has expired or is invalid. Open Terminal and run:\n\(loginCommand)\nComplete sign-in, then retry AI analysis. Your recording and transcript are saved."
        case let .processTimedOut(tool):
            return "\(tool.displayName) analysis timed out."
        case .transcriptChunkTooLarge:
            return "A transcript segment or partial analysis is too large to process safely."
        case .emptyOutput:
            return "The AI tool returned an empty analysis."
        case .outputTooLarge:
            return "The AI tool returned an analysis that is too large."
        case .reservedMarkerInOutput:
            return "The AI analysis contains a reserved Dicavo marker."
        case let .invalidStructuredOutput(reason):
            return "The structured AI analysis could not be decoded: \(reason)"
        case .localToolUnavailableOnThisPlatform:
            return "AI analysis runs through a locally installed command-line tool, which this platform cannot start. Transfer the recording to the Mac to analyse it there."
        case let .cloudConsentRequired(tool):
            return "\(tool.displayName) sends the transcript to an external service. Confirm that in Settings → AI before analysis can run. Nothing was sent."
        case let .proRequired(feature, state):
            let ended: String
            if case .free(.expired(let date)) = state {
                ended = "Dicavo Pro ended on \(date.formatted(date: .long, time: .omitted)). "
            } else {
                ended = ""
            }
            switch feature {
            case .cloudAnalysis:
                return ended + "Cloud AI analysis needs Dicavo Pro. Nothing was sent; your recording and transcript are saved."
            case .bridgeAnalysis:
                return ended + "Dicavo CLI Bridge analysis needs Dicavo Pro. Nothing was sent; your recording and transcript are saved."
            default:
                return ended + "This feature needs Dicavo Pro. Nothing was sent; your recording and transcript are saved."
            }
        case let .apiKeyMissing(tool):
            return "No API key is saved for \(tool.displayName). Enter one in Settings → AI. Nothing was sent."
        case let .apiKeyRejected(tool):
            return "\(tool.displayName) rejected the API key. Check the key in Settings → AI and that it has access to the selected model."
        case let .endpointMissing(tool):
            return "\(tool.displayName) has no valid base URL. Enter one in Settings → AI."
        case let .httpRequestFailed(tool, statusCode, message):
            let detail = message.isEmpty ? "No diagnostic output." : message
            return "\(tool.displayName) answered HTTP \(statusCode): \(detail)"
        case let .networkFailure(tool, message):
            return "\(tool.displayName) could not be reached: \(message)"
        case let .rateLimited(tool, service, detail):
            // Stored with the recording when it happens, so it is written in
            // the interface language rather than in English.
            let who = tool == .dicavoBridge
                ? InterfaceLanguage.text("\(service) via Dicavo CLI Bridge")
                : service
            guard let detail else {
                return InterfaceLanguage.text(
                    "\(who) is over its usage limit right now. The recording, transcript and note are saved; retry the AI analysis later."
                )
            }
            return InterfaceLanguage.text(
                "\(who) reports a usage limit: \(detail) The recording, transcript and note are saved; retry the AI analysis later."
            )
        case let .responseRefused(tool):
            return "\(tool.displayName) declined to analyze this recording."
        case let .onDeviceModelUnavailable(reason):
            return "Apple Intelligence is not available: \(reason)"
        case let .onDeviceModelLanguageUnsupported(language):
            return "Apple Intelligence does not support \(language) as the output language. Choose another output language or another AI tool."
        case .bridgeNotRunning:
            return "The Dicavo CLI Bridge is not running on this Mac. Start it, then retry AI analysis."
        case let .bridgeToolUnavailable(service):
            // Stored with the recording, like a usage limit, so it is
            // written in the interface language.
            return InterfaceLanguage.text(
                "Dicavo CLI Bridge cannot run \(service) on this Mac: it is not installed there or not ready. In Settings → AI, choose a model for a tool the bridge lists under Usable tools, then retry AI analysis."
            )
        }
    }
}
