import Foundation
import XCTest
@testable import BridgeCore

/// Unit tests for the bridge updater: what the manifest accepts, when a
/// check is due, what the installer proves about a downloaded bundle, and
/// what the checker fetches over a stubbed session.
final class BridgeUpdateTests: XCTestCase {
    // MARK: Fixtures

    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories = []
        StubURLProtocol.handler = nil
        StubURLProtocol.requestCount = 0
        super.tearDown()
    }

    /// JSON for a valid manifest, with single-field overrides for the
    /// rejection tests.
    private func manifestJSON(
        schemaVersion: Int = 1,
        version: String = "1.1",
        build: Int = 4,
        minimumSystemVersion: String = "14.2",
        url: String = "https://dicavo.eu/downloads/DicavoCLIBridge-1.1-abc1234.dmg",
        sha256: String = String(repeating: "a", count: 64),
        size: Int64 = 452608,
        releaseNotesURL: String? = "https://dicavo.eu/en/bridge.html",
        extra: [String: Any] = [:]
    ) -> Data {
        var object: [String: Any] = [
            "schemaVersion": schemaVersion,
            "version": version,
            "build": build,
            "minimumSystemVersion": minimumSystemVersion,
            "url": url,
            "sha256": sha256,
            "size": size,
        ]
        if let releaseNotesURL {
            object["releaseNotesURL"] = releaseNotesURL
        }
        for (key, value) in extra {
            object[key] = value
        }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func decode(_ data: Data) throws -> BridgeUpdateManifest {
        try BridgeUpdateManifest.decode(data)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BridgeUpdateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func assertThrows(
        _ expected: BridgeUpdateError,
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try body()
            XCTFail("Expected \(expected), got success.", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? BridgeUpdateError, expected, file: file, line: line)
        }
    }

    private func assertThrowsAsync(
        _ expected: BridgeUpdateError,
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("Expected \(expected), got success.", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? BridgeUpdateError, expected, file: file, line: line)
        }
    }

    private func assertThrowsSignatureInvalid(
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case .signatureInvalid = error as? BridgeUpdateError else {
                return XCTFail("Expected signatureInvalid, got \(error).", file: file, line: line)
            }
        }
    }

    // MARK: Manifest decoding

    func testManifestDecodesWithAllFields() throws {
        let manifest = try decode(manifestJSON())
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.version, "1.1")
        XCTAssertEqual(manifest.build, 4)
        XCTAssertEqual(manifest.minimumSystemVersion, "14.2")
        XCTAssertEqual(manifest.url, URL(string: "https://dicavo.eu/downloads/DicavoCLIBridge-1.1-abc1234.dmg"))
        XCTAssertEqual(manifest.sha256, String(repeating: "a", count: 64))
        XCTAssertEqual(manifest.size, 452608)
        XCTAssertEqual(manifest.releaseNotesURL, URL(string: "https://dicavo.eu/en/bridge.html"))
    }

    func testManifestAcceptsMissingReleaseNotes() throws {
        let manifest = try decode(manifestJSON(releaseNotesURL: nil))
        XCTAssertNil(manifest.releaseNotesURL)
    }

    func testManifestRejectsUnknownSchemaVersion() {
        assertThrows(.unsupportedManifest) {
            _ = try decode(manifestJSON(schemaVersion: 2))
        }
    }

    func testManifestRejectsPlainHTTP() {
        assertThrows(.untrustedURL) {
            _ = try decode(manifestJSON(url: "http://dicavo.eu/downloads/DicavoCLIBridge-1.1-abc1234.dmg"))
        }
    }

    func testManifestRejectsLookalikeHost() {
        assertThrows(.untrustedURL) {
            _ = try decode(manifestJSON(url: "https://dicavo.eu.example.com/downloads/DicavoCLIBridge-1.1-abc1234.dmg"))
        }
    }

    func testManifestRejectsExplicitPort() {
        assertThrows(.untrustedURL) {
            _ = try decode(manifestJSON(url: "https://dicavo.eu:8443/x.dmg"))
        }
    }

    func testManifestRejectsCredentialsInURL() {
        assertThrows(.untrustedURL) {
            _ = try decode(manifestJSON(url: "https://user:pw@dicavo.eu/x.dmg"))
        }
    }

    func testManifestRejectsUntrustedReleaseNotes() {
        assertThrows(.untrustedURL) {
            _ = try decode(manifestJSON(releaseNotesURL: "https://example.com/"))
        }
    }

    func testManifestRejectsShortSha256() {
        assertThrows(.malformedManifest) {
            _ = try decode(manifestJSON(sha256: String(repeating: "a", count: 63)))
        }
    }

    func testManifestRejectsNonHexSha256() {
        assertThrows(.malformedManifest) {
            _ = try decode(manifestJSON(sha256: String(repeating: "a", count: 63) + "g"))
        }
    }

    func testManifestRejectsZeroBuild() {
        assertThrows(.malformedManifest) {
            _ = try decode(manifestJSON(build: 0))
        }
    }

    func testManifestRejectsZeroSize() {
        assertThrows(.malformedManifest) {
            _ = try decode(manifestJSON(size: 0))
        }
    }

    func testManifestRejectsOversizedImage() {
        assertThrows(.malformedManifest) {
            _ = try decode(manifestJSON(size: BridgeUpdateManifest.maximumImageBytes + 1))
        }
    }

    func testManifestRejectsNonNumericMinimumSystemVersion() {
        assertThrows(.malformedManifest) {
            _ = try decode(manifestJSON(minimumSystemVersion: "14.x"))
        }
    }

    func testManifestRejectsInvalidJSON() {
        assertThrows(.malformedManifest) {
            _ = try decode(Data("not json".utf8))
        }
    }

    func testManifestRejectsPaddedJSON() {
        let padded = manifestJSON(extra: ["padding": String(repeating: "x", count: BridgeUpdateManifest.maximumManifestBytes)])
        XCTAssertGreaterThan(padded.count, BridgeUpdateManifest.maximumManifestBytes)
        assertThrows(.malformedManifest) {
            _ = try decode(padded)
        }
    }

    // MARK: System version parsing

    func testSystemVersionParsesMajorOnly() throws {
        let version = try XCTUnwrap(BridgeUpdateManifest.systemVersion("14"))
        XCTAssertEqual(version.majorVersion, 14)
        XCTAssertEqual(version.minorVersion, 0)
        XCTAssertEqual(version.patchVersion, 0)
    }

    func testSystemVersionParsesThreeComponents() throws {
        let version = try XCTUnwrap(BridgeUpdateManifest.systemVersion("14.2.1"))
        XCTAssertEqual(version.majorVersion, 14)
        XCTAssertEqual(version.minorVersion, 2)
        XCTAssertEqual(version.patchVersion, 1)
    }

    func testSystemVersionRejectsMalformedInput() {
        XCTAssertNil(BridgeUpdateManifest.systemVersion(""))
        XCTAssertNil(BridgeUpdateManifest.systemVersion("14..2"))
        XCTAssertNil(BridgeUpdateManifest.systemVersion("1.2.3.4"))
        XCTAssertNil(BridgeUpdateManifest.systemVersion("-1"))
    }

    // MARK: Availability

    func testAvailabilityIsUpToDateAtTheSameBuild() throws {
        let manifest = try decode(manifestJSON())
        XCTAssertEqual(manifest.availability(currentBuild: 4, system: OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)), .upToDate)
    }

    func testAvailabilityIsUpToDateOnNewerBuild() throws {
        let manifest = try decode(manifestJSON())
        XCTAssertEqual(manifest.availability(currentBuild: 5, system: OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)), .upToDate)
    }

    func testAvailabilityOffersUpdateOnOlderBuild() throws {
        let manifest = try decode(manifestJSON())
        guard case .available = manifest.availability(currentBuild: 3, system: OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)) else {
            return XCTFail("Expected available.")
        }
    }

    func testAvailabilityRequiresNewerSystemBelowMinimum() throws {
        let manifest = try decode(manifestJSON())
        guard case .requiresNewerSystem = manifest.availability(currentBuild: 3, system: OperatingSystemVersion(majorVersion: 14, minorVersion: 1, patchVersion: 0)) else {
            return XCTFail("Expected requiresNewerSystem.")
        }
    }

    // MARK: Offer from a found manifest

    private let macOS27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)

    /// A newer manifest this Mac can run is offered by its version alone.
    func testOfferForAnInstallableManifest() throws {
        let manifest = try decode(manifestJSON(build: 9))
        XCTAssertEqual(
            manifest.offer(currentBuild: 5, system: macOS27),
            BridgeUpdateOffer(version: "1.1")
        )
    }

    /// A newer manifest this Mac cannot run still reports its version, plus
    /// the macOS it needs.
    func testOfferCarriesANewerSystemRequirement() throws {
        let manifest = try decode(manifestJSON(build: 9, minimumSystemVersion: "28.0"))
        XCTAssertEqual(
            manifest.offer(currentBuild: 5, system: macOS27),
            BridgeUpdateOffer(version: "1.1", requiredSystemVersion: "28.0")
        )
    }

    /// A manifest the running build has caught up with, as after the update
    /// was installed, stops being offered.
    func testNoOfferOnceTheUpdateIsInstalled() throws {
        let manifest = try decode(manifestJSON(build: 9))
        XCTAssertNil(manifest.offer(currentBuild: 9, system: macOS27))
        XCTAssertNil(manifest.offer(currentBuild: 10, system: macOS27))
    }

    // MARK: Schedule

    func testScheduleIsQuietWhenDisabled() {
        XCTAssertFalse(BridgeUpdateSchedule.isDue(enabled: false, lastCheck: nil, now: Date(timeIntervalSince1970: 1_000)))
    }

    func testScheduleIsDueWhenNeverChecked() {
        XCTAssertTrue(BridgeUpdateSchedule.isDue(enabled: true, lastCheck: nil, now: Date(timeIntervalSince1970: 1_000)))
    }

    func testScheduleWaitsNearlyADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(BridgeUpdateSchedule.isDue(enabled: true, lastCheck: now.addingTimeInterval(-23 * 60 * 60), now: now))
    }

    func testScheduleIsDueAfterADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(BridgeUpdateSchedule.isDue(enabled: true, lastCheck: now.addingTimeInterval(-24 * 60 * 60), now: now))
    }

    func testScheduleIsDueWhenClockMovedBack() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(BridgeUpdateSchedule.isDue(enabled: true, lastCheck: now.addingTimeInterval(60 * 60), now: now))
    }

    // MARK: Checker

    func testCheckerReturnsAValidManifest() async throws {
        let data = manifestJSON()
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url, URL(string: "https://dicavo.eu/bridge/latest.json"))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
        let checker = makeChecker(feedURL: URL(string: "https://dicavo.eu/bridge/latest.json")!)
        let manifest = try await checker.fetchManifest()
        XCTAssertEqual(manifest, try BridgeUpdateManifest.decode(data))
    }

    func testCheckerRejectsHTTP404() async {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let checker = makeChecker(feedURL: URL(string: "https://dicavo.eu/bridge/latest.json")!)
        await assertThrowsAsync(.httpStatus(404)) {
            _ = try await checker.fetchManifest()
        }
    }

    func testCheckerRejectsAResponseFromAnotherHost() async {
        StubURLProtocol.handler = { _ in
            let response = HTTPURLResponse(url: URL(string: "https://example.com/latest.json")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let checker = makeChecker(feedURL: URL(string: "https://dicavo.eu/bridge/latest.json")!)
        await assertThrowsAsync(.untrustedURL) {
            _ = try await checker.fetchManifest()
        }
    }

    func testCheckerRefusesAnUntrustedFeedWithoutRequestingIt() async {
        StubURLProtocol.handler = { _ in
            XCTFail("The stub must not be asked for an untrusted feed.")
            let response = HTTPURLResponse(url: URL(string: "https://dicavo.eu/bridge/latest.json")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let checker = makeChecker(feedURL: URL(string: "http://dicavo.eu/bridge/latest.json")!)
        await assertThrowsAsync(.untrustedURL) {
            _ = try await checker.fetchManifest()
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testCheckerReportsNetworkFailures() async {
        StubURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let checker = makeChecker(feedURL: URL(string: "https://dicavo.eu/bridge/latest.json")!)
        do {
            _ = try await checker.fetchManifest()
            XCTFail("Expected a network error.")
        } catch {
            guard case .network = error as? BridgeUpdateError else {
                return XCTFail("Expected network, got \(error).")
            }
        }
    }

    private func makeChecker(feedURL: URL) -> BridgeUpdateChecker {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return BridgeUpdateChecker(session: BridgeUpdateChecker.makeSession(configuration: configuration), feedURL: feedURL)
    }

    #if os(macOS)
    // MARK: Installer — integrity

    func testSha256MatchesKnownDigest() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("hello.bin")
        try Data("hello".utf8).write(to: file)
        XCTAssertEqual(try BridgeUpdateInstaller.sha256(of: file), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    func testCheckIntegrityAcceptsAMatchingFile() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("image.dmg")
        let payload = Data("hello".utf8)
        try payload.write(to: file)
        let manifest = try decode(manifestJSON(sha256: try BridgeUpdateInstaller.sha256(of: file), size: Int64(payload.count)))
        XCTAssertNoThrow(try BridgeUpdateInstaller.checkIntegrity(of: file, against: manifest))
    }

    func testCheckIntegrityRejectsAWrongSize() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("image.dmg")
        let payload = Data("hello".utf8)
        try payload.write(to: file)
        let manifest = try decode(manifestJSON(sha256: try BridgeUpdateInstaller.sha256(of: file), size: Int64(payload.count) + 1))
        assertThrows(.sizeMismatch) {
            try BridgeUpdateInstaller.checkIntegrity(of: file, against: manifest)
        }
    }

    func testCheckIntegrityRejectsAWrongChecksum() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("image.dmg")
        let payload = Data("hello".utf8)
        try payload.write(to: file)
        let manifest = try decode(manifestJSON(sha256: String(repeating: "b", count: 64), size: Int64(payload.count)))
        assertThrows(.checksumMismatch) {
            try BridgeUpdateInstaller.checkIntegrity(of: file, against: manifest)
        }
    }

    // MARK: Installer — mount output

    func testMountPointReadsTheSingleVolume() throws {
        let plist: [String: Any] = [
            "system-entities": [
                ["dev-entry": "/dev/disk9"],
                ["dev-entry": "/dev/disk9s1", "mount-point": "/private/tmp/x/Dicavo"],
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertEqual(try BridgeUpdateInstaller.mountPoint(fromAttachOutput: data).path, "/private/tmp/x/Dicavo")
    }

    func testMountPointRejectsTwoMountPoints() throws {
        let plist: [String: Any] = [
            "system-entities": [
                ["mount-point": "/private/tmp/x/A"],
                ["mount-point": "/private/tmp/x/B"],
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        assertThrowsMountFailure(data)
    }

    func testMountPointRejectsNoMountPoint() throws {
        let plist: [String: Any] = ["system-entities": [["dev-entry": "/dev/disk9"]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        assertThrowsMountFailure(data)
    }

    func testMountPointRejectsNonPlistOutput() {
        assertThrowsMountFailure(Data("not a plist".utf8))
    }

    /// The `diskutil` attach line targets a private, read-only mount point.
    func testAttachCommandUsesDiskutilWithAPrivateMountPoint() {
        let command = BridgeUpdateInstaller.attachCommand(
            .diskutil,
            image: URL(fileURLWithPath: "/tmp/w/u.dmg"),
            mountRoot: URL(fileURLWithPath: "/tmp/w/mount"),
            mountName: "M"
        )
        XCTAssertEqual(command, BridgeUpdateInstaller.DiskImageCommand(executable: "/usr/sbin/diskutil", arguments: [
            "image", "attach", "--plist", "--readOnly", "--nobrowse",
            "--mountPoint", "/tmp/w/mount/M", "/tmp/w/u.dmg",
        ]))
    }

    /// The `hdiutil` fallback attaches read-only into a random mount point.
    func testAttachCommandUsesHdiutilWithARandomMountPoint() {
        let command = BridgeUpdateInstaller.attachCommand(
            .hdiutil,
            image: URL(fileURLWithPath: "/tmp/w/u.dmg"),
            mountRoot: URL(fileURLWithPath: "/tmp/w/mount"),
            mountName: "M"
        )
        XCTAssertEqual(command, BridgeUpdateInstaller.DiskImageCommand(executable: "/usr/bin/hdiutil", arguments: [
            "attach", "-readonly", "-nobrowse", "-noautoopen",
            "-mountrandom", "/tmp/w/mount", "-plist", "/tmp/w/u.dmg",
        ]))
    }

    /// `diskutil` stays the first choice, `hdiutil` the fallback.
    func testDiskutilIsTriedBeforeHdiutil() {
        XCTAssertEqual(BridgeUpdateInstaller.DiskImageTool.allCases, [.diskutil, .hdiutil])
    }

    /// A `diskutil` detach ejects the mount point, and force-unmounts and
    /// ejects the device when that fails.
    func testDetachCommandsEjectTheMountPointWithDiskutil() {
        let commands = BridgeUpdateInstaller.detachCommands(
            for: BridgeUpdateInstaller.AttachedImage(
                mountPoint: URL(fileURLWithPath: "/tmp/w/mount/M"),
                device: "disk12"
            ),
            attachedWith: .diskutil
        )
        XCTAssertEqual(commands.ordinary, BridgeUpdateInstaller.DiskImageCommand(
            executable: "/usr/sbin/diskutil", arguments: ["eject", "/tmp/w/mount/M"]
        ))
        XCTAssertEqual(commands.forced, [
            BridgeUpdateInstaller.DiskImageCommand(
                executable: "/usr/sbin/diskutil", arguments: ["unmount", "force", "/tmp/w/mount/M"]
            ),
            BridgeUpdateInstaller.DiskImageCommand(
                executable: "/usr/sbin/diskutil", arguments: ["eject", "disk12"]
            ),
        ])
    }

    /// Without a reported device, the forced path is only the force-unmount.
    func testDetachCommandsForcedUnmountAloneWithoutADevice() {
        let commands = BridgeUpdateInstaller.detachCommands(
            for: BridgeUpdateInstaller.AttachedImage(
                mountPoint: URL(fileURLWithPath: "/tmp/w/mount/M"),
                device: nil
            ),
            attachedWith: .diskutil
        )
        XCTAssertEqual(commands.forced, [BridgeUpdateInstaller.DiskImageCommand(
            executable: "/usr/sbin/diskutil", arguments: ["unmount", "force", "/tmp/w/mount/M"]
        )])
    }

    /// An `hdiutil` detach is quiet, and its forced form repeats it with
    /// `-force`.
    func testDetachCommandsDetachWithHdiutil() {
        let commands = BridgeUpdateInstaller.detachCommands(
            for: BridgeUpdateInstaller.AttachedImage(
                mountPoint: URL(fileURLWithPath: "/tmp/w/mount/M"),
                device: "disk9"
            ),
            attachedWith: .hdiutil
        )
        XCTAssertEqual(commands.ordinary, BridgeUpdateInstaller.DiskImageCommand(
            executable: "/usr/bin/hdiutil", arguments: ["detach", "/tmp/w/mount/M", "-quiet"]
        ))
        XCTAssertEqual(commands.forced, [BridgeUpdateInstaller.DiskImageCommand(
            executable: "/usr/bin/hdiutil", arguments: ["detach", "/tmp/w/mount/M", "-force", "-quiet"]
        )])
    }

    /// Real `diskutil image attach --plist` output yields the mount point
    /// and the whole-disk device.
    func testAttachedImageReadsRealDiskutilOutput() throws {
        // Real `diskutil image attach --plist` output, with the mount path
        // shortened to keep the literal readable.
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>system-entities</key>
        \t<array>
        \t\t<dict>
        \t\t\t<key>content-hint</key>
        \t\t\t<string>GUID_partition_scheme</string>
        \t\t\t<key>dev-entry</key>
        \t\t\t<string>disk12</string>
        \t\t\t<key>size</key>
        \t\t\t<integer>12731904</integer>
        \t\t</dict>
        \t\t<dict>
        \t\t\t<key>content-hint</key>
        \t\t\t<string>Apple_APFS</string>
        \t\t\t<key>dev-entry</key>
        \t\t\t<string>disk12s1</string>
        \t\t\t<key>size</key>
        \t\t\t<integer>12693504</integer>
        \t\t</dict>
        \t\t<dict>
        \t\t\t<key>content-hint</key>
        \t\t\t<string>Apple_APFS_Container</string>
        \t\t\t<key>dev-entry</key>
        \t\t\t<string>disk13</string>
        \t\t\t<key>size</key>
        \t\t\t<integer>12693504</integer>
        \t\t</dict>
        \t\t<dict>
        \t\t\t<key>content-hint</key>
        \t\t\t<string>Apple_APFS_Volume</string>
        \t\t\t<key>dev-entry</key>
        \t\t\t<string>disk13s1</string>
        \t\t\t<key>filesystem-name</key>
        \t\t\t<string>APFS</string>
        \t\t\t<key>filesystem-type</key>
        \t\t\t<string>apfs</string>
        \t\t\t<key>mount-point</key>
        \t\t\t<string>/private/tmp/work/mount/M</string>
        \t\t\t<key>size</key>
        \t\t\t<integer>12693504</integer>
        \t\t\t<key>volume-name</key>
        \t\t\t<string>Dicavo CLI Bridge 2.0</string>
        \t\t</dict>
        \t</array>
        </dict>
        </plist>
        """.utf8)
        let attached = try BridgeUpdateInstaller.attachedImage(fromAttachOutput: data)
        XCTAssertEqual(attached.mountPoint.path, "/private/tmp/work/mount/M")
        XCTAssertEqual(attached.device, "disk12")
    }

    /// The `/dev/` prefix of an `hdiutil` device is stripped away.
    func testAttachedImageReadsHdiutilStyleDevices() throws {
        let plist: [String: Any] = [
            "system-entities": [
                ["dev-entry": "/dev/disk9"],
                ["dev-entry": "/dev/disk9s1", "mount-point": "/private/tmp/x/Dicavo"],
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let attached = try BridgeUpdateInstaller.attachedImage(fromAttachOutput: data)
        XCTAssertEqual(attached.mountPoint.path, "/private/tmp/x/Dicavo")
        XCTAssertEqual(attached.device, "disk9")
    }

    /// An attach whose output is not what was expected still detaches what
    /// it mounted, and the next tool tries (B-4).
    func testAnUnexpectedAttachIsDetachedAndTheNextToolTries() throws {
        let work = try makeTemporaryDirectory()
        let image = work.appendingPathComponent("u.dmg")
        let volume = work.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(
            at: volume.appendingPathComponent(BridgeUpdateInstaller.applicationName, isDirectory: true),
            withIntermediateDirectories: true
        )
        func attachOutput(_ points: [String]) throws -> Data {
            try PropertyListSerialization.data(
                fromPropertyList: ["system-entities": points.map { ["mount-point": $0] }],
                format: .xml,
                options: 0
            )
        }
        // A and B are inside the work folder, B is no volume root, and the
        // third path is outside it: only A may be detached.
        let mountRoot = work.appendingPathComponent("mount", isDirectory: true)
        let twoVolumes = try attachOutput([
            mountRoot.appendingPathComponent("A").path,
            mountRoot.appendingPathComponent("B").path,
            "/private/tmp/elsewhere",
        ])
        let oneVolume = try attachOutput([volume.path])
        var commands: [[String]] = []

        let copied = try BridgeUpdateInstaller.copyApplication(
            outOf: image,
            into: work,
            isVolumeRoot: { $0.lastPathComponent != "B" }
        ) { executable, arguments in
            commands.append([executable] + arguments)
            switch (executable, arguments.first) {
            case ("/usr/sbin/diskutil", "image"?):
                return .init(status: 0, output: twoVolumes, error: Data())
            case ("/usr/bin/hdiutil", "attach"?):
                return .init(status: 0, output: oneVolume, error: Data())
            default:
                return .init(status: 0, output: Data(), error: Data())
            }
        }

        XCTAssertEqual(copied.lastPathComponent, BridgeUpdateInstaller.applicationName)
        let ejected = commands.filter { Array($0.prefix(2)) == ["/usr/sbin/diskutil", "eject"] }.compactMap(\.last)
        XCTAssertEqual(ejected, [mountRoot.appendingPathComponent("A").path])
        XCTAssertTrue(commands.contains { Array($0.prefix(2)) == ["/usr/bin/hdiutil", "attach"] })
        XCTAssertEqual(commands.last, ["/usr/bin/hdiutil", "detach", volume.path, "-quiet"])
    }

    private func assertThrowsMountFailure(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try BridgeUpdateInstaller.mountPoint(fromAttachOutput: data), file: file, line: line) { error in
            guard case .mountFailed = error as? BridgeUpdateError else {
                return XCTFail("Expected mountFailed, got \(error).", file: file, line: line)
            }
        }
    }

    // MARK: Installer — signature and bundle

    /// An unsigned bundle that looks like the bridge, so the signature
    /// checks have something real to reject.
    private func makeFakeBundle() throws -> URL {
        let directory = try makeTemporaryDirectory()
        let application = directory.appendingPathComponent("Fake.app", isDirectory: true)
        try FileManager.default.createDirectory(at: application.appendingPathComponent("Contents/MacOS", isDirectory: true), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "cz.smartbrains.dicavo.bridge",
            "CFBundleExecutable": "Fake",
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: application.appendingPathComponent("Contents/Info.plist"))
        let executable = application.appendingPathComponent("Contents/MacOS/Fake")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return application
    }

    func testVerifySignatureRejectsAnUnsignedBundle() throws {
        let application = try makeFakeBundle()
        let requirement = try BridgeUpdateInstaller.requirement(
            BridgeUpdateInstaller.developerRequirement(bundleIdentifier: "cz.smartbrains.dicavo.bridge")
        )
        assertThrowsSignatureInvalid {
            try BridgeUpdateInstaller.verifySignature(of: application, requirements: [requirement])
        }
    }

    func testDeveloperRequirementNamesTheTeamAndBundle() throws {
        let text = BridgeUpdateInstaller.developerRequirement(bundleIdentifier: "cz.smartbrains.dicavo.bridge")
        XCTAssertTrue(text.contains("H8LTS9AT3K"))
        XCTAssertTrue(text.contains("cz.smartbrains.dicavo.bridge"))
        XCTAssertNoThrow(try BridgeUpdateInstaller.requirement(text))
    }

    func testRequirementRejectsGarbage() {
        assertThrowsSignatureInvalid {
            _ = try BridgeUpdateInstaller.requirement("not a requirement")
        }
    }

    func testInfoDictionaryReadsTheFakeBundle() throws {
        let application = try makeFakeBundle()
        let info = try BridgeUpdateInstaller.infoDictionary(of: application)
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "cz.smartbrains.dicavo.bridge")
    }

    // MARK: Installer — replacement

    func testCanReplaceInsideAWritableDirectory() throws {
        let directory = try makeTemporaryDirectory()
        let application = directory.appendingPathComponent("Dicavo CLI Bridge.app", isDirectory: true)
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
        XCTAssertTrue(BridgeUpdateInstaller.canReplace(application))
    }

    func testCannotReplaceATranslocatedApplication() {
        XCTAssertFalse(BridgeUpdateInstaller.canReplace(
            URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/ABC/d/Dicavo CLI Bridge.app")
        ))
    }
    #endif
}

/// A URLProtocol whose behaviour one test at a time supplies, so the checker
/// can be exercised without touching the network.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.requestCount += 1
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
