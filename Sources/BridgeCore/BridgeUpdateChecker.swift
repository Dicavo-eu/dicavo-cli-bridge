import Foundation

/// Fetches the update manifest.
///
/// The request carries nothing about the Mac, the meetings or the tools:
/// it is one GET for a static file, over a session that keeps no cookies,
/// no cache and no credentials. What the server necessarily sees is the IP
/// address and the User-Agent, and the privacy policy says so.
struct BridgeUpdateChecker: Sendable {
    let session: URLSession
    let feedURL: URL

    init(session: URLSession = BridgeUpdateChecker.makeSession(), feedURL: URL = BridgeUpdateManifest.feedURL) {
        self.session = session
        self.feedURL = feedURL
    }

    static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }

    func fetchManifest() async throws -> BridgeUpdateManifest {
        guard BridgeUpdateManifest.isTrusted(feedURL) else { throw BridgeUpdateError.untrustedURL }
        var request = URLRequest(url: feedURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BridgeUpdateError.network(error.localizedDescription)
        }
        try Self.check(response)
        return try BridgeUpdateManifest.decode(data)
    }

    /// A redirect that ends anywhere but dicavo.eu is refused, whatever it
    /// returned.
    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw BridgeUpdateError.network("No HTTP response.") }
        if let url = http.url, !BridgeUpdateManifest.isTrusted(url) { throw BridgeUpdateError.untrustedURL }
        guard http.statusCode == 200 else { throw BridgeUpdateError.httpStatus(http.statusCode) }
    }
}
