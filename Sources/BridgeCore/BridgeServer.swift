import Foundation
import Network

/// Listens on loopback and hands each connection's single request to the
/// handler.
///
/// One request per connection, then close: `URLSession` copes with that
/// perfectly well and it keeps the parser stateless across requests. The
/// listener is bound to 127.0.0.1 explicitly; there is no configuration that
/// could make it reachable from another machine.
///
/// A request lives as long as its connection. Dicavo cancelling an analysis,
/// timing it out or quitting closes the connection, and the request's task
/// is cancelled with it, which ends the command it runs; stopping the bridge
/// cancels every one. Compiled into the application too, like the request
/// handler, so both test suites can drive it; only the bridge starts one.
final class BridgeServer: @unchecked Sendable {
    /// Tried first so the endpoint is stable across launches; if it is taken
    /// the system picks another and the descriptor says which.
    static let preferredPort: UInt16 = 48123
    /// A request has this long to arrive in full; the response may take as
    /// long as the analysis does.
    static let requestDeadline: TimeInterval = 30
    /// Dicavo sends one request at a time per chunk; this is room enough.
    static let maximumConnections = 16

    private let handler: BridgeRequestHandler
    private let queue = DispatchQueue(label: "cz.smartbrains.DicavoBridge.server")
    private var listener: NWListener?
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// The task answering each connection's request, while it runs.
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var requestsInFlight = 0

    init(handler: BridgeRequestHandler) {
        self.handler = handler
    }

    /// Starts listening and returns the port once the listener is ready.
    func start() async throws -> UInt16 {
        do {
            return try await start(on: NWEndpoint.Port(rawValue: Self.preferredPort)!)
        } catch {
            return try await start(on: .any)
        }
    }

    private func start(on port: NWEndpoint.Port) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener = try NWListener(using: parameters)
        lock.withLock { self.listener = listener }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue, once.claim() else { return }
                    continuation.resume(returning: port)
                case let .failed(error):
                    if once.claim() {
                        continuation.resume(throwing: error)
                    }
                    self?.lock.withLock {
                        if self?.listener === listener { self?.listener = nil }
                    }
                case .cancelled:
                    if once.claim() {
                        continuation.resume(throwing: CancellationError())
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// A continuation may be resumed exactly once; the listener reports
    /// state from its own queue, so the guard has to be a lock, not a var.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.withLock {
                if claimed { return false }
                claimed = true
                return true
            }
        }
    }

    /// Requests handed to the handler whose response has not gone out yet.
    /// An update waits for this to reach zero before it replaces the bridge.
    var activeRequestCount: Int {
        lock.withLock { requestsInFlight }
    }

    func stop() {
        let current = lock.withLock { () -> NWListener? in
            let current = listener
            listener = nil
            return current
        }
        current?.cancel()
        let (open, running) = lock.withLock { () -> ([NWConnection], [Task<Void, Never>]) in
            let open = Array(connections.values)
            let running = Array(requests.values)
            connections.removeAll()
            requests.removeAll()
            return (open, running)
        }
        open.forEach { $0.cancel() }
        // Cancelled here rather than left to the connections' state updates,
        // which arrive later on the server's queue: a bridge that is quitting
        // ends its commands before the process goes.
        running.forEach { $0.cancel() }
    }

    /// The connection is gone, whichever side ended it: its request, if one
    /// still runs, is cancelled.
    private func connectionEnded(_ connection: NWConnection) {
        let request = lock.withLock { () -> Task<Void, Never>? in
            connections.removeValue(forKey: ObjectIdentifier(connection))
            return requests.removeValue(forKey: ObjectIdentifier(connection))
        }
        request?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        let admitted = lock.withLock { () -> Bool in
            guard connections.count < Self.maximumConnections else { return false }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }
        guard admitted else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connectionEnded(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        let arrived = RequestArrival()
        queue.asyncAfter(deadline: .now() + Self.requestDeadline) {
            if !arrived.isComplete { connection.cancel() }
        }
        receive(on: connection, parser: BridgeHTTPRequestParser(), arrived: arrived, checkedToken: false)
    }

    private func receive(on connection: NWConnection, parser: BridgeHTTPRequestParser, arrived: RequestArrival, checkedToken: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var parser = parser
            if let error {
                _ = error
                connection.cancel()
                return
            }
            do {
                if let data, !data.isEmpty, let request = try parser.append(data) {
                    arrived.markComplete()
                    self.respond(to: request, on: connection)
                    return
                }
                if !checkedToken, let head = parser.headersOnly {
                    guard self.handler.isAuthorized(head) else {
                        arrived.markComplete()
                        self.send(
                            BridgeRequestHandler.error(status: 401, type: "authentication_error", message: "Missing or invalid bridge token."),
                            on: connection
                        )
                        return
                    }
                    self.receive(on: connection, parser: parser, arrived: arrived, checkedToken: true)
                    return
                }
            } catch let parseError as BridgeHTTPParseError {
                let status = parseError == .bodyTooLarge || parseError == .headersTooLarge ? 413 : 400
                self.send(
                    BridgeRequestHandler.error(status: status, type: "invalid_request_error", message: "Malformed request."),
                    on: connection
                )
                return
            } catch {
                connection.cancel()
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection, parser: parser, arrived: arrived, checkedToken: checkedToken)
        }
    }

    /// Whether the request has arrived, shared between the reader and the
    /// deadline, which run as separate blocks on the server's queue.
    private final class RequestArrival: @unchecked Sendable {
        private let lock = NSLock()
        private var complete = false
        var isComplete: Bool { lock.withLock { complete } }
        func markComplete() { lock.withLock { complete = true } }
    }

    private func respond(to request: BridgeHTTPRequest, on connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.withLock { requestsInFlight += 1 }
        let task = Task {
            let response = await handler.handle(request)
            guard !Task.isCancelled else {
                // The client went away, or the bridge stopped: there is
                // nobody to answer.
                self.requestFinished(id)
                return
            }
            send(response, on: connection) {
                self.requestFinished(id)
            }
        }
        let isOpen = lock.withLock { () -> Bool in
            guard connections[id] != nil else { return false }
            requests[id] = task
            return true
        }
        if !isOpen { task.cancel() }
        watchForDeparture(of: connection)
    }

    private func requestFinished(_ id: ObjectIdentifier) {
        lock.withLock {
            requestsInFlight -= 1
            requests[id] = nil
        }
    }

    /// After its request a client sends nothing more, so whatever the
    /// connection still reports is its end: end of file or an error, as
    /// when Dicavo cancels the request. Reading on is how that is noticed
    /// while the request runs; stray bytes are ignored.
    private func watchForDeparture(of connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.connectionEnded(connection)
                connection.cancel()
                return
            }
            self.watchForDeparture(of: connection)
        }
    }

    private func send(_ response: BridgeHTTPResponse, on connection: NWConnection, completion: (@Sendable () -> Void)? = nil) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
            completion?()
        })
    }
}
