#if os(macOS)
import CryptoKit
import Foundation
import Security

/// Downloads a published bridge, proves it is the one that was published and
/// that it comes from the same developer, and puts it in place of the running
/// copy.
///
/// Every check runs against the staged copy that will be installed, not the
/// disk image it came from, so nothing can change between checking and
/// installing. Any failure leaves the running bridge untouched.
struct BridgeUpdateInstaller: Sendable {
    /// The name the DMG ships the app under (`scripts/make-dmg.sh`).
    static let applicationName = "Dicavo CLI Bridge.app"
    static let teamIdentifier = "H8LTS9AT3K"

    let session: URLSession
    let installedApplication: URL
    let bundleIdentifier: String
    let currentBuild: Int

    init(
        session: URLSession = BridgeUpdateChecker.makeSession(),
        installedApplication: URL = Bundle.main.bundleURL,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "",
        currentBuild: Int = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    ) {
        self.session = session
        self.installedApplication = installedApplication
        self.bundleIdentifier = bundleIdentifier
        self.currentBuild = currentBuild
    }

    /// A verified update, staged next to the installed app and ready to swap.
    struct StagedUpdate: Sendable {
        let manifest: BridgeUpdateManifest
        let image: URL
        let application: URL
        let workDirectory: URL
    }

    // MARK: Download and verification

    func stage(_ manifest: BridgeUpdateManifest) async throws -> StagedUpdate {
        try manifest.validate()
        guard manifest.build > currentBuild else { throw BridgeUpdateError.notNewer }
        // Next to the installed app, so the final swap is a rename on one
        // volume. A copy that cannot be replaced in place (a read-only disk
        // image, App Translocation) stages in the temporary folder instead
        // and is handed over for a manual install.
        let work = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: Self.canReplace(installedApplication) ? installedApplication : FileManager.default.temporaryDirectory,
            create: true
        )
        do {
            let image = try await download(manifest, into: work)
            let application = try Self.copyApplication(outOf: image, into: work)
            try verify(application, against: manifest)
            return StagedUpdate(manifest: manifest, image: image, application: application, workDirectory: work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    private func download(_ manifest: BridgeUpdateManifest, into directory: URL) async throws -> URL {
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(for: URLRequest(url: manifest.url))
        } catch {
            throw BridgeUpdateError.network(error.localizedDescription)
        }
        try BridgeUpdateChecker.check(response)
        let image = directory.appendingPathComponent(manifest.url.lastPathComponent.isEmpty ? "update.dmg" : manifest.url.lastPathComponent)
        try FileManager.default.moveItem(at: temporary, to: image)
        try Self.checkIntegrity(of: image, against: manifest)
        return image
    }

    static func checkIntegrity(of file: URL, against manifest: BridgeUpdateManifest) throws {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        guard size == manifest.size else { throw BridgeUpdateError.sizeMismatch }
        guard try sha256(of: file) == manifest.sha256.lowercased() else { throw BridgeUpdateError.checksumMismatch }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The two ways to attach an image read-only and out of sight.
    /// `diskutil image attach` comes first, because macOS 27 reports
    /// `hdiutil` as deprecated in its favour. Homebrew dates `diskutil image
    /// attach` to macOS 13, below the bridge's 14.2, but only macOS 27 was
    /// tried here, so `hdiutil` stays the fallback when `diskutil` fails.
    enum DiskImageTool: CaseIterable, Sendable {
        case diskutil
        case hdiutil
    }

    struct DiskImageCommand: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    /// An attached image: where it is mounted, and its whole-disk device
    /// when the tool reported one, for a forced detach.
    struct AttachedImage: Equatable, Sendable {
        let mountPoint: URL
        let device: String?
    }

    static func attachCommand(
        _ tool: DiskImageTool,
        image: URL,
        mountRoot: URL,
        mountName: String = UUID().uuidString
    ) -> DiskImageCommand {
        switch tool {
        case .diskutil:
            // `diskutil` has no `-mountrandom`: a fresh name in the private
            // work folder does the same, and `diskutil` creates the folder
            // and removes it on eject. It has no `-noautoopen` either; a
            // volume hidden from Finder is not opened in it.
            return DiskImageCommand(executable: "/usr/sbin/diskutil", arguments: [
                "image", "attach", "--plist", "--readOnly", "--nobrowse",
                "--mountPoint", mountRoot.appendingPathComponent(mountName, isDirectory: true).path,
                image.path
            ])
        case .hdiutil:
            return DiskImageCommand(executable: "/usr/bin/hdiutil", arguments: [
                "attach", "-readonly", "-nobrowse", "-noautoopen",
                "-mountrandom", mountRoot.path, "-plist", image.path
            ])
        }
    }

    /// The ordinary detach, then what to run when it fails. `diskutil image`
    /// has no detach of its own; `diskutil eject` releases the whole image.
    static func detachCommands(
        for image: AttachedImage,
        attachedWith tool: DiskImageTool
    ) -> (ordinary: DiskImageCommand, forced: [DiskImageCommand]) {
        switch tool {
        case .diskutil:
            let diskutil = "/usr/sbin/diskutil"
            var forced = [DiskImageCommand(executable: diskutil, arguments: ["unmount", "force", image.mountPoint.path])]
            if let device = image.device {
                forced.append(DiskImageCommand(executable: diskutil, arguments: ["eject", device]))
            }
            return (DiskImageCommand(executable: diskutil, arguments: ["eject", image.mountPoint.path]), forced)
        case .hdiutil:
            let hdiutil = "/usr/bin/hdiutil"
            return (
                DiskImageCommand(executable: hdiutil, arguments: ["detach", image.mountPoint.path, "-quiet"]),
                [DiskImageCommand(executable: hdiutil, arguments: ["detach", image.mountPoint.path, "-force", "-quiet"])]
            )
        }
    }

    /// Runs one command line; the tests stand in for the disk image tools.
    typealias CommandRunner = (_ executable: String, _ arguments: [String]) throws -> ProcessResult

    /// Mounts the image read-only and out of sight, copies the app out with
    /// `ditto` (which keeps the signature intact), and always detaches.
    static func copyApplication(
        outOf image: URL,
        into directory: URL,
        isVolumeRoot: (URL) -> Bool = BridgeUpdateInstaller.isVolume,
        runner: CommandRunner = { try run($0, $1) }
    ) throws -> URL {
        let mountRoot = directory.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        var failures: [String] = []
        for tool in DiskImageTool.allCases {
            let command = attachCommand(tool, image: image, mountRoot: mountRoot)
            let foldersBefore = folders(in: mountRoot)
            guard let attach = try? runner(command.executable, command.arguments) else {
                failures.append("\(command.executable) could not be started.")
                continue
            }
            guard attach.status == 0 else {
                failures.append(attach.errorText)
                continue
            }
            let attached: AttachedImage
            do {
                attached = try attachedImage(fromAttachOutput: attach.output)
            } catch {
                // The tool attached the image but did not describe it as
                // expected: whatever it mounted is detached, and the next
                // tool tries, rather than leaving a volume behind.
                // Only the root of a volume made in the work folder is
                // detached: any other path the output names would make
                // `diskutil` force off the volume that holds it. Both tools
                // mount directly in `mountRoot`; the parent is compared, as
                // it always exists and resolves the same way.
                let root = mountRoot.resolvingSymlinksInPath().path
                let leftovers = (mountPoints(listedIn: attach.output)
                    + folders(in: mountRoot).subtracting(foldersBefore))
                    .filter {
                        $0.deletingLastPathComponent().resolvingSymlinksInPath().path == root
                            && isVolumeRoot($0)
                    }
                for mountPoint in Set(leftovers) {
                    detach(AttachedImage(mountPoint: mountPoint, device: nil), attachedWith: tool, runner: runner)
                }
                if case let .mountFailed(message)? = error as? BridgeUpdateError {
                    failures.append(message)
                } else {
                    failures.append(error.localizedDescription)
                }
                continue
            }
            defer { detach(attached, attachedWith: tool, runner: runner) }
            return try copyApplication(from: attached.mountPoint, into: directory, runner: runner)
        }
        throw BridgeUpdateError.mountFailed(failures.joined(separator: "\n"))
    }

    private static func copyApplication(from mountPoint: URL, into directory: URL, runner: CommandRunner) throws -> URL {
        let source = mountPoint.appendingPathComponent(applicationName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BridgeUpdateError.applicationMissing
        }
        let destination = directory.appendingPathComponent(applicationName, isDirectory: true)
        let copy = try runner("/usr/bin/ditto", [source.path, destination.path])
        guard copy.status == 0 else { throw BridgeUpdateError.installFailed(copy.errorText) }
        return destination
    }

    private static func detach(_ image: AttachedImage, attachedWith tool: DiskImageTool, runner: CommandRunner) {
        let commands = detachCommands(for: image, attachedWith: tool)
        guard (try? runner(commands.ordinary.executable, commands.ordinary.arguments))?.status != 0 else { return }
        for command in commands.forced {
            _ = try? runner(command.executable, command.arguments)
        }
    }

    /// Every mount point an attach plist names, however many; empty when
    /// the output is not a plist at all.
    static func mountPoints(listedIn data: Data) -> [URL] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { return [] }
        return entities.compactMap { $0["mount-point"] as? String }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func folders(in directory: URL) -> Set<URL> {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        return Set(contents.map(\.standardizedFileURL))
    }

    /// Only the root of a volume is detached: `diskutil` handed any other
    /// folder would eject or force-unmount the volume that holds it.
    static func isVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
    }

    /// The single mount point the attach plist reports.
    static func mountPoint(fromAttachOutput data: Data) throws -> URL {
        try attachedImage(fromAttachOutput: data).mountPoint
    }

    /// `diskutil image attach --plist` writes the same `system-entities` as
    /// `hdiutil attach -plist`; only the device is spelled without `/dev/`.
    static func attachedImage(fromAttachOutput data: Data) throws -> AttachedImage {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { throw BridgeUpdateError.mountFailed("Unexpected disk image tool output.") }
        let points = entities.compactMap { $0["mount-point"] as? String }
        guard points.count == 1, let point = points.first else {
            throw BridgeUpdateError.mountFailed("Expected one mounted volume, found \(points.count).")
        }
        let device = entities
            .compactMap { ($0["dev-entry"] as? String)?.replacingOccurrences(of: "/dev/", with: "") }
            .first { $0.range(of: "^disk[0-9]+$", options: .regularExpression) != nil }
        return AttachedImage(mountPoint: URL(fileURLWithPath: point, isDirectory: true), device: device)
    }

    func verify(_ application: URL, against manifest: BridgeUpdateManifest) throws {
        try Self.verifySignature(of: application, requirements: [
            try Self.runningDesignatedRequirement(),
            try Self.requirement(Self.developerRequirement(bundleIdentifier: bundleIdentifier))
        ])
        let info = try Self.infoDictionary(of: application)
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else { throw BridgeUpdateError.wrongBundle }
        guard let build = (info["CFBundleVersion"] as? String).flatMap(Int.init), build == manifest.build else {
            throw BridgeUpdateError.buildMismatch
        }
        guard build > currentBuild else { throw BridgeUpdateError.notNewer }
        // Never trade down: a notarised bridge only accepts a notarised
        // update. A locally signed build can still exercise the whole path.
        if Self.passesGatekeeper(installedApplication), !Self.passesGatekeeper(application) {
            throw BridgeUpdateError.notNotarized
        }
    }

    static func developerRequirement(bundleIdentifier: String) -> String {
        "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    static func requirement(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw BridgeUpdateError.signatureInvalid(message(for: status))
        }
        return requirement
    }

    /// Who signed the running bridge. Requiring the update to satisfy it
    /// ties the update to the same developer, not to one certificate, so it
    /// survives the certificate's renewal.
    static func runningDesignatedRequirement() throws -> SecRequirement {
        var code: SecCode?
        var status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else { throw BridgeUpdateError.signatureInvalid(message(for: status)) }
        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { throw BridgeUpdateError.signatureInvalid(message(for: status)) }
        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(staticCode, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw BridgeUpdateError.signatureInvalid(message(for: status))
        }
        return requirement
    }

    static func verifySignature(of application: URL, requirements: [SecRequirement]) throws {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(application as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw BridgeUpdateError.signatureInvalid(message(for: status)) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        for requirement in requirements {
            var error: Unmanaged<CFError>?
            status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
            guard status == errSecSuccess else {
                let detail = error?.takeRetainedValue().localizedDescription ?? message(for: status)
                throw BridgeUpdateError.signatureInvalid(detail)
            }
        }
    }

    /// Gatekeeper's verdict on launching the app, which for a Developer ID
    /// build means it is notarised. `SecAssessment` is not available to
    /// Swift, so this asks `spctl`, as the DMG script does.
    static func passesGatekeeper(_ application: URL) -> Bool {
        let result = try? run("/usr/sbin/spctl", ["--assess", "--type", "execute", application.path])
        return result?.status == 0
    }

    static func infoDictionary(of application: URL) throws -> [String: Any] {
        let url = application.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw BridgeUpdateError.wrongBundle }
        return info
    }

    // MARK: Installation

    /// Whether the running copy can be replaced where it is. An app started
    /// from the disk image, from App Translocation or from a folder the user
    /// cannot write is updated by hand instead.
    static func canReplace(_ application: URL) -> Bool {
        let path = application.standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return false }
        if (try? application.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true { return false }
        let fileManager = FileManager.default
        return fileManager.isWritableFile(atPath: application.deletingLastPathComponent().path)
            && fileManager.isWritableFile(atPath: path)
    }

    /// Swaps the staged app in, after checking it once more: the staging
    /// directory is the user's, and time has passed since `stage`.
    func install(_ update: StagedUpdate) throws {
        try verify(update.application, against: update.manifest)
        do {
            _ = try FileManager.default.replaceItemAt(installedApplication, withItemAt: update.application)
        } catch {
            throw BridgeUpdateError.installFailed(error.localizedDescription)
        }
    }

    /// Starts the installed app once the process `pid` has exited, so the
    /// old and the new bridge never listen at the same time.
    static func relaunch(_ application: URL, after pid: Int32) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "sh", String(pid), application.path
        ]
        try process.run()
    }

    /// Moves the verified image to Downloads for a manual install, and
    /// returns where it went.
    static func keepImageForManualInstall(_ update: StagedUpdate) throws -> URL {
        let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var destination = downloads.appendingPathComponent(update.image.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = update.image.deletingPathExtension().lastPathComponent
            destination = downloads.appendingPathComponent("\(base) \(counter).dmg")
            counter += 1
        }
        try FileManager.default.moveItem(at: update.image, to: destination)
        return destination
    }

    static func discard(_ update: StagedUpdate) {
        try? FileManager.default.removeItem(at: update.workDirectory)
    }

    // MARK: Helpers

    struct ProcessResult {
        var status: Int32
        var output: Data
        var error: Data

        var errorText: String {
            let text = String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "exit status \(status)" : text
        }
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Drain both pipes before waiting, so a chatty child cannot block on
        // a full pipe while this waits for it to exit.
        let group = DispatchGroup()
        nonisolated(unsafe) var errorData = Data()
        group.enter()
        DispatchQueue.global().async {
            errorData = error.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, output: outputData, error: errorData)
    }

    private static func message(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
#endif
