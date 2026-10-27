import AppKit
import Foundation

/// Checks for, downloads and installs bridge updates, and remembers whether
/// the person wants that to happen on its own.
///
/// Automatic checks are off until the person turns them on — at first
/// launch, or later in the menu. A manual check always works and always
/// answers. See docs/updates.md in the dicavo-cli-bridge repository.
@MainActor
final class BridgeUpdateController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(BridgeUpdateManifest)
        case requiresNewerSystem(BridgeUpdateManifest)
        case downloading(BridgeUpdateManifest)
        /// Verified and staged; waits until Dicavo's current request is done.
        case waitingForRequests(BridgeUpdateManifest)
        case installing(BridgeUpdateManifest)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .waitingForRequests, .installing: return true
            default: return false
            }
        }
    }

    private enum Keys {
        static let automaticChecks = "BridgeAutomaticUpdateChecks"
        static let lastCheck = "BridgeLastUpdateCheck"
        static let welcomeShown = "BridgeWelcomeShown"
        static let foundUpdate = "BridgeFoundUpdate"
    }

    static let downloadPageURL = URL(string: "https://dicavo.eu/\(BridgeUpdateController.webLanguage)/bridge.html")!

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var automaticChecksEnabled: Bool
    @Published private(set) var lastCheck: Date?

    private let defaults: UserDefaults
    private let checker = BridgeUpdateChecker()
    private let installer = BridgeUpdateInstaller()
    private weak var model: BridgeModel?
    private var timer: Timer?
    private var started = false
    /// The newest manifest a check returned. Kept across launches, so a
    /// bridge restarted after finding an update still tells Dicavo about it.
    private var foundUpdate: BridgeUpdateManifest? {
        didSet {
            if let foundUpdate, let data = try? JSONEncoder().encode(foundUpdate) {
                defaults.set(data, forKey: Keys.foundUpdate)
            } else {
                defaults.removeObject(forKey: Keys.foundUpdate)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticChecksEnabled = defaults.bool(forKey: Keys.automaticChecks)
        lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date
        foundUpdate = (defaults.data(forKey: Keys.foundUpdate))
            .flatMap { try? JSONDecoder().decode(BridgeUpdateManifest.self, from: $0) }
    }

    /// What Dicavo's Settings show about this bridge's updates.
    var summary: BridgeUpdateSummary {
        let offer = foundUpdate?.offer(
            currentBuild: Self.currentBuild,
            system: ProcessInfo.processInfo.operatingSystemVersion
        )
        return BridgeUpdateSummary(
            automaticChecks: automaticChecksEnabled,
            lastCheck: lastCheck,
            availableVersion: offer?.version,
            requiredSystemVersion: offer?.requiredSystemVersion
        )
    }

    private func publishSummary() {
        model?.updateSummary = summary
    }

    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    /// The web has en, sk and cs pages; anything else reads English.
    private static var webLanguage: String {
        let code = Bundle.main.preferredLocalizations.first?.prefix(2).lowercased() ?? "en"
        return ["sk", "cs"].contains(code) ? code : "en"
    }

    /// Called once the bridge listens: the welcome at first launch, then the
    /// hourly look at whether a daily check is due.
    func start(model: BridgeModel) {
        guard !started else { return }
        started = true
        self.model = model
        publishSummary()
        if !defaults.bool(forKey: Keys.welcomeShown) {
            defaults.set(true, forKey: Keys.welcomeShown)
            // After the menu bar item exists, so "you'll find it up there"
            // is true when the window says it.
            DispatchQueue.main.async { [weak self] in self?.showWelcome() }
        }
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        automaticChecksEnabled = enabled
        defaults.set(enabled, forKey: Keys.automaticChecks)
        publishSummary()
        if enabled { checkIfDue() }
    }

    private func checkIfDue() {
        guard !phase.isBusy,
              BridgeUpdateSchedule.isDue(enabled: automaticChecksEnabled, lastCheck: lastCheck, now: Date())
        else { return }
        Task { await check(userInitiated: false) }
    }

    // MARK: Checking

    func check(userInitiated: Bool) async {
        guard !phase.isBusy else { return }
        phase = .checking
        do {
            let manifest = try await checker.fetchManifest()
            recordCheck()
            let availability = manifest.availability(
                currentBuild: Self.currentBuild,
                system: ProcessInfo.processInfo.operatingSystemVersion
            )
            switch availability {
            case .upToDate:
                foundUpdate = nil
            case .available, .requiresNewerSystem:
                foundUpdate = manifest
            }
            publishSummary()
            switch availability {
            case .upToDate:
                phase = .upToDate
                if userInitiated { showUpToDate() }
            case let .available(manifest):
                phase = .available(manifest)
                if userInitiated { offerInstall(manifest) }
            case let .requiresNewerSystem(manifest):
                phase = .requiresNewerSystem(manifest)
                if userInitiated { showRequiresNewerSystem(manifest) }
            }
        } catch {
            let message = error.localizedDescription
            // An automatic check that fails says so in the menu only; it does
            // not interrupt anyone with an alert about a flaky network.
            phase = .failed(message)
            if userInitiated { showFailure(message) }
        }
    }

    private func recordCheck() {
        let now = Date()
        lastCheck = now
        defaults.set(now, forKey: Keys.lastCheck)
    }

    // MARK: Installing

    func install(_ manifest: BridgeUpdateManifest) async {
        guard !phase.isBusy else { return }
        phase = .downloading(manifest)
        let staged: BridgeUpdateInstaller.StagedUpdate
        do {
            staged = try await installer.stage(manifest)
        } catch {
            fail(error.localizedDescription)
            return
        }

        guard BridgeUpdateInstaller.canReplace(Bundle.main.bundleURL) else {
            handOver(staged)
            return
        }

        phase = .waitingForRequests(manifest)
        while model?.hasActiveRequests == true {
            try? await Task.sleep(for: .seconds(2))
        }

        phase = .installing(manifest)
        do {
            try installer.install(staged)
        } catch {
            BridgeUpdateInstaller.discard(staged)
            fail(error.localizedDescription)
            return
        }
        BridgeUpdateInstaller.discard(staged)
        do {
            try BridgeUpdateInstaller.relaunch(Bundle.main.bundleURL, after: ProcessInfo.processInfo.processIdentifier)
        } catch {
            // The new version is in place; it starts the next time the
            // bridge is opened. Say so rather than quitting into nothing.
            phase = .failed(InterfaceLanguage.text("Version \(manifest.version) is installed. Quit and reopen Dicavo CLI Bridge to start it."))
            return
        }
        model?.stop()
        NSApplication.shared.terminate(nil)
    }

    /// The running copy cannot be replaced where it is: keep the verified
    /// image in Downloads and open it for a manual drag to Applications.
    private func handOver(_ staged: BridgeUpdateInstaller.StagedUpdate) {
        do {
            let image = try BridgeUpdateInstaller.keepImageForManualInstall(staged)
            BridgeUpdateInstaller.discard(staged)
            phase = .available(staged.manifest)
            NSWorkspace.shared.open(image)
            alert(
                InterfaceLanguage.text("Finish the update in Finder"),
                InterfaceLanguage.text("Dicavo CLI Bridge cannot replace itself where it is running from. The verified disk image is in your Downloads folder and now open: quit the bridge, then drag Dicavo CLI Bridge to Applications.")
            )
        } catch {
            BridgeUpdateInstaller.discard(staged)
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        alert(InterfaceLanguage.text("The update was not installed"), message + "\n\n" + InterfaceLanguage.text("The running version is unchanged. You can also download the update from dicavo.eu."), showsDownloadPage: true)
    }

    func openDownloadPage() {
        NSWorkspace.shared.open(Self.downloadPageURL)
    }

    // MARK: Windows

    func showAbout() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString(
            string: InterfaceLanguage.text("Runs the Claude Code, Codex or Antigravity installed on this Mac for Dicavo.") + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]
        )
        credits.append(NSAttributedString(
            string: "dicavo.eu",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .link: Self.downloadPageURL]
        ))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private func showWelcome() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = InterfaceLanguage.text("Dicavo CLI Bridge runs in the menu bar")
        alert.informativeText = InterfaceLanguage.text("Look for ›D at the top right of the screen. From there you can check your tools, start the bridge at login and quit it.\n\nShould the bridge check once a day whether a new version is available? It then downloads a small file from dicavo.eu; nothing about your meetings or tools is sent. You can change this in the menu at any time.")
        alert.addButton(withTitle: InterfaceLanguage.text("Check for updates automatically"))
        alert.addButton(withTitle: InterfaceLanguage.text("Not now"))
        if alert.runModal() == .alertFirstButtonReturn {
            setAutomaticChecks(true)
        }
    }

    private func showUpToDate() {
        alert(
            InterfaceLanguage.text("Dicavo CLI Bridge is up to date"),
            InterfaceLanguage.text("Version \(BridgeModel.version) is the newest available.")
        )
    }

    private func showRequiresNewerSystem(_ manifest: BridgeUpdateManifest) {
        alert(
            InterfaceLanguage.text("Version \(manifest.version) needs a newer macOS"),
            InterfaceLanguage.text("Dicavo CLI Bridge \(manifest.version) requires macOS \(manifest.minimumSystemVersion) or later. This version keeps working.")
        )
    }

    private func showFailure(_ message: String) {
        alert(InterfaceLanguage.text("Could not check for updates"), message, showsDownloadPage: true)
    }

    private func offerInstall(_ manifest: BridgeUpdateManifest) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = InterfaceLanguage.text("Version \(manifest.version) is available")
        alert.informativeText = InterfaceLanguage.text("You have \(BridgeModel.version). The bridge downloads the update from dicavo.eu, checks that it is signed by the Dicavo developer and notarized by Apple, replaces itself and starts again.")
        alert.addButton(withTitle: InterfaceLanguage.text("Install and restart"))
        alert.addButton(withTitle: InterfaceLanguage.text("Later"))
        if manifest.releaseNotesURL != nil {
            alert.addButton(withTitle: InterfaceLanguage.text("What's new"))
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await install(manifest) }
        case .alertThirdButtonReturn:
            if let notes = manifest.releaseNotesURL { NSWorkspace.shared.open(notes) }
        default:
            break
        }
    }

    private func alert(_ title: String, _ message: String, showsDownloadPage: Bool = false) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: InterfaceLanguage.text("OK"))
        if showsDownloadPage {
            alert.addButton(withTitle: InterfaceLanguage.text("Open download page"))
        }
        if alert.runModal() == .alertSecondButtonReturn {
            openDownloadPage()
        }
    }
}
