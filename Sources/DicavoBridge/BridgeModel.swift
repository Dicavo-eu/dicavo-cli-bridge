import AppKit
import Foundation
import ServiceManagement
import Security

/// The bridge's whole state, for the menu bar: whether it listens, where,
/// which tools it found, and whether it starts at login.
@MainActor
final class BridgeModel: ObservableObject {
    enum ServerState: Equatable {
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    @Published private(set) var serverState: ServerState = .starting
    @Published private(set) var toolStatuses: [BridgeToolStatus] = []
    @Published private(set) var isRefreshingTools = false
    @Published private(set) var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var descriptorError: String?
    /// The command set up in the bridge, as last saved.
    @Published private(set) var localCommand: BridgeLocalCommandConfiguration
    /// Set by the update controller; published with the descriptor so
    /// Dicavo's Settings can show it. A change goes out at once only after
    /// the first publish: before that the tools are not known yet, and the
    /// first publish carries the summary anyway.
    var updateSummary: BridgeUpdateSummary? {
        didSet {
            guard updateSummary != oldValue, hasPublished, case let .listening(port) = serverState else { return }
            publishDescriptor(port: port)
        }
    }
    private var hasPublished = false

    let token: String
    private let runner: any BridgeToolRunning
    private let descriptors: BridgeDescriptorStore
    private let localCommands: BridgeLocalCommandStore
    private var server: BridgeServer?
    /// A check asked for while one runs; see `refreshTools()`.
    private var refreshRequested = false

    /// The runner reads the local command from the same store this model
    /// saves it to, so a saved command is what the next request runs.
    init(
        runner: (any BridgeToolRunning)? = nil,
        descriptors: BridgeDescriptorStore = BridgeDescriptorStore(),
        localCommands: BridgeLocalCommandStore = BridgeLocalCommandStore()
    ) {
        self.runner = runner ?? CLIBridgeToolRunner(localCommands: localCommands)
        self.descriptors = descriptors
        self.localCommands = localCommands
        self.localCommand = localCommands.configuration
        self.token = Self.makeToken()
        Self.followDicavoLanguageAtNextLaunch()
        // Dicavo says when its language changes; the menu is built again on
        // the next publish, in the new language.
        languageObserver = DistributedNotificationCenter.default().addObserver(
            forName: InterfaceLanguage.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                Self.followDicavoLanguageAtNextLaunch()
                self?.objectWillChange.send()
            }
        }
        // However the bridge quits — its menu, logging out, an update that
        // relaunches it — the commands it runs end with it.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    private var languageObserver: (any NSObjectProtocol)?
    private var terminationObserver: (any NSObjectProtocol)?

    /// The menu's own text follows Dicavo at once through `InterfaceLanguage`;
    /// the items macOS adds itself, and the alerts' standard buttons, follow
    /// the process language, which takes effect when the bridge next starts.
    private static func followDicavoLanguageAtNextLaunch() {
        if let code = InterfaceLanguage.sharedCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    /// 32 random bytes from the system CSPRNG, hex-encoded. New on every
    /// launch, so a descriptor left behind by a crash authorises nothing.
    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func start() async {
        let server = BridgeServer(handler: BridgeRequestHandler(token: token, runner: runner))
        self.server = server
        do {
            let port = try await server.start()
            serverState = .listening(port: port)
            await refreshTools()
            publishDescriptor(port: port)
        } catch {
            serverState = .failed(error.localizedDescription)
        }
    }

    /// Whether Dicavo is waiting on the bridge right now.
    var hasActiveRequests: Bool {
        (server?.activeRequestCount ?? 0) > 0
    }

    func stop() {
        server?.stop()
        server = nil
        descriptors.remove()
    }

    func refreshTools() async {
        guard !isRefreshingTools else {
            // The check under way may have read the local command before it
            // was saved; one more round makes the menu and the descriptor
            // show the saved one.
            refreshRequested = true
            return
        }
        isRefreshingTools = true
        defer { isRefreshingTools = false }
        repeat {
            refreshRequested = false
            toolStatuses = await runner.toolStatuses()
        } while refreshRequested
        if case let .listening(port) = serverState {
            publishDescriptor(port: port)
        }
    }

    /// Saves the command set up in the bridge's window. The menu, the models
    /// Dicavo is offered and `bridge.json` follow once the tools are checked
    /// again.
    func saveLocalCommand(_ configuration: BridgeLocalCommandConfiguration) {
        localCommands.save(configuration)
        localCommand = localCommands.configuration
        Task { await refreshTools() }
    }

    private func publishDescriptor(port: UInt16) {
        let descriptor = BridgeDescriptor(
            port: port,
            token: token,
            bridgeVersion: Self.version,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            startedAt: Date(),
            availableTools: toolStatuses.filter(\.isUsable).map(\.tool.rawValue),
            updates: updateSummary
        )
        do {
            try descriptors.save(descriptor)
            descriptorError = nil
            hasPublished = true
            #if DEBUG
            // The shared container is unreadable to anything that is not a
            // member of the group, the terminal included, so a debug build
            // started from one with this flag says where it listens.
            if CommandLine.arguments.contains("--debug-print-descriptor") {
                FileHandle.standardError.write(Data("bridge endpoint: \(descriptor.endpoint?.absoluteString ?? "-") token: \(descriptor.token)\n".utf8))
            }
            #endif
        } catch {
            descriptorError = InterfaceLanguage.text("Could not publish the bridge for Dicavo: \(error.localizedDescription)")
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            descriptorError = error.localizedDescription
        }
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }
}
