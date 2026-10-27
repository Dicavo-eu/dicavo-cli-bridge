import Foundation
import Network
import XCTest
@testable import BridgeCore

/// The bridge's loopback server over a real socket: a request lives as long
/// as its connection, and stopping the bridge ends every one.
final class BridgeServerTests: XCTestCase {
    /// Dicavo cancelling an analysis closes the connection; the command the
    /// bridge runs for it is cancelled, not left to finish for nobody.
    func testAClientThatGoesAwayCancelsItsCommand() async throws {
        let runner = BlockingToolRunner()
        let server = BridgeServer(handler: BridgeRequestHandler(token: "token", runner: runner))
        let port = try await startOrSkip(server)
        defer { server.stop() }

        let client = try await sendCompletionRequest(to: port)
        try await runner.waitUntilRunning()
        XCTAssertEqual(server.activeRequestCount, 1)

        client.cancel()
        let cancelled = await runner.waitUntilCancelled()
        XCTAssertTrue(cancelled, "the command outlived the client that asked for it")
        try await waitUntilIdle(server)
    }

    /// Quitting stops the server, and every command still running is
    /// cancelled with it.
    func testStoppingCancelsEveryCommand() async throws {
        let runner = BlockingToolRunner()
        let server = BridgeServer(handler: BridgeRequestHandler(token: "token", runner: runner))
        let port = try await startOrSkip(server)

        let client = try await sendCompletionRequest(to: port)
        defer { client.cancel() }
        try await runner.waitUntilRunning()

        server.stop()
        let cancelled = await runner.waitUntilCancelled()
        XCTAssertTrue(cancelled, "the command outlived the bridge")
    }

    // MARK: - Fixtures

    private func startOrSkip(_ server: BridgeServer) async throws -> UInt16 {
        do {
            return try await server.start()
        } catch {
            throw XCTSkip("this machine will not let a test process listen: \(error)")
        }
    }

    /// Opens a connection and sends one chat completion, as Dicavo does.
    private func sendCompletionRequest(to port: UInt16) async throws -> NWConnection {
        let body = Data(#"{"model":"claude","messages":[{"role":"user","content":"Hello"}]}"#.utf8)
        let head = "POST /v1/chat/completions HTTP/1.1\r\n"
            + "Host: 127.0.0.1\r\n"
            + "Authorization: Bearer token\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let queue = DispatchQueue(label: "BridgeServerTests.client")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeGate()
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
            connection.start(queue: queue)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        return connection
    }

    private func waitUntilIdle(_ server: BridgeServer) async throws {
        for _ in 0..<100 where server.activeRequestCount > 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(server.activeRequestCount, 0, "the request is still counted as running")
    }
}

/// A command that runs until it is cancelled.
private final class BlockingToolRunner: BridgeToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var isRunning = false
    private var wasCancelled = false

    func toolStatuses() async -> [BridgeToolStatus] { [] }

    func run(tool: AnalysisTool, model: String?, promptText: String) async throws -> String {
        lock.withLock { isRunning = true }
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            lock.withLock { wasCancelled = true }
            throw error
        }
        return "## Done"
    }

    func waitUntilRunning() async throws {
        for _ in 0..<250 {
            if lock.withLock({ isRunning }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTSkip("the request never reached the command")
    }

    /// True once the command was cancelled, within five seconds.
    func waitUntilCancelled() async -> Bool {
        for _ in 0..<250 {
            if lock.withLock({ wasCancelled }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
