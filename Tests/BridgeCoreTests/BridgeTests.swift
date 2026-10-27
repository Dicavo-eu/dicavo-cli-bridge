import Foundation
import XCTest
@testable import BridgeCore

/// The bridge is trusted with the transcript, so the two things that gate
/// it are tested first: the token and the parser's limits. The rest checks
/// that a Dicavo-shaped request comes back as a Dicavo-readable response.
final class BridgeTests: XCTestCase {
    // MARK: HTTP parsing

    func testParserAssemblesARequestFromFragments() throws {
        var parser = BridgeHTTPRequestParser()
        let raw = "POST /v1/chat/completions?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer abc\r\nContent-Length: 5\r\n\r\nhello"
        let data = Data(raw.utf8)
        XCTAssertNil(try parser.append(data.prefix(20)))
        XCTAssertNil(try parser.append(data.subdata(in: 20..<(data.count - 2))))
        let request = try XCTUnwrap(try parser.append(data.suffix(2)))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/chat/completions")
        XCTAssertEqual(request.header("Host"), "127.0.0.1")
        XCTAssertEqual(request.bearerToken, "abc")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "hello")
    }

    func testTheHeadersAreAvailableBeforeTheBodyArrives() throws {
        var parser = BridgeHTTPRequestParser()
        let head = "POST /v1/chat/completions HTTP/1.1\r\nAuthorization: Bearer abc\r\nContent-Length: 1000\r\n\r\n"
        XCTAssertNil(try parser.append(Data(head.utf8)))
        let early = try XCTUnwrap(parser.headersOnly)
        XCTAssertEqual(early.bearerToken, "abc")
        XCTAssertTrue(early.body.isEmpty)
    }

    func testIsAuthorizedChecksThePresentedToken() {
        let handler = BridgeRequestHandler(token: "secret", runner: StubBridgeRunner())
        XCTAssertTrue(handler.isAuthorized(makeRequest(method: "GET", path: "/v1/models", token: "secret")))
        XCTAssertFalse(handler.isAuthorized(makeRequest(method: "GET", path: "/v1/models", token: "secreT")))
        XCTAssertFalse(handler.isAuthorized(makeRequest(method: "GET", path: "/v1/models", token: nil)))
    }

    func testParserRejectsOversizedHeadersAndBodies() {
        var parser = BridgeHTTPRequestParser()
        let junk = Data(repeating: UInt8(ascii: "a"), count: BridgeHTTPRequestParser.maximumHeaderBytes + 1)
        XCTAssertThrowsError(try parser.append(junk)) { error in
            XCTAssertEqual(error as? BridgeHTTPParseError, .headersTooLarge)
        }
        var bodyParser = BridgeHTTPRequestParser()
        let head = "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: \(BridgeHTTPRequestParser.maximumBodyBytes + 1)\r\n\r\n"
        XCTAssertThrowsError(try bodyParser.append(Data(head.utf8))) { error in
            XCTAssertEqual(error as? BridgeHTTPParseError, .bodyTooLarge)
        }
    }

    func testParserRejectsMalformedRequestLines() {
        var parser = BridgeHTTPRequestParser()
        XCTAssertThrowsError(try parser.append(Data("GARBAGE\r\n\r\n".utf8))) { error in
            XCTAssertEqual(error as? BridgeHTTPParseError, .malformedRequestLine)
        }
    }

    func testResponseSerializationCarriesLengthAndClose() {
        let response = BridgeHTTPResponse.json(status: 200, object: ["ok": true])
        let text = String(decoding: response.serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json; charset=utf-8\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 11\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n\r\n"))
        XCTAssertTrue(text.hasSuffix(#"{"ok":true}"#))
    }

    // MARK: Handler

    func testMissingOrWrongTokenIsRefusedBeforeAnyToolRuns() async {
        let runner = StubBridgeRunner()
        let handler = BridgeRequestHandler(token: "secret", runner: runner)

        let noToken = await handler.handle(makeRequest(method: "GET", path: "/v1/models", token: nil))
        XCTAssertEqual(noToken.status, 401)
        let wrongToken = await handler.handle(makeRequest(method: "GET", path: "/v1/models", token: "secreT"))
        XCTAssertEqual(wrongToken.status, 401)
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testModelsListsOnlyUsableTools() async throws {
        let runner = StubBridgeRunner(statuses: [
            BridgeToolStatus(tool: .claude, executablePath: "/x/claude", version: "2.1", isAuthenticated: true, loginCommand: nil),
            BridgeToolStatus(tool: .codex, executablePath: "/x/codex", version: "1.0", isAuthenticated: false, loginCommand: "codex login"),
        ])
        let handler = BridgeRequestHandler(token: "secret", runner: runner)

        let response = await handler.handle(makeRequest(method: "GET", path: "/v1/models", token: "secret"))

        XCTAssertEqual(response.status, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertEqual(data.map { $0["id"] as? String }, ["claude"])
    }

    func testCompletionRunsTheNamedToolWithTheConcatenatedPrompt() async throws {
        let runner = StubBridgeRunner(result: "## Summary\n- done")
        let handler = BridgeRequestHandler(token: "secret", runner: runner)
        let body: [String: Any] = [
            "model": "claude:opus",
            "messages": [
                ["role": "system", "content": "You analyze."],
                ["role": "user", "content": [["type": "text", "text": "TRANSCRIPT CHUNK\n[00:00:01] hello"]]],
            ],
        ]

        let response = await handler.handle(makeRequest(
            method: "POST", path: "/v1/chat/completions", token: "secret",
            body: try JSONSerialization.data(withJSONObject: body)
        ))

        XCTAssertEqual(response.status, 200)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].tool, .claude)
        XCTAssertEqual(calls[0].model, "opus")
        XCTAssertEqual(calls[0].promptText, "You analyze.\n\nTRANSCRIPT CHUNK\n[00:00:01] hello")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "## Summary\n- done")
        XCTAssertEqual(choices.first?["finish_reason"] as? String, "stop")
    }

    func testUnknownModelAndBadBodyAreBadRequests() async throws {
        let runner = StubBridgeRunner()
        let handler = BridgeRequestHandler(token: "secret", runner: runner)

        let badJSON = await handler.handle(makeRequest(
            method: "POST", path: "/v1/chat/completions", token: "secret", body: Data("nope".utf8)
        ))
        XCTAssertEqual(badJSON.status, 400)

        let unknownModel = await handler.handle(makeRequest(
            method: "POST", path: "/v1/chat/completions", token: "secret",
            body: try JSONSerialization.data(withJSONObject: ["model": "gpt-4", "messages": [["role": "user", "content": "x"]]])
        ))
        XCTAssertEqual(unknownModel.status, 400)

        let apiTool = await handler.handle(makeRequest(
            method: "POST", path: "/v1/chat/completions", token: "secret",
            body: try JSONSerialization.data(withJSONObject: ["model": "claudeAPI", "messages": [["role": "user", "content": "x"]]])
        ))
        XCTAssertEqual(apiTool.status, 400, "only the command-line tools are bridged")
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testToolFailuresMapToStatusesDicavoUnderstands() async throws {
        let cases: [(AnalysisError, Int)] = [
            (.executableNotFound(path: "claude"), 503),
            (.authenticationRequired(tool: .claude, loginCommand: "claude auth login"), 503),
            (.processTimedOut(tool: .codex), 504),
            (.outputTooLarge, 413),
            (.processFailed(tool: .claude, exitCode: 1, message: "boom"), 502),
        ]
        for (error, expectedStatus) in cases {
            let runner = StubBridgeRunner(error: error)
            let handler = BridgeRequestHandler(token: "secret", runner: runner)
            let response = await handler.handle(makeRequest(
                method: "POST", path: "/v1/chat/completions", token: "secret",
                body: try JSONSerialization.data(withJSONObject: ["model": "claude", "messages": [["role": "user", "content": "x"]]])
            ))
            XCTAssertEqual(response.status, expectedStatus, "\(error)")
            // Dicavo's provider reads `error.message`; make sure it is there.
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            XCTAssertNotNil((object["error"] as? [String: Any])?["message"] as? String)
        }
    }

    // MARK: Descriptor

    func testDescriptorRoundTripsAndIgnoresDeadBridges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BridgeTests-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BridgeDescriptorStore(fileURL: directory.appendingPathComponent("bridge.json"))
        let descriptor = BridgeDescriptor(
            port: 48123, token: "t", bridgeVersion: "0.1", processIdentifier: 4242,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), availableTools: ["claude"]
        )

        try store.save(descriptor)

        XCTAssertEqual(store.load(processIsAlive: { $0 == 4242 }), descriptor)
        XCTAssertNil(store.load(processIsAlive: { _ in false }))
        XCTAssertEqual(descriptor.endpoint?.absoluteString, "http://127.0.0.1:48123/v1")
        store.remove()
        XCTAssertNil(store.load(processIsAlive: { _ in true }))
        XCTAssertNil(BridgeDescriptorStore(fileURL: nil).load())
    }

    /// An update summary in the descriptor survives a store round trip.
    func testDescriptorRoundTripsUpdateSummary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BridgeTests-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BridgeDescriptorStore(fileURL: directory.appendingPathComponent("bridge.json"))
        let descriptor = BridgeDescriptor(
            port: 48123, token: "t", bridgeVersion: "2.1", processIdentifier: 4242,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), availableTools: ["claude"],
            updates: BridgeUpdateSummary(
                automaticChecks: true,
                lastCheck: Date(timeIntervalSince1970: 1_700_000_000),
                availableVersion: "2.1"
            )
        )

        try store.save(descriptor)

        XCTAssertEqual(store.load(processIsAlive: { _ in true }), descriptor)
    }

    /// A bridge.json from before the update field still loads, unreported.
    func testDescriptorFromBridgeTwoPointZeroHasNoUpdateSummary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BridgeTests-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("bridge.json")
        try Data("""
        {"availableTools":["claude"],"bridgeVersion":"2.0 (5)","port":50123,"processIdentifier":4242,"schemaVersion":1,"startedAt":"2026-10-12T10:00:00Z","token":"tok"}
        """.utf8).write(to: fileURL)
        let store = BridgeDescriptorStore(fileURL: fileURL)

        let descriptor = store.load(processIsAlive: { _ in true })

        XCTAssertNotNil(descriptor)
        XCTAssertEqual(descriptor?.bridgeVersion, "2.0 (5)")
        XCTAssertNil(descriptor?.updates)
        XCTAssertEqual(descriptor?.updateState, .unreported)
    }

    /// Each summary shape maps to its own update state on the descriptor.
    func testDescriptorMapsUpdateStateFromTheSummary() {
        let base = BridgeDescriptor(
            port: 48123, token: "t", bridgeVersion: "2.1", processIdentifier: 4242,
            startedAt: Date(), availableTools: ["claude"]
        )

        var available = base
        available.updates = BridgeUpdateSummary(
            automaticChecks: true, lastCheck: Date(timeIntervalSince1970: 1_700_000_000), availableVersion: "2.2"
        )
        XCTAssertEqual(available.updateState, .available(version: "2.2"))

        var requiresNewerSystem = base
        requiresNewerSystem.updates = BridgeUpdateSummary(
            automaticChecks: true,
            lastCheck: Date(timeIntervalSince1970: 1_700_000_000),
            availableVersion: "2.2",
            requiredSystemVersion: "28.0"
        )
        XCTAssertEqual(requiresNewerSystem.updateState, .requiresNewerSystem(version: "2.2", system: "28.0"))

        var upToDate = base
        upToDate.updates = BridgeUpdateSummary(
            automaticChecks: true, lastCheck: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(upToDate.updateState, .upToDate(checkedAt: Date(timeIntervalSince1970: 1_700_000_000)))

        var notChecked = base
        notChecked.updates = BridgeUpdateSummary(automaticChecks: false, lastCheck: nil)
        XCTAssertEqual(notChecked.updateState, .notChecked(automaticChecks: false))
    }

    // MARK: Helpers

    private func makeRequest(method: String, path: String, token: String?, body: Data = Data()) -> BridgeHTTPRequest {
        var headers: [String: String] = ["content-type": "application/json"]
        if let token { headers["authorization"] = "Bearer \(token)" }
        return BridgeHTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}

private actor StubBridgeRunner: BridgeToolRunning {
    struct Call: Equatable { let tool: AnalysisTool; let model: String?; let promptText: String }

    private let statuses: [BridgeToolStatus]
    private let result: String
    private let error: AnalysisError?
    private(set) var calls: [Call] = []

    init(statuses: [BridgeToolStatus] = [], result: String = "ok", error: AnalysisError? = nil) {
        self.statuses = statuses
        self.result = result
        self.error = error
    }

    func toolStatuses() async -> [BridgeToolStatus] { statuses }

    func run(tool: AnalysisTool, model: String?, promptText: String) async throws -> String {
        calls.append(Call(tool: tool, model: model, promptText: promptText))
        if let error { throw error }
        return result
    }
}
