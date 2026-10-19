import Foundation
import os
import BopifyDomain

public struct SpotifyLibraryClient: LibraryService, SavedTracksService, ListeningHistoryService, TrackSearchService, LibraryCollectionsService {
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
        ], scopes: ["user-library-read"])
        guard let page = try? JSONDecoder().decode(APIPage<SavedItem>.self, from: data) else { throw LibraryError.invalidResponse }
        return SavedTracksPage(tracks: page.items.compactMap { $0.value?.track.domain },
                               nextOffset: try page.nextOffset(offset: offset, limit: limit), total: page.total)
    }

    public func recentlyPlayed() async throws -> [RecentPlay] {
        let data = try await request(method: "GET", path: "/v1/me/player/recently-played",
                                     query: [URLQueryItem(name: "limit", value: "50")], scopes: ["user-read-recently-played"])
        guard let page = try? JSONDecoder().decode(RecentPage.self, from: data) else { throw LibraryError.invalidResponse }
        return page.items.compactMap { item in
            item.track?.domain.map { RecentPlay(track: $0, contextURI: item.loadableContext) }
        }
    }

    public func topItems(_ kind: TopItemKind) async throws -> [StationSeed] {
        let data = try await request(method: "GET", path: "/v1/me/top/\(kind.rawValue)", query: [
            URLQueryItem(name: "time_range", value: "medium_term"), URLQueryItem(name: "limit", value: "5")
        ], scopes: ["user-top-read"])
        switch kind {
        case .tracks:
            guard let page = try? JSONDecoder().decode(TopPage<SavedTrack>.self, from: data) else { throw LibraryError.invalidResponse }
            return page.items.compactMap { $0.value?.domain }.map { StationSeed(uri: $0.uri, name: $0.title) }
        case .artists:
            guard let page = try? JSONDecoder().decode(TopPage<TopArtist>.self, from: data) else { throw LibraryError.invalidResponse }
            return page.items.compactMap { $0.value?.seed }
        }
    }

    public func searchTracks(query: String, offset: Int, limit: Int) async throws -> TrackSearchPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, (0...1000).contains(offset), (1...10).contains(limit) else { throw LibraryError.invalidResponse }
        let data = try await request(method: "GET", path: "/v1/search", query: [
            URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: String(limit))
        ], scopes: [])
        guard let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else { throw LibraryError.invalidResponse }
        let next = try response.tracks.nextOffset(offset: offset, limit: limit, maximum: 1000)
        return TrackSearchPage(tracks: response.tracks.items.compactMap { $0.value?.domain }, nextOffset: next)
    }

    public func savedCollections(_ kind: LibraryCollectionKind, cursor: LibraryCollectionCursor, limit: Int) async throws -> LibraryCollectionsPage {
        guard (1...50).contains(limit) else { throw LibraryError.invalidResponse }
        if kind == .artists {
            guard case let .after(after) = cursor, after?.isEmpty != true else { throw LibraryError.invalidResponse }
            var query = [URLQueryItem(name: "type", value: "artist"), URLQueryItem(name: "limit", value: String(limit))]
            if let after { query.append(URLQueryItem(name: "after", value: after)) }
            let data = try await request(method: "GET", path: "/v1/me/following", query: query, scopes: ["user-follow-read"])
            guard let response = try? JSONDecoder().decode(FollowedArtistsResponse.self, from: data),
                  response.artists.items.count <= limit else { throw LibraryError.invalidResponse }
            let page = response.artists
            var next: LibraryCollectionCursor?
            if page.next != nil {
                guard let nextID = page.cursors.after, !nextID.isEmpty, nextID != after, !page.items.isEmpty else {
                    throw LibraryError.invalidResponse
                }
                next = .after(nextID)
            }
            return LibraryCollectionsPage(items: page.items.compactMap { $0.value?.domain(.artists) }, nextCursor: next)
        }
        guard case let .offset(offset) = cursor, offset >= 0 else { throw LibraryError.invalidResponse }
        let scopes: Set<String> = kind == .albums ? ["user-library-read"] : ["playlist-read-private", "playlist-read-collaborative"]
        let data = try await request(method: "GET", path: "/v1/me/\(kind.rawValue)", query: [
            URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: String(limit))
        ], scopes: scopes)
        do {
            switch kind {
            case .albums:
                let page = try JSONDecoder().decode(APIPage<SavedAlbum>.self, from: data)
                return LibraryCollectionsPage(items: page.items.compactMap { $0.value?.album.domain(kind) },
                    nextCursor: try page.nextOffset(offset: offset, limit: limit).map(LibraryCollectionCursor.offset))
            case .playlists:
                let page = try JSONDecoder().decode(APIPage<CollectionEntity>.self, from: data)
                return LibraryCollectionsPage(items: page.items.compactMap { $0.value?.domain(kind) },
                    nextCursor: try page.nextOffset(offset: offset, limit: limit).map(LibraryCollectionCursor.offset))
            case .artists: throw LibraryError.invalidResponse
            }
        } catch { throw LibraryError.invalidResponse }
    }

    private func request(method: String, uri: SpotifyURI, contains: Bool = false) async throws -> Data {
        guard uri.kind == .track, uri.id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw LibraryError.unavailable
        }
        return try await request(method: method, path: "/v1/me/library" + (contains ? "/contains" : ""),
                                 query: [URLQueryItem(name: "uris", value: uri.rawValue)],
                                 scopes: [contains ? "user-library-read" : "user-library-modify"])
    }

    private func request(method: String, path: String, query: [URLQueryItem], scopes: Set<String>) async throws -> Data {
        let token: String
        do { token = try await tokenProvider(scopes) }
        catch let error as LibraryError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch PlayerError.authExpired { throw LibraryError.authorizationRequired }
        catch PlayerError.credentialCorrupt { throw LibraryError.authorizationRequired }
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
        guard let until, let failure else { return }
        let remaining = until.timeIntervalSince(now())
        guard remaining > 0 else { return }
        let seconds = Int(exactly: ceil(remaining)) ?? Int.max
        switch failure {
        case .rateLimited: throw LibraryError.rateLimited(retryAfterSeconds: seconds)
        case .quotaExceeded: throw LibraryError.quotaExceeded(retryAfterSeconds: seconds)
        default: throw failure
        }
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

private struct SavedItem: Decodable {
    let track: SavedTrack
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

private struct RecentPage: Decodable { let items: [RecentItem] }

private struct RecentItem: Decodable {
    struct Context: Decodable { let uri: String }
    let track: SavedTrack?
    let context: Context?
    private enum CodingKeys: String, CodingKey { case track, context }
    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        track = try? container?.decode(SavedTrack.self, forKey: .track)
        context = try? container?.decode(Context.self, forKey: .context)
    }
    /// Only contexts the engine can load with a start track; a Liked Songs collection URI is not one.
    var loadableContext: SpotifyURI? {
        guard let uri = context.flatMap({ SpotifyURI($0.uri) }) else { return nil }
        switch uri.kind {
        case .album, .playlist, .artist, .show: return uri
        default: return nil
        }
    }
}

private struct TopPage<Item: Decodable>: Decodable { let items: [Lenient<Item>] }

/// One malformed item must not discard the rest of the page.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

private struct TopArtist: Decodable {
    let uri: String
    let name: String
    var seed: StationSeed? {
        guard let uri = SpotifyURI(uri), uri.kind == .artist, !name.isEmpty else { return nil }
        return StationSeed(uri: uri, name: name)
    }
}

private struct SearchResponse: Decodable { let tracks: APIPage<SavedTrack> }
private struct SavedAlbum: Decodable { let album: CollectionEntity }

private struct APIPage<Item: Decodable>: Decodable {
    let items: [Lenient<Item>]
    let offset: Int
    let limit: Int
    let total: Int
    let next: String?

    func nextOffset(offset: Int, limit: Int, maximum: Int = .max) throws -> Int? {
        guard self.offset == offset, self.limit == limit, total >= 0, items.count <= limit else { throw LibraryError.invalidResponse }
        let (nextOffset, overflow) = offset.addingReportingOverflow(items.count)
        guard !overflow else { throw LibraryError.invalidResponse }
        return next != nil && !items.isEmpty && nextOffset < total && nextOffset <= maximum ? nextOffset : nil
    }
}

private struct FollowedArtistsResponse: Decodable {
    struct Page: Decodable {
        struct Cursors: Decodable { let after: String? }
        let items: [Lenient<CollectionEntity>]
        let cursors: Cursors
        let next: String?
    }
    let artists: Page
}

private struct CollectionEntity: Decodable {
    struct Owner: Decodable { let display_name: String? }
    let uri: String
    let name: String
    let artists: [SavedTrack.Artist]?
    let owner: Owner?
    let images: [SavedTrack.Image]?

    func domain(_ kind: LibraryCollectionKind) -> LibraryCollection? {
        let uriKind: SpotifyURI.Kind = switch kind {
        case .albums: .album
        case .playlists: .playlist
        case .artists: .artist
        }
        guard let uri = SpotifyURI(uri), uri.kind == uriKind,
              !name.isEmpty, uri.id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        let artwork = images?.compactMap { image -> Artwork? in
            guard let url = URL(string: image.url), url.scheme == "https", url.host != nil else { return nil }
            return Artwork(url: url)
        }.first
        let subtitle = switch kind {
        case .albums: (artists ?? []).map(\.name).joined(separator: ", ")
        case .playlists: owner?.display_name ?? ""
        case .artists: ""
        }
        return LibraryCollection(uri: uri, title: name, subtitle: subtitle, artwork: artwork)
    }
}
