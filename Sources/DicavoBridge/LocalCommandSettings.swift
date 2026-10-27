import AppKit
import SwiftUI

/// The window where the local command is set up — the only place it can
/// be. Dicavo, which is sandboxed, has no say in what the bridge runs.
@MainActor
final class LocalCommandWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(model: BridgeModel) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = LocalCommandSettingsView(
            initial: model.localCommand,
            onSave: { [weak self, weak model] configuration in
                model?.saveLocalCommand(configuration)
                self?.window?.close()
            },
            onCancel: { [weak self] in self?.window?.close() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = InterfaceLanguage.text("Local command")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Closed with Save, Cancel or the close button alike: the next opening
    /// starts again from what is saved.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

/// The form itself. Edits stay in the window until Save, so a half-typed
/// path or argument never reaches a request Dicavo is waiting on.
struct LocalCommandSettingsView: View {
    @State private var executablePath: String
    @State private var argumentLines: String
    @State private var timeoutSeconds: Int
    @State private var isEnabled: Bool
    let onSave: (BridgeLocalCommandConfiguration) -> Void
    let onCancel: () -> Void

    init(
        initial: BridgeLocalCommandConfiguration,
        onSave: @escaping (BridgeLocalCommandConfiguration) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _executablePath = State(initialValue: initial.executablePath)
        _argumentLines = State(initialValue: BridgeLocalCommandConfiguration.lines(from: initial.arguments))
        _timeoutSeconds = State(initialValue: initial.timeoutSeconds)
        _isEnabled = State(initialValue: initial.isEnabled)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var draft: BridgeLocalCommandConfiguration {
        BridgeLocalCommandConfiguration(
            executablePath: executablePath.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: BridgeLocalCommandConfiguration.arguments(fromLines: argumentLines),
            timeoutSeconds: timeoutSeconds,
            isEnabled: isEnabled
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: t("Dicavo CLI Bridge can run one command of your choice for Dicavo, for example llm or ollama run with a model. The command receives the meeting transcript, notes and instructions on standard input and writes the analysis as Markdown to standard output. Dicavo cannot see what the command does with the transcript: if the command sends it to a server, that is where it goes."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(t("Enabled"), isOn: $isEnabled)

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: t("Executable"))
                HStack {
                    TextField(text: $executablePath, prompt: Text(verbatim: "/opt/homebrew/bin/ollama")) {
                        Text(verbatim: t("Executable"))
                    }
                    .labelsHidden()
                    Button(t("Choose…")) { chooseExecutable() }
                }
                Text(verbatim: executableStatus)
                    .font(.caption)
                    .foregroundStyle(executableIsRunnable ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: t("Arguments"))
                TextEditor(text: $argumentLines)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
                Text(verbatim: t("One argument per line, passed exactly as written. There is no shell: quotes, variables and redirections have no special meaning."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(verbatim: t("Timeout (seconds)"))
                    TextField(value: $timeoutSeconds, format: .number) {
                        Text(verbatim: t("Timeout (seconds)"))
                    }
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    Stepper(
                        value: $timeoutSeconds,
                        in: BridgeLocalCommandConfiguration.timeoutRange,
                        step: 30
                    ) {
                        Text(verbatim: t("Timeout (seconds)"))
                    }
                    .labelsHidden()
                }
                Text(verbatim: t("At most \(Int64(BridgeLocalCommandConfiguration.timeoutRange.upperBound)) seconds, the longest Dicavo waits for one answer."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(t("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(t("Save")) { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var executableIsRunnable: Bool {
        switch draft.availability() {
        case .ready, .disabled: return true
        case .notSetUp, .notFound, .notExecutable: return false
        }
    }

    private var executableStatus: String {
        switch draft.availability() {
        case .notSetUp:
            return t("Enter the full path of the program, for example /opt/homebrew/bin/ollama.")
        case .notFound:
            return t("There is no program at this path. Enter the full path, starting with /.")
        case .notExecutable:
            return t("This file cannot be run. Choose the program itself.")
        case .ready, .disabled:
            return t("Found and executable.")
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Kept as chosen: a Homebrew link such as /opt/homebrew/bin/ollama
        // survives an upgrade, the versioned file it points to does not.
        panel.resolvesAliases = false
        // Some tools ship inside an application bundle.
        panel.treatsFilePackagesAsDirectories = true
        let current = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        let start = executablePath.hasPrefix("/")
            ? current
            : ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        panel.directoryURL = start
        if panel.runModal() == .OK, let url = panel.url {
            executablePath = url.path
        }
    }

    /// Like the menu, the window speaks the language Dicavo chose.
    private func t(_ text: LocalizedStringResource) -> String {
        InterfaceLanguage.text(text)
    }
}
