import Foundation

/// What Dicavo tells the Dicavo CLI Bridge about the analysis it asks for
/// (X16), so the bridge can show in its menu what it is working on: the
/// recording's title and, for an analysis in parts (X8), which part.
///
/// It travels in one request header and nowhere else. The bridge shows it
/// in its menu while the request runs and never writes it to a log, a file
/// or its descriptor. An older bridge ignores the header; a newer bridge
/// treats a request without it as it always did.
///
/// The value is base64url of a small JSON object, so a title in any script
/// stays one ASCII header line. The bridge reads it defensively: a value
/// too long, not decodable, or with numbers out of range gives no task at
/// all, and the title is cleaned of control and direction characters and
/// shortened before anything shows it.
struct BridgeTaskInfo: Codable, Equatable, Sendable {
    static let headerName = "X-Dicavo-Task"
    /// The schema of the value; a bridge ignores a version it does not know.
    static let version = 1
    /// The longest header value a bridge reads.
    static let maximumHeaderLength = 2_048
    /// The longest title a bridge shows, in characters.
    static let maximumTitleLength = 120
    static let maximumPartCount = 999

    var title: String?
    /// 1-based, with `partCount`; both nil for an analysis in one call.
    var part: Int?
    var partCount: Int?

    init(title: String?, part: Int? = nil, partCount: Int? = nil) {
        self.title = title
        self.part = part
        self.partCount = partCount
    }

    private struct Wire: Codable {
        var v: Int
        var title: String?
        var part: Int?
        var parts: Int?
    }

    /// The header value Dicavo sends.
    var headerValue: String? {
        let wire = Wire(
            v: Self.version,
            title: Self.cleanedTitle(title),
            part: part,
            parts: partCount
        )
        guard let data = try? JSONEncoder().encode(wire) else { return nil }
        let value = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return value.count <= Self.maximumHeaderLength ? value : nil
    }

    /// The task in a header value, or nil when there is none worth showing.
    init?(headerValue: String?) {
        guard let headerValue else { return nil }
        let trimmed = headerValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= Self.maximumHeaderLength,
              trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        var base64 = trimmed
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              wire.v == Self.version else { return nil }
        var part = wire.part
        var count = wire.parts
        if let p = part, let c = count, (1...Self.maximumPartCount).contains(c), (1...c).contains(p) {
            part = p
            count = c
        } else {
            part = nil
            count = nil
        }
        let title = Self.cleanedTitle(wire.title)
        guard title != nil || part != nil else { return nil }
        self.init(title: title, part: part, partCount: count)
    }

    /// A title fit to show: one line without control, format or direction
    /// characters, at most `maximumTitleLength` characters; nil when nothing
    /// is left.
    static func cleanedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let scalars = title.unicodeScalars.map { scalar -> Character in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                return " "
            default:
                return Character(scalar)
            }
        }
        let collapsed = String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maximumTitleLength else { return collapsed }
        return String(collapsed.prefix(maximumTitleLength - 1)) + "…"
    }
}

/// One request the bridge works on now (X16), as its menu shows it.
struct BridgeActiveTask: Identifiable, Equatable, Sendable {
    let id: UUID
    let tool: AnalysisTool
    let startedAt: Date
    /// What Dicavo said about it; nil from an older Dicavo.
    let info: BridgeTaskInfo?
}

/// The requests in flight, for the bridge's icon and menu. Held in memory
/// only and never written anywhere: the title in it is what Dicavo sent and
/// stays in this process.
final class BridgeActiveTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [BridgeActiveTask] = []
    private var observer: (@Sendable ([BridgeActiveTask]) -> Void)?

    init() {}

    /// Called with the whole list on every change, on the caller's thread.
    func observe(_ observer: @escaping @Sendable ([BridgeActiveTask]) -> Void) {
        lock.withLock { self.observer = observer }
    }

    /// Called on the main actor after every change with the list as it is
    /// then. Each change hops on its own `Task`, and those may run out of
    /// order: reading `current` there, not the snapshot of the change, keeps
    /// a stale list from landing last and showing work that has ended.
    func observeOnMainActor(_ apply: @escaping @MainActor @Sendable ([BridgeActiveTask]) -> Void) {
        observe { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                apply(self.current)
            }
        }
    }

    var current: [BridgeActiveTask] {
        lock.withLock { tasks }
    }

    func begin(_ task: BridgeActiveTask) {
        let (list, observer) = lock.withLock { () -> ([BridgeActiveTask], (@Sendable ([BridgeActiveTask]) -> Void)?) in
            tasks.append(task)
            return (tasks, self.observer)
        }
        observer?(list)
    }

    func end(_ id: UUID) {
        let (list, observer) = lock.withLock { () -> ([BridgeActiveTask], (@Sendable ([BridgeActiveTask]) -> Void)?) in
            tasks.removeAll { $0.id == id }
            return (tasks, self.observer)
        }
        observer?(list)
    }
}
