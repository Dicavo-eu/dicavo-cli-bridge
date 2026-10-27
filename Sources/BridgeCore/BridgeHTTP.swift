import Foundation

/// The little of HTTP/1.1 the bridge needs: one request per connection, a
/// request line, headers, an optional `Content-Length` body. No chunked
/// transfer, no keep-alive, no pipelining — the one client is `URLSession`
/// on the same machine, told `Connection: close`.
struct BridgeHTTPRequest: Equatable, Sendable {
    let method: String
    /// The path without the query string.
    let path: String
    /// Header names lowercased; the last occurrence wins.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// The bearer token from `Authorization`, or `nil`.
    var bearerToken: String? {
        guard let value = header("authorization") else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}

enum BridgeHTTPParseError: Error, Equatable {
    case malformedRequestLine
    case malformedHeader
    case headersTooLarge
    case bodyTooLarge
    case invalidContentLength
}

/// Accumulates bytes from a connection and yields the request once the
/// whole of it has arrived.
struct BridgeHTTPRequestParser: Sendable {
    /// Generous for a request line and a dozen headers; small enough that a
    /// stray client streaming garbage is cut off quickly.
    static let maximumHeaderBytes = 64 * 1024
    /// A one-hour transcript chunk is under 100 KB. Sixteen megabytes leaves
    /// room for notes and a very long meeting and still bounds memory.
    static let maximumBodyBytes = 16 * 1024 * 1024

    private var buffer = Data()
    private var head: (method: String, path: String, headers: [String: String], bodyLength: Int)?

    init() {}

    /// The request line and headers as soon as they have arrived, with an
    /// empty body. The server checks the token on this, so a client without
    /// it never makes the bridge hold a body.
    var headersOnly: BridgeHTTPRequest? {
        head.map { BridgeHTTPRequest(method: $0.method, path: $0.path, headers: $0.headers, body: Data()) }
    }

    /// Feeds bytes in; returns the request when complete, `nil` while more is
    /// needed. Throws once the input can no longer be a valid request.
    mutating func append(_ data: Data) throws -> BridgeHTTPRequest? {
        buffer.append(data)
        if head == nil {
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > Self.maximumHeaderBytes { throw BridgeHTTPParseError.headersTooLarge }
                return nil
            }
            if separator.lowerBound > Self.maximumHeaderBytes { throw BridgeHTTPParseError.headersTooLarge }
            let headData = buffer.subdata(in: 0..<separator.lowerBound)
            buffer.removeSubrange(0..<separator.upperBound)
            head = try Self.parseHead(headData)
        }
        guard let head else { return nil }
        if head.bodyLength > Self.maximumBodyBytes { throw BridgeHTTPParseError.bodyTooLarge }
        guard buffer.count >= head.bodyLength else { return nil }
        let body = buffer.prefix(head.bodyLength)
        return BridgeHTTPRequest(
            method: head.method,
            path: head.path,
            headers: head.headers,
            body: Data(body)
        )
    }

    private static func parseHead(_ data: Data) throws -> (String, String, [String: String], Int) {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw BridgeHTTPParseError.malformedRequestLine }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            throw BridgeHTTPParseError.malformedRequestLine
        }
        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw BridgeHTTPParseError.malformedHeader }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw BridgeHTTPParseError.malformedHeader }
            headers[name] = value
        }

        var bodyLength = 0
        if let lengthText = headers["content-length"] {
            guard let length = Int(lengthText), length >= 0 else {
                throw BridgeHTTPParseError.invalidContentLength
            }
            bodyLength = length
        }
        return (method, path, headers, bodyLength)
    }
}

struct BridgeHTTPResponse: Equatable, Sendable {
    let status: Int
    let headers: [(String, String)]
    let body: Data

    init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json(status: Int, object: Any) -> BridgeHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return BridgeHTTPResponse(
            status: status,
            headers: [("Content-Type", "application/json; charset=utf-8")],
            body: body
        )
    }

    /// The bytes to write, with `Content-Length` and `Connection: close`
    /// added so the client knows the response is whole and the socket is
    /// done.
    func serialized() -> Data {
        var lines = ["HTTP/1.1 \(status) \(Self.reasonPhrase(status))"]
        for (name, value) in headers {
            lines.append("\(name): \(value)")
        }
        lines.append("Content-Length: \(body.count)")
        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        var data = Data(lines.joined(separator: "\r\n").utf8)
        data.append(body)
        return data
    }

    static func == (lhs: BridgeHTTPResponse, rhs: BridgeHTTPResponse) -> Bool {
        lhs.status == rhs.status
            && lhs.body == rhs.body
            && lhs.headers.map { "\($0.0):\($0.1)" } == rhs.headers.map { "\($0.0):\($0.1)" }
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Status \(status)"
        }
    }
}
