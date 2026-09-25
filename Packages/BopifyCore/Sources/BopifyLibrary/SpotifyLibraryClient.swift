import Foundation
import os
import BopifyDomain

public struct SpotifyLibraryClient: LibraryService {
    private let session: URLSession
    private let tokenProvider: @Sendable (Set<String>) async throws -> String
    private let redirects = LibraryRedirectPolicy()

    public init(session: URLSession = .shared, tokenProvider: @Sendable @escaping (Set<String>) async throws -> String) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    public func savedState(for uri: SpotifyURI) async throws -> Bool {
        let data = try await request(method: "GET", uri: uri, contains: true)
        guard let values = try? JSONDecoder().decode([Bool].self, from: data), values.count == 1 else {
            throw LibraryError.invalidResponse
        }
        return values[0]
    }
    public func save(_ uri: SpotifyURI) async throws { _ = try await request(method: "PUT", uri: uri) }
    public func remove(_ uri: SpotifyURI) async throws { _ = try await request(method: "DELETE", uri: uri) }

    private func request(method: String, uri: SpotifyURI, contains: Bool = false) async throws -> Data {
        guard uri.kind == .track, uri.id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw LibraryError.unavailable
        }
        let token: String
        do { token = try await tokenProvider([contains ? "user-library-read" : "user-library-modify"]) }
        catch let error as LibraryError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch PlayerError.authExpired { throw LibraryError.authorizationRequired }
        catch { throw LibraryError.unavailable }
        try Task.checkCancellation()
        var components = URLComponents(string: "https://api.spotify.com/v1/me/library")!
        if contains { components.path += "/contains" }
        components.queryItems = [URLQueryItem(name: "uris", value: uri.rawValue)]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: redirects) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw LibraryError.unavailable }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw LibraryError.invalidResponse }
        BopifyLog.library.debug("library request method=\(method, privacy: .public) status=\(http.statusCode, privacy: .public)")
        switch http.statusCode {
        case 200: return data
        case 401: throw LibraryError.authorizationRequired
        case 403: throw LibraryError.forbidden
        case 429:
            let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
            throw LibraryError.rateLimited(retryAfterSeconds: seconds)
        case 500...599: throw LibraryError.unavailable
        default: throw LibraryError.invalidResponse
        }
    }
}

// The fixed API endpoint has no legitimate redirect requirement.
final class LibraryRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
