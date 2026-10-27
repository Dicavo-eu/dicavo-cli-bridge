import AppKit
import SwiftUI

/// A menu-bar item and one small window, where the local command is set up.
/// The bridge listens, it shows what it found, it can be told to start at
/// login, it keeps itself up to date when asked to, and it can be quit.
@main
struct DicavoBridgeApp: App {
    @StateObject private var model = BridgeModel()
    @StateObject private var updates = BridgeUpdateController()
    @State private var localCommandWindow = LocalCommandWindowController()

    var body: some Scene {
        MenuBarExtra {
            Button {
                updates.showAbout()
            } label: {
                Label {
                    Text(verbatim: t(LocalizedStringResource("Dicavo CLI Bridge \(BridgeModel.version)", comment: "Bridge name and version, the first line of the menu")))
                } icon: {
                    Image("DicavoIcon")
                }
                // A menu shows a label's icon only when asked to.
                .labelStyle(.titleAndIcon)
            }
            Text(verbatim: statusLine)
            if let error = model.descriptorError {
                Text(verbatim: error).font(.caption)
            }
            Divider()
            Menu(t("AI tools (\(usableToolCount))")) {
                if model.toolStatuses.isEmpty {
                    Text(verbatim: model.isRefreshingTools ? t("Checking installed tools…") : t("No tools checked yet"))
                }
                ForEach(model.toolStatuses, id: \.tool) { status in
                    // A menu item whose label holds two Text views shows the second as its subtitle, small under the title.
                    let line = toolLine(status)
                    Button {} label: {
                        Text(verbatim: line.title)
                        if let path = line.path { Text(verbatim: path) }
                    }
                    .disabled(true)
                    if status.executablePath != nil, status.isAuthenticated == false, let command = status.loginCommand {
                        Button(t("Copy sign-in command for \(status.tool.displayName)")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                    }
                }
                Button(t("Local command…")) {
                    localCommandWindow.show(model: model)
                }
                Button(t("Check tools again")) {
                    Task { await model.refreshTools() }
                }
                .disabled(model.isRefreshingTools)
            }
            Divider()
            Toggle(t("Launch at login"), isOn: Binding(
                get: { model.launchAtLoginEnabled },
                set: { model.setLaunchAtLogin($0) }
            ))
            Divider()
            updateSection
            Divider()
            Button(t("About Dicavo CLI Bridge")) {
                updates.showAbout()
            }
            Button(t("Quit Dicavo CLI Bridge")) {
                model.stop()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(nsImage: BridgeStatusIcon.image(for: iconState))
                .accessibilityLabel(BridgeStatusIcon.accessibilityLabel(for: iconState))
        }
        .onChange(of: model.serverState, initial: true) { _, state in
            switch state {
            case .starting:
                Task { await model.start() }
            case .listening:
                updates.start(model: model)
            case .failed:
                break
            }
        }
    }

    private var usableToolCount: Int {
        model.toolStatuses.filter(\.isUsable).count
    }

    private var iconState: BridgeStatusIcon.State {
        switch model.serverState {
        case .starting: return .starting
        case .listening: return model.toolStatuses.contains(where: \.isUsable) ? .ready : .noUsableTool
        case .failed: return .failed
        }
    }

    @ViewBuilder
    private var updateSection: some View {
        switch updates.phase {
        case let .available(manifest):
            Button(t("Install version \(manifest.version)…")) {
                Task { await updates.install(manifest) }
            }
        case let .requiresNewerSystem(manifest):
            Text(verbatim: t("Version \(manifest.version) requires macOS \(manifest.minimumSystemVersion)"))
        case .checking:
            Text(verbatim: t("Checking for updates…"))
        case let .downloading(manifest):
            Text(verbatim: t("Downloading and verifying version \(manifest.version)…"))
        case let .waitingForRequests(manifest):
            Text(verbatim: t("Version \(manifest.version) installs when the current analysis finishes"))
        case let .installing(manifest):
            Text(verbatim: t("Installing version \(manifest.version)…"))
        case let .failed(message):
            Text(verbatim: t("Update: \(message)")).font(.caption)
            Button(t("Open download page")) {
                updates.openDownloadPage()
            }
        case .idle, .upToDate:
            EmptyView()
        }
        Button(t("Check for updates…")) {
            Task { await updates.check(userInitiated: true) }
        }
        .disabled(updates.phase.isBusy)
        Toggle(t("Check for updates automatically"), isOn: Binding(
            get: { updates.automaticChecksEnabled },
            set: { updates.setAutomaticChecks($0) }
        ))
        if !updates.automaticChecksEnabled {
            Text(verbatim: t("Off – check for updates manually")).font(.caption)
        } else if let lastCheck = updates.lastCheck {
            Text(verbatim: t("Last checked \(lastCheck.formatted(date: .abbreviated, time: .shortened))")).font(.caption)
        }
    }

    /// The menu is AppKit's, so its text is resolved here, in the language
    /// Dicavo chose, rather than by the SwiftUI environment.
    private func t(_ text: LocalizedStringResource) -> String {
        InterfaceLanguage.text(text)
    }

    private var statusLine: String {
        switch model.serverState {
        case .starting:
            return InterfaceLanguage.text("Starting…")
        case let .listening(port):
            // A port is not a quantity: no digit grouping ("48 123").
            return InterfaceLanguage.text("Listening on 127.0.0.1:\(String(port)) for Dicavo")
        case let .failed(reason):
            return InterfaceLanguage.text("Not listening: \(reason)")
        }
    }

    private func toolLine(_ status: BridgeToolStatus) -> (title: String, path: String?) {
        if let availability = status.localCommand {
            let path = status.executablePath.flatMap { $0.isEmpty ? nil : $0 }
            switch availability {
            case .ready: return (InterfaceLanguage.text("Local command: ready"), path)
            case .disabled: return (InterfaceLanguage.text("Local command: off"), path)
            case .notFound: return (InterfaceLanguage.text("Local command: not found"), path)
            case .notExecutable: return (InterfaceLanguage.text("Local command: not executable"), path)
            case .notSetUp: return (InterfaceLanguage.text("Local command: not set up"), nil)
            }
        }
        let name = status.tool.displayName
        guard let path = status.executablePath else {
            return (InterfaceLanguage.text("\(name): not installed"), nil)
        }
        let version = status.version.map { " \($0)" } ?? ""
        switch status.isAuthenticated {
        case .some(true): return (InterfaceLanguage.text("\(name)\(version): ready"), path)
        case .some(false): return (InterfaceLanguage.text("\(name)\(version): not signed in"), path)
        case nil: return (name, path)
        }
    }
}
