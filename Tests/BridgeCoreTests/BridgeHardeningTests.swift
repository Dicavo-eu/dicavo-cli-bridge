import CryptoKit
import Foundation
import Network
import XCTest
@testable import BridgeCore

/// The paths a hostile manifest, a local process without the token or a tool
/// that will not stop could use, each pinned by a test.
final class BridgeHardeningTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories = []
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Update download

    /// `lastPathComponent` decodes `%2F`: a name taken from the URL could
    /// leave the work folder. The image is saved under a name of its own.
    func testTheImageNameNeverComesFromTheURL() throws {
        let directory = try makeTemporaryDirectory()
        let manifest = try makeManifest(url: "https://dicavo.eu/bridge/..%2F..%2F..%2FLibrary%2FLaunchAgents%2Fx.plist", body: Data("x".utf8))
        XCTAssertEqual(manifest.url.lastPathComponent, "../../../Library/LaunchAgents/x.plist", "the premise of this test")

        let image = try BridgeUpdateInstaller.imageLocation(for: manifest, in: directory)

        XCTAssertEqual(image.lastPathComponent, "DicavoCLIBridge-\(manifest.build).dmg")
        XCTAssertEqual(image.deletingLastPathComponent().standardizedFileURL.path, directory.standardizedFileURL.path)
    }

    func testADownloadFromATraversingURLStaysInTheWorkFolder() async throws {
        let root = try makeTemporaryDirectory()
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        let body = Data("not a disk image".utf8)
        let manifest = try makeManifest(url: "https://dicavo.eu/bridge/..%2Fescaped.plist", body: body)
        StubURLProtocol.respond(to: manifest.url, status: 200, body: body)

        let image = try await installer().download(manifest, into: work)

        XCTAssertEqual(image.deletingLastPathComponent().standardizedFileURL.path, work.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.plist").path))
        let permissions = try FileManager.default.attributesOfItem(atPath: image.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    /// More bytes than the manifest promised end the download as they
    /// arrive, whatever the server claimed beforehand.
    func testADownloadLongerThanTheManifestSaysIsRefused() async throws {
        let work = try makeTemporaryDirectory()
        let promised = Data(repeating: 1, count: 1_000)
        let manifest = try makeManifest(url: "https://dicavo.eu/downloads/big.dmg", body: promised)
        StubURLProtocol.respond(
            to: manifest.url,
            status: 200,
            body: Data(repeating: 1, count: BridgeUpdateInstaller.downloadChunkBytes * 3),
            announceLength: false
        )

        do {
            _ = try await installer().download(manifest, into: work)
            XCTFail("an oversized download was accepted")
        } catch let error as BridgeUpdateError {
            XCTAssertEqual(error, .sizeMismatch)
        }
    }

    /// A redirect to another host is not followed: nothing is requested
    /// there, and the redirect itself is refused.
    func testARedirectAwayFromDicavoIsNotFollowed() async throws {
        let work = try makeTemporaryDirectory()
        let manifest = try makeManifest(url: "https://dicavo.eu/downloads/update.dmg", body: Data("x".utf8))
        let elsewhere = URL(string: "https://example.com/update.dmg")!
        StubURLProtocol.redirect(manifest.url, to: elsewhere)
        StubURLProtocol.respond(to: elsewhere, status: 200, body: Data("x".utf8))

        do {
            _ = try await installer().download(manifest, into: work)
            XCTFail("the redirect was followed")
        } catch let error as BridgeUpdateError {
            XCTAssertEqual(error, .httpStatus(302))
        }
        XCTAssertFalse(StubURLProtocol.requested.contains(elsewhere), "the other host was asked")
    }

    func testTheManifestCheckDoesNotFollowARedirectAwayFromDicavo() async throws {
        let elsewhere = URL(string: "https://example.com/latest.json")!
        StubURLProtocol.redirect(BridgeUpdateManifest.feedURL, to: elsewhere)
        StubURLProtocol.respond(to: elsewhere, status: 200, body: Data("{}".utf8))
        let checker = BridgeUpdateChecker(session: Self.stubSession())

        do {
            _ = try await checker.fetchManifest()
            XCTFail("the redirect was followed")
        } catch let error as BridgeUpdateError {
            XCTAssertEqual(error, .httpStatus(302))
        }
        XCTAssertFalse(StubURLProtocol.requested.contains(elsewhere))
    }

    func testAnUnsignedFolderIsNotTakenForADeveloperIDBuild() throws {
        let directory = try makeTemporaryDirectory()
        XCTAssertFalse(BridgeUpdateInstaller.isSignedWithDeveloperID(directory))
    }

    func testAHangingToolIsStoppedAtItsTimeout() throws {
        let started = Date()
        let result = try BridgeUpdateInstaller.run("/bin/sleep", ["30"], timeout: 0.3)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    // MARK: Server

    /// A local process without the token can hold only part of the slots,
    /// and only for a few seconds; Dicavo still gets through.
    func testConnectionsWithoutATokenCannotTakeEverySlot() async throws {
        let server = BridgeServer(
            handler: BridgeRequestHandler(token: "token", runner: AnsweringToolRunner()),
            authorizationDeadline: 30
        )
        let port = try await startOrSkip(server)
        defer { server.stop() }

        var idle: [NWConnection] = []
        defer { idle.forEach { $0.cancel() } }
        for _ in 0..<BridgeServer.maximumUnauthorizedConnections + 4 {
            idle.append(try await connect(to: port))
        }
        try await Task.sleep(for: .milliseconds(200))

        let response = try await exchange(Self.completionRequest(token: "token"), port: port)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), response)
    }

    func testAConnectionThatNeverShowsItsTokenIsClosed() async throws {
        let server = BridgeServer(
            handler: BridgeRequestHandler(token: "token", runner: AnsweringToolRunner()),
            authorizationDeadline: 0.3
        )
        let port = try await startOrSkip(server)
        defer { server.stop() }

        let connection = try await connect(to: port)
        defer { connection.cancel() }
        let closed = await waitForEnd(of: connection, within: .seconds(5))
        XCTAssertTrue(closed, "a connection without a token kept its slot")
    }

    func testAPausedBridgeTurnsNewRequestsAwayAndStillChecksTheToken() async throws {
        let runner = AnsweringToolRunner()
        let server = BridgeServer(handler: BridgeRequestHandler(token: "token", runner: runner))
        let port = try await startOrSkip(server)
        defer { server.stop() }
        server.isPaused = true

        let updating = try await exchange(Self.completionRequest(token: "token"), port: port)
        XCTAssertTrue(updating.hasPrefix("HTTP/1.1 503"), updating)
        XCTAssertTrue(updating.contains("bridge_updating"), updating)
        let refused = try await exchange(Self.completionRequest(token: "wrong"), port: port)
        XCTAssertTrue(refused.hasPrefix("HTTP/1.1 401"), refused)
        XCTAssertEqual(runner.runs, 0)

        server.isPaused = false
        let answered = try await exchange(Self.completionRequest(token: "token"), port: port)
        XCTAssertTrue(answered.hasPrefix("HTTP/1.1 200"), answered)
    }

    // MARK: HTTP parsing and the token

    func testInvalidContentLengthAndMalformedHeadersAreRejected() {
        for length in ["-1", "abc", "1e3"] {
            var parser = BridgeHTTPRequestParser()
            XCTAssertThrowsError(try parser.append(Data("POST /v1 HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n".utf8))) {
                XCTAssertEqual($0 as? BridgeHTTPParseError, .invalidContentLength, length)
            }
        }
        var parser = BridgeHTTPRequestParser()
        XCTAssertThrowsError(try parser.append(Data("GET /v1 HTTP/1.1\r\nno colon here\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? BridgeHTTPParseError, .malformedHeader)
        }
    }

    func testTokensMatchOnlyExactly() {
        XCTAssertTrue(BridgeRequestHandler.tokensMatch("abc123", "abc123"))
        XCTAssertFalse(BridgeRequestHandler.tokensMatch("abc123", "abc124"))
        XCTAssertFalse(BridgeRequestHandler.tokensMatch("abc123", "abc12"))
        XCTAssertFalse(BridgeRequestHandler.tokensMatch("", "a"))
    }

    // MARK: Descriptor

    func testTheDescriptorIsOnlyEverReadableByItsOwner() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("bridge.json")
        let store = BridgeDescriptorStore(fileURL: file)

        try store.save(descriptor(processStartedAt: nil))
        try store.save(descriptor(processStartedAt: nil))

        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["bridge.json"], "a staging file was left behind")
    }

    /// A PID that another process took over after a crash is not the bridge.
    func testADescriptorWhosePIDNowBelongsToAnotherProcessIsStale() throws {
        let directory = try makeTemporaryDirectory()
        let store = BridgeDescriptorStore(fileURL: directory.appendingPathComponent("bridge.json"))
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        try store.save(descriptor(processStartedAt: started))

        XCTAssertNotNil(store.load(processIsAlive: { _ in true }, processStartTime: { _ in started }))
        XCTAssertNil(store.load(processIsAlive: { _ in true }, processStartTime: { _ in started.addingTimeInterval(60) }))
        XCTAssertNotNil(
            store.load(processIsAlive: { _ in true }, processStartTime: { _ in nil }),
            "where the start time cannot be read, the PID alone decides"
        )
    }

    func testABridgeWithoutAStartTimeIsJudgedByItsPIDAsBefore() throws {
        let directory = try makeTemporaryDirectory()
        let store = BridgeDescriptorStore(fileURL: directory.appendingPathComponent("bridge.json"))
        try store.save(descriptor(processStartedAt: nil))
        XCTAssertNotNil(store.load(processIsAlive: { _ in true }, processStartTime: { _ in Date() }))
    }

    func testTheKernelReportsThisProcessesStartTime() throws {
        let start = try XCTUnwrap(BridgeDescriptorStore.processStartTime(ProcessInfo.processInfo.processIdentifier))
        XCTAssertLessThanOrEqual(start, Date())
        XCTAssertNil(BridgeDescriptorStore.processStartTime(-1))
    }

    // MARK: Tools

    func testTheRunsPrivateFilesAreReadableByItsOwnerOnly() async throws {
        let runner = InspectingRunner(output: Data(#"{"markdown":"Done"}"#.utf8))
        let provider = CLIAnalysisProvider(tool: .claude, executableURL: URL(fileURLWithPath: "/bin/echo"), runner: runner)

        _ = try await provider.rawMarkdown(forPromptText: "Summarize.")

        let seen = try XCTUnwrap(runner.directoryPermissions)
        XCTAssertEqual(seen, 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(runner.directory).path), "the run's folder outlived it")
    }

    func testAntigravityRunsWithEveryToolButFinishDenied() async throws {
        let runner = InspectingRunner(output: Data((
            #"{"type":"result","structured_output":{"markdown":"Done"}}"# + "\n"
        ).utf8))
        let provider = CLIAnalysisProvider(tool: .antigravity, executableURL: URL(fileURLWithPath: "/bin/echo"), runner: runner)

        _ = try? await provider.rawMarkdown(forPromptText: "Summarize.")

        let command = try XCTUnwrap(runner.commands.last)
        XCTAssertTrue(command.arguments.contains("--disable-slash-commands"))
        XCTAssertEqual(command.arguments.firstIndex(of: "--input-format").map { command.arguments[$0 + 1] }, "stream-json")
        let hooks = try XCTUnwrap(runner.hooks)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: hooks) as? [String: Any])
        let preToolUse = try XCTUnwrap((object["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse.first?["matcher"] as? String, CLIAnalysisProvider.antigravityToolMatcher)
        let line = String(decoding: command.standardInput, as: UTF8.self)
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertTrue(line.contains(#""event":"user""#), line)
    }

    func testTheAntigravityMatcherAllowsOnlyFinish() throws {
        let matcher = try NSRegularExpression(pattern: CLIAnalysisProvider.antigravityToolMatcher)
        func denied(_ name: String) -> Bool {
            matcher.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
        XCTAssertFalse(denied("finish"))
        for name in ["run_command", "f", "fin", "finis", "finish2", "finishx", "Finish", "read_file", "write_to_file", "browser"] {
            XCTAssertTrue(denied(name), name)
        }
    }

    func testAntigravityCleanupRemovesOnlyThatRunAndOnlyForAUUID() throws {
        let home = try makeTemporaryDirectory()
        let root = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        let id = UUID().uuidString
        let other = UUID().uuidString
        for path in ["conversations/\(id).db", "conversations/\(other).db", "brain/\(id)/note", "annotations/\(id).pbtxt"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }

        AntigravityRunCleanup.removeRun(conversationID: "../../etc", home: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("conversations/\(id).db").path))

        AntigravityRunCleanup.removeRun(conversationID: id, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("conversations/\(id).db").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("brain/\(id)").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("annotations/\(id).pbtxt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("conversations/\(other).db").path))
    }

    /// A tool that ignores SIGTERM does not outlive a bridge that quits.
    func testQuittingKillsAToolThatIgnoresTerm() async throws {
        let directory = try makeTemporaryDirectory()
        let script = directory.appendingPathComponent("stubborn")
        try Data("#!/bin/sh\ntrap '' TERM\nwhile true; do sleep 1; done\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let runner = AnalysisProcessRunner(terminationGracePeriod: 60)
        let run = Task {
            try await runner.run(
                AnalysisCommand(
                    executableURL: script,
                    arguments: [],
                    standardInput: Data(),
                    currentDirectoryURL: directory,
                    timeout: .seconds(120)
                ),
                tool: .localCommand
            )
        }
        for _ in 0..<250 where RunningAnalysisProcesses.count == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(RunningAnalysisProcesses.count, 0, "the tool never started")

        RunningAnalysisProcesses.terminateAll(gracePeriod: 0.3)

        let ended = Task {
            _ = try? await run.value
            return true
        }
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await ended.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(finished, "the tool survived the bridge quitting")
        run.cancel()
    }

    // MARK: Fixtures

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BridgeHardeningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func makeManifest(url: String, body: Data) throws -> BridgeUpdateManifest {
        let sha = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let object: [String: Any] = [
            "schemaVersion": 1, "version": "9.9", "build": 999, "minimumSystemVersion": "14.2",
            "url": url, "sha256": sha, "size": body.count,
        ]
        return try BridgeUpdateManifest.decode(try JSONSerialization.data(withJSONObject: object))
    }

    private func installer() -> BridgeUpdateInstaller {
        BridgeUpdateInstaller(
            session: Self.stubSession(),
            installedApplication: FileManager.default.temporaryDirectory.appendingPathComponent("Dicavo CLI Bridge.app"),
            bundleIdentifier: "cz.smartbrains.dicavo.bridge",
            currentBuild: 1
        )
    }

    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return BridgeUpdateChecker.makeSession(configuration: configuration)
    }

    private func descriptor(processStartedAt: Date?) -> BridgeDescriptor {
        BridgeDescriptor(
            port: 48123, token: "token", bridgeVersion: "2.2 (31)", processIdentifier: 4242,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000), availableTools: ["claude"],
            updates: nil, processStartedAt: processStartedAt
        )
    }

    private func startOrSkip(_ server: BridgeServer) async throws -> UInt16 {
        do {
            return try await server.start()
        } catch {
            throw XCTSkip("this machine will not let a test process listen: \(error)")
        }
    }

    private static func completionRequest(token: String) -> Data {
        let body = #"{"model":"claude","messages":[{"role":"user","content":"Hello"}]}"#
        return Data((
            "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\n"
                + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        ).utf8)
    }

    private func connect(to port: UInt16) async throws -> NWConnection {
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = OnceGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.claim() { continuation.resume() }
                case let .failed(error), let .waiting(error):
                    if gate.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "BridgeHardeningTests.client"))
        }
        return connection
    }

    /// Sends one request and returns the whole response as text.
    private func exchange(_ request: Data, port: UInt16) async throws -> String {
        let connection = try await connect(to: port)
        defer { connection.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: request, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        var response = Data()
        while true {
            let (data, isComplete) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error, data == nil { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, isComplete)) }
                }
            }
            if let data { response.append(data) }
            if isComplete || data == nil { break }
        }
        return String(decoding: response, as: UTF8.self)
    }

    private func waitForEnd(of connection: NWConnection, within limit: Duration) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = OnceGate()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, isComplete, error in
                if (isComplete || error != nil), gate.claim() { continuation.resume(returning: true) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(limit.components.seconds)) {
                if gate.claim() { continuation.resume(returning: false) }
            }
        }
    }
}

/// Answers every prompt at once and counts the runs.
private final class AnsweringToolRunner: BridgeToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var runs: Int { lock.withLock { count } }

    func toolStatuses() async -> [BridgeToolStatus] { [] }

    func run(tool: AnalysisTool, model: String?, promptText: String) async throws -> String {
        lock.withLock { count += 1 }
        return "## Done"
    }
}

/// Records each command and what the run's folder looked like while it ran.
private final class InspectingRunner: AnalysisCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let output: Data
    private var recorded: [AnalysisCommand] = []
    private var permissions: Int?
    private var folder: URL?
    private var hooksData: Data?

    init(output: Data) { self.output = output }

    var commands: [AnalysisCommand] { lock.withLock { recorded } }
    var directoryPermissions: Int? { lock.withLock { permissions } }
    var directory: URL? { lock.withLock { folder } }
    var hooks: Data? { lock.withLock { hooksData } }

    func run(_ command: AnalysisCommand, tool: AnalysisTool) async throws -> AnalysisCommandResult {
        let attributes = try? FileManager.default.attributesOfItem(atPath: command.currentDirectoryURL.path)
        let hooks = try? Data(contentsOf: command.currentDirectoryURL.appendingPathComponent(".agents/hooks.json"))
        lock.withLock {
            recorded.append(command)
            if command.arguments != tool.authenticationStatusArguments {
                permissions = attributes?[.posixPermissions] as? Int
                folder = command.currentDirectoryURL
                hooksData = hooks
            }
        }
        if let index = command.arguments.firstIndex(of: "--output-last-message") {
            try output.write(to: URL(fileURLWithPath: command.arguments[index + 1]))
        }
        return AnalysisCommandResult(exitCode: 0, standardOutput: output, standardError: Data())
    }
}

/// Serves canned responses and redirects, and records what was asked for.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Response {
        var status: Int
        var body: Data
        var location: URL?
        var announceLength: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [URL: Response] = [:]
    nonisolated(unsafe) private static var requestedURLs: [URL] = []

    static var requested: [URL] { lock.withLock { requestedURLs } }

    static func respond(to url: URL, status: Int, body: Data, announceLength: Bool = true) {
        lock.withLock { responses[url] = Response(status: status, body: body, location: nil, announceLength: announceLength) }
    }

    static func redirect(_ url: URL, to target: URL) {
        lock.withLock { responses[url] = Response(status: 302, body: Data(), location: target, announceLength: true) }
    }

    static func reset() {
        lock.withLock {
            responses = [:]
            requestedURLs = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let response = Self.lock.withLock { () -> Response? in
            Self.requestedURLs.append(url)
            return Self.responses[url]
        }
        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var headers: [String: String] = [:]
        if response.announceLength { headers["Content-Length"] = String(response.body.count) }
        if let location = response.location { headers["Location"] = location.absoluteString }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        if let location = response.location {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: location), redirectResponse: http)
            // The redirect was refused: what the caller sees is the 302.
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < response.body.count {
            let end = min(offset + 16 * 1024, response.body.count)
            client?.urlProtocol(self, didLoad: response.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
