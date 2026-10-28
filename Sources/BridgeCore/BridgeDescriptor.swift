import Foundation

/// What a running bridge publishes about itself so Dicavo can find it
/// without the user copying anything.
///
/// The file lives in the App Group container both applications share. The
/// bridge, which is not sandboxed, writes it at every start with a fresh
/// token; Dicavo, which is, may read that container and nothing else of the
/// bridge's. A token that changes on every launch is the cheapest way to
/// make a stale copy useless.
struct BridgeDescriptor: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int = BridgeDescriptor.schemaVersion
    /// Loopback only; the host is never part of the file because the bridge
    /// never listens anywhere else.
    var port: UInt16
    var token: String
    /// The bridge's own version string, for the status line in Dicavo.
    var bridgeVersion: String
    /// The process that wrote the file. A descriptor whose process is gone
    /// is stale even when the file is still there.
    var processIdentifier: Int32
    var startedAt: Date
    /// Raw values of the `AnalysisTool` cases the bridge found on this Mac.
    var availableTools: [String]
    /// What the bridge knows about its own updates, for Dicavo's Settings.
    /// Bridge 2.0 and older do not write it, and Dicavo 2.0 and older skip
    /// it, so the schema version stays 1.
    var updates: BridgeUpdateSummary?
    /// When the process that wrote the file started, as the kernel reports
    /// it. A PID is reused once its process is gone; together with this
    /// time it names one process only, so a descriptor left behind by a
    /// crash is not taken for a running bridge. Bridge 2.1 and older do not
    /// write it.
    var processStartedAt: Date? = nil

    var endpoint: URL? {
        URL(string: "http://127.0.0.1:\(port)/v1")
    }

    /// The update line Dicavo's Settings show for this bridge.
    var updateState: BridgeUpdateState {
        guard let updates else { return .unreported }
        if let version = updates.availableVersion {
            if let system = updates.requiredSystemVersion {
                return .requiresNewerSystem(version: version, system: system)
            }
            return .available(version: version)
        }
        if let lastCheck = updates.lastCheck {
            return .upToDate(checkedAt: lastCheck)
        }
        return .notChecked(automaticChecks: updates.automaticChecks)
    }
}

/// The bridge's own view of its updates. It installs them itself; Dicavo
/// only says what the bridge found, so a person who never opens the
/// bridge's menu still learns that a new version is waiting there.
struct BridgeUpdateSummary: Codable, Equatable, Sendable {
    /// Whether the bridge checks once a day on its own.
    var automaticChecks: Bool
    /// The last check that got an answer from dicavo.eu.
    var lastCheck: Date?
    /// The newer version a check found, e.g. "2.1"; nil when the bridge is
    /// up to date or has never checked.
    var availableVersion: String?
    /// The macOS that version needs, set only when this Mac runs an older one.
    var requiredSystemVersion: String?
}

enum BridgeUpdateState: Equatable, Sendable {
    /// A bridge from before the summary existed.
    case unreported
    case available(version: String)
    case requiresNewerSystem(version: String, system: String)
    case upToDate(checkedAt: Date)
    case notChecked(automaticChecks: Bool)
}

/// Reads and writes the descriptor in the shared container.
struct BridgeDescriptorStore: Sendable {
    /// Team-prefixed, as macOS requires for a group two applications share.
    static let applicationGroup = "H8LTS9AT3K.cz.smartbrains.dicavo"
    static let fileName = "bridge.json"

    private let fileURL: URL?

    init(fileURL: URL? = BridgeDescriptorStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: applicationGroup)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// The published descriptor, or `nil` when there is none, it cannot be
    /// read, or the bridge that wrote it is no longer running.
    func load(
        processIsAlive: (Int32) -> Bool = BridgeDescriptorStore.processIsAlive,
        processStartTime: (Int32) -> Date? = BridgeDescriptorStore.processStartTime
    ) -> BridgeDescriptor? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let descriptor = try? decoder.decode(BridgeDescriptor.self, from: data),
              descriptor.schemaVersion == BridgeDescriptor.schemaVersion,
              !descriptor.token.isEmpty,
              descriptor.port > 0,
              processIsAlive(descriptor.processIdentifier)
        else { return nil }
        // Where the start time cannot be read, the PID alone decides, as it
        // did before the field existed.
        if let recorded = descriptor.processStartedAt,
           let actual = processStartTime(descriptor.processIdentifier),
           abs(actual.timeIntervalSince(recorded)) > Self.startTimeTolerance {
            return nil
        }
        return descriptor
    }

    /// ISO 8601 in the file keeps whole seconds only.
    static let startTimeTolerance: TimeInterval = 1.5

    func save(_ descriptor: BridgeDescriptor) throws {
        guard let fileURL else { throw BridgeDescriptorError.containerUnavailable }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(descriptor)
        // Created readable by its owner only, then renamed into place, so
        // the token is never in a file anyone else could open, not even for
        // the moment between writing and changing permissions.
        let staging = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(Self.fileName).\(UUID().uuidString)", isDirectory: false)
        guard FileManager.default.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw BridgeDescriptorError.writeFailed
        }
        guard rename(staging.path, fileURL.path) == 0 else {
            try? FileManager.default.removeItem(at: staging)
            throw BridgeDescriptorError.writeFailed
        }
    }

    /// Removes the descriptor. Called when the bridge quits, so Dicavo does
    /// not spend a connection attempt finding out.
    func remove() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// The kernel's start time of process `pid`, or nil when it is gone or
    /// cannot be asked about.
    static func processStartTime(_ pid: Int32) -> Date? {
        #if os(macOS)
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        #else
        return nil
        #endif
    }
}

enum BridgeDescriptorError: Error, Equatable {
    case containerUnavailable
    case writeFailed
}
