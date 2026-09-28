import Foundation
import os
import BopifyDomain

public struct SpotifyLibraryClient: LibraryService, SavedTracksService {
    private let session: URLSession
    private let tokenProvider: @Sendable (Set<String>) async throws -> String
    private let redirects = LibraryRedirectPolicy()
    private let cooldown: LibraryCooldown

    public init(session: URLSession = .shared, tokenProvider: @Sendable @escaping (Set<String>) async throws -> String) {
        self.init(session: session, tokenProvider: tokenProvider, now: Date.init)
    }

    init(session: URLSession, tokenProvider: @Sendable @escaping (Set<String>) async throws -> String,
         now: @Sendable @escaping () -> Date) {
        self.session = session
        self.tokenProvider = tokenProvider
        cooldown = LibraryCooldown(now: now)
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

    public func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage {
        guard offset >= 0, (1...50).contains(limit) else { throw LibraryError.invalidResponse }
        let data = try await request(method: "GET", path: "/v1/me/tracks", query: [
            URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: String(limit))
        ], scope: "user-library-read")
        guard let page = try? JSONDecoder().decode(SavedPage.self, from: data),
              page.offset == offset, page.limit == limit, page.total >= 0,
              page.items.count <= limit else { throw LibraryError.invalidResponse }
        let (next, overflow) = offset.addingReportingOverflow(page.items.count)
        guard !overflow else { throw LibraryError.invalidResponse }
        let continues = page.next != nil && !page.items.isEmpty && next < page.total
        return SavedTracksPage(tracks: page.items.compactMap { $0.track?.domain },
                               nextOffset: continues ? next : nil, total: page.total)
    }

    private func request(method: String, uri: SpotifyURI, contains: Bool = false) async throws -> Data {
        guard uri.kind == .track, uri.id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw LibraryError.unavailable
        }
        return try await request(method: method, path: "/v1/me/library" + (contains ? "/contains" : ""),
                                 query: [URLQueryItem(name: "uris", value: uri.rawValue)],
                                 scope: contains ? "user-library-read" : "user-library-modify")
    }

    private func request(method: String, path: String, query: [URLQueryItem], scope: String) async throws -> Data {
        let token: String
        do { token = try await tokenProvider([scope]) }
        catch let error as LibraryError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch PlayerError.authExpired { throw LibraryError.authorizationRequired }
        catch { throw LibraryError.unavailable }
        try Task.checkCancellation()
        var components = URLComponents(string: "https://api.spotify.com")!
        components.path = path
        components.queryItems = query
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        try await cooldown.check()
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
            let quota = (try? JSONDecoder().decode(LibraryLimitResponse.self, from: data))?.error.reason == "QUOTA_EXCEEDED"
            let failure: LibraryError = quota ? .quotaExceeded(retryAfterSeconds: seconds) : .rateLimited(retryAfterSeconds: seconds)
            await cooldown.record(failure, seconds: seconds)
            BopifyLog.library.notice("library request limited cause=\(quota ? "quota" : "rate", privacy: .public) retryAfterSeconds=\(seconds ?? -1, privacy: .public)")
            throw failure
        case 500...599: throw LibraryError.unavailable
        default: throw LibraryError.invalidResponse
        }
    }
}

private actor LibraryCooldown {
    private let now: @Sendable () -> Date
    private var until: Date?
    private var failure: LibraryError?

    init(now: @Sendable @escaping () -> Date) { self.now = now }

    func check() throws {
        if let until, now() < until, let failure { throw failure }
    }

    func record(_ failure: LibraryError, seconds: Int?) {
        let deadline = now().addingTimeInterval(TimeInterval(seconds ?? 60))
        if let until, until > deadline { return }
        until = deadline
        self.failure = failure
    }
}

private struct LibraryLimitResponse: Decodable {
    struct Details: Decodable { let reason: String? }
    let error: Details
}

// The fixed API endpoint has no legitimate redirect requirement.
final class LibraryRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct SavedPage: Decodable {
    let items: [SavedItem]
    let offset: Int
    let limit: Int
    let total: Int
    let next: String?
}

private struct SavedItem: Decodable {
    let track: SavedTrack?
    private enum CodingKeys: String, CodingKey { case track }
    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        track = try? container?.decode(SavedTrack.self, forKey: .track)
    }
}

private struct SavedTrack: Decodable {
    struct Artist: Decodable { let name: String }
    struct Image: Decodable { let url: String }
    struct Album: Decodable { let name: String; let images: [Image] }
    let uri: String
    let name: String
    let artists: [Artist]
    let album: Album?
    let duration_ms: Int64
    let is_playable: Bool?
    let is_local: Bool?

    var domain: Track? {
        guard let uri = SpotifyURI(uri), uri.kind == .track,
              uri.id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              duration_ms > 0, !name.isEmpty, is_playable != false, is_local != true else { return nil }
        let artwork = album?.images.compactMap { image -> Artwork? in
            guard let url = URL(string: image.url), url.scheme == "https", url.host != nil else { return nil }
            return Artwork(url: url)
        }.first
        return Track(uri: uri, title: name, artists: artists.map { ArtistSummary(name: $0.name) },
                     albumTitle: album?.name, artwork: artwork, durationMs: duration_ms)
    }
}
