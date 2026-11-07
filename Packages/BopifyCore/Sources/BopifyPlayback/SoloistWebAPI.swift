import Foundation
import BopifyDomain

struct SoloistDevice: Decodable, Hashable, Sendable {
    let id: String?
    let name: String
    let is_restricted: Bool
}

struct SoloistWebPlayback: Sendable {
    let deviceID: String?
    let deviceName: String
    let uri: String?
    let positionMs: Double
    let playing: Bool
    let observedAt: Date
    let track: Track?
}

private final class SoloistHTTPPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Requests are always scoped to the user's own grant and an explicitly verified local device.
actor SoloistWebAPI {
    private let session: URLSession
    private let rateLimit: SoloistRateLimit

    init(session: URLSession? = nil, rateLimit: SoloistRateLimit? = nil) {
        self.rateLimit = rateLimit ?? (session == nil ? .shared : SoloistRateLimit())
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration, delegate: SoloistHTTPPolicy(), delegateQueue: nil)
        }
    }

    func close() { session.invalidateAndCancel() }
    func retryDate() async -> Date { await rateLimit.retryAt }

    private func request(_ path: String, token: String, method: String = "GET", body: Data? = nil,
        device: String? = nil) async throws -> Data? {
        try Task.checkCancellation()
        try await rateLimit.check()
        var url = URLComponents(string: "https://api.spotify.com/v1" + path)!
        if let device {
            guard !device.isEmpty, device.utf8.count <= 256 else { throw SoloistPlaybackError.ambiguousDevice }
            url.queryItems = [URLQueryItem(name: "device_id", value: device)]
        }
        var request = URLRequest(url: url.url!)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw SoloistPlaybackError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw SoloistPlaybackError.invalidState }
        if http.statusCode == 429 {
            let seconds = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            await rateLimit.postpone(seconds: seconds)
            throw SoloistPlaybackError.rateLimited
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw SoloistPlaybackError.authorizationRequired }
        guard (200..<300).contains(http.statusCode) else { throw SoloistPlaybackError.unavailable }
        if http.statusCode == 204 { return nil }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_097_152 else { throw SoloistPlaybackError.invalidState }
            data.append(byte)
        }
        return data
    }

    func account(token: String) async throws -> String {
        guard let data = try await request("/me", token: token),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["account_id"] as? String, !id.isEmpty else { throw SoloistPlaybackError.missingAccountID }
        return id
    }

    func devices(token: String) async throws -> Set<SoloistDevice> {
        struct Response: Decodable { let devices: [SoloistDevice] }
        guard let data = try await request("/me/player/devices", token: token),
              let result = try? JSONDecoder().decode(Response.self, from: data) else { throw SoloistPlaybackError.invalidState }
        return Set(result.devices)
    }

    func playback(token: String) async throws -> SoloistWebPlayback? {
        let observedAt = Date()
        guard let data = try await request("/me/player", token: token) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = object["device"] as? [String: Any], let position = object["progress_ms"] as? Double,
              position.isFinite, position >= 0, let playing = object["is_playing"] as? Bool else { throw SoloistPlaybackError.invalidState }
        let item = object["item"] as? [String: Any]
        var track: Track?
        if let item, let raw = item["uri"] as? String, let uri = SpotifyURI(raw), let name = item["name"] as? String,
           let duration = item["duration_ms"] as? Double, duration.isFinite, (0...31_536_000_000).contains(duration) {
            let artists = (item["artists"] as? [[String: Any]] ?? []).compactMap { ($0["name"] as? String).map(ArtistSummary.init(name:)) }
            let album = item["album"] as? [String: Any]
            let image = (album?["images"] as? [[String: Any]])?.compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }.first { $0.scheme == "https" }
            track = Track(uri: uri, title: name, artists: artists, albumTitle: album?["name"] as? String,
                artwork: image.map(Artwork.init(url:)), durationMs: Int64(duration))
        }
        return SoloistWebPlayback(deviceID: device["id"] as? String, deviceName: device["name"] as? String ?? "Spotify",
            uri: item?["uri"] as? String, positionMs: position, playing: playing, observedAt: observedAt, track: track)
    }

    static func playBody(_ request: PlayRequest) throws -> [String: Any] {
        var body: [String: Any] = ["position_ms": max(0, request.startPositionMs)]
        switch request.contextURI.kind {
        case .track, .episode: body["uris"] = [request.contextURI.rawValue]
        default:
            body["context_uri"] = request.contextURI.rawValue
            if let start = request.startTrackURI {
                guard request.contextURI.kind == .album || request.contextURI.kind == .playlist else { throw SoloistPlaybackError.unsupported }
                body["offset"] = ["uri": start.rawValue]
            }
        }
        return body
    }

    func play(_ request: PlayRequest, deviceID: String, token: String) async throws {
        _ = try await self.request("/me/player/play", token: token, method: "PUT",
            body: JSONSerialization.data(withJSONObject: Self.playBody(request)), device: deviceID)
    }
}
