import Foundation
import CryptoKit
import BopifyDomain

private final class LyricHTTPPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Lyrics are independent of Web API account checks; only the supplied Spotify reader uses credentials.
public actor LyricsResolver {
    private let session: URLSession
    private let cacheDirectory: URL?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let spotifyTimeout: Duration
    private var nextRequest = Date.distantPast
    private var retryAt = Date.distantPast
    private static let cacheLifetime: TimeInterval = 30 * 86_400
    private static let maximumBytes = 1_048_576

    public init(cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("com.leesiongchan.bopify/lyrics", isDirectory: true),
                session: URLSession? = nil) {
        self.init(cacheDirectory: cacheDirectory, session: session, now: Date.init,
                  sleep: { try await Task.sleep(for: $0) }, spotifyTimeout: .seconds(3))
    }

    init(cacheDirectory: URL?, session: URLSession?, now: @escaping @Sendable () -> Date = Date.init,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         spotifyTimeout: Duration = .seconds(3)) {
        self.cacheDirectory = cacheDirectory
        self.now = now
        self.sleep = sleep
        self.spotifyTimeout = spotifyTimeout
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 8
            self.session = URLSession(configuration: configuration, delegate: LyricHTTPPolicy(), delegateQueue: nil)
        }
    }

    public func request(for track: Track,
                        spotify: @escaping @Sendable (SpotifyURI) async throws -> TrackLyrics) async throws -> TrackLyrics {
        try Task.checkCancellation()
        guard track.uri.kind == .track else { throw LyricFailure.noLyrics }
        let cached = readCache(for: track)
        if let cached, now().timeIntervalSince(cached.storedAt) >= 0,
           now().timeIntervalSince(cached.storedAt) < Self.cacheLifetime {
            BopifyLog.playback.debug("lyrics resolved source=cache")
            return cached.lyrics
        }
        do {
            let lyrics = try await lyricWithin(spotifyTimeout) { try await spotify(track.uri) }
            guard Self.valid(lyrics, for: track) else { throw LyricFailure.unavailable }
            try Task.checkCancellation()
            store(lyrics, for: track)
            BopifyLog.playback.debug("lyrics resolved source=spotify")
            return lyrics
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            BopifyLog.playback.debug("lyrics Spotify unavailable; trying independent provider")
        }
        do {
            let lyrics = try await lyricWithin(.seconds(20)) { try await self.lookup(track) }
            try Task.checkCancellation()
            store(lyrics, for: track)
            BopifyLog.playback.info("lyrics resolved source=lrclib")
            return lyrics
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if error as? LyricFailure == .noLyrics { throw LyricFailure.noLyrics }
            if let cached {
                BopifyLog.playback.notice("lyrics resolved source=staleCache")
                return cached.lyrics
            }
            BopifyLog.playback.notice("lyrics provider unavailable")
            throw LyricFailure.network
        }
    }

    private func lookup(_ track: Track) async throws -> TrackLyrics {
        guard track.title.utf8.count <= 1024, !Self.normalized(track.title).isEmpty,
              let artist = track.artists.first?.name, artist.utf8.count <= 1024, !Self.normalized(artist).isEmpty,
              (track.albumTitle?.utf8.count ?? 0) <= 1024,
              (1_000...3_600_000).contains(track.durationMs) else { throw LyricFailure.noLyrics }
        var query = [URLQueryItem(name: "track_name", value: track.title), URLQueryItem(name: "artist_name", value: artist),
                     URLQueryItem(name: "duration", value: String(track.durationMs / 1000))]
        if let album = track.albumTitle, !album.isEmpty { query.append(URLQueryItem(name: "album_name", value: album)) }
        var exactFailure: (any Error)?
        do {
            if let data = try await get("/api/get", query: query) {
                let record = try JSONDecoder().decode(Record.self, from: data)
                if record.matches(track), let lyrics = record.lyrics(for: track.uri), Self.valid(lyrics, for: track) { return lyrics }
                if record.matches(track), record.instrumental { throw LyricFailure.noLyrics }
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            guard error is URLError || (error as? HTTPFailure)?.permitsSearch == true,
                  retryAt.timeIntervalSince(now()) <= 5 else { throw error }
            exactFailure = error
            BopifyLog.playback.debug("lyrics exact lookup unavailable; trying search")
        }
        query = [URLQueryItem(name: "track_name", value: track.title), URLQueryItem(name: "artist_name", value: artist)]
        guard let data = try await get("/api/search", query: query) else {
            if let exactFailure { throw exactFailure }
            throw LyricFailure.noLyrics
        }
        let records = try JSONDecoder().decode([Record].self, from: data)
        guard records.count <= 200 else { throw LyricFailure.unavailable }
        let candidates = records.filter { $0.matches(track) }.sorted {
            let first = abs($0.duration * 1000 - Double(track.durationMs))
            let second = abs($1.duration * 1000 - Double(track.durationMs))
            if first != second { return first < second }
            return Self.normalized($0.albumName) == Self.normalized(track.albumTitle ?? "")
                && Self.normalized($1.albumName) != Self.normalized(track.albumTitle ?? "")
        }
        for record in candidates {
            if let lyrics = record.lyrics(for: track.uri), Self.valid(lyrics, for: track) { return lyrics }
        }
        if let exactFailure { throw exactFailure }
        throw LyricFailure.noLyrics
    }

    private struct HTTPFailure: Error {
        let permitsSearch: Bool
    }

    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data? {
        for attempt in 0...3 {
            try Task.checkCancellation()
            guard now() >= retryAt || retryAt.timeIntervalSince(now()) <= 5 else { throw LyricFailure.network }
            let slot = max(nextRequest, retryAt, now())
            nextRequest = slot.addingTimeInterval(0.25)
            if slot > now() { try await sleep(.seconds(slot.timeIntervalSince(now()))) }
            try Task.checkCancellation()
            guard now() >= retryAt else { throw LyricFailure.network }
            var components = URLComponents(string: "https://lrclib.net" + path)!
            components.queryItems = query
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 5
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.6.0"
            request.setValue("Bopify/\(version) (https://github.com/leesiongchan/bopify)", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw LyricFailure.network }
            let status = response.statusCode
            if status == 429 || (502...504).contains(status) {
                let wait = Self.retryDelay(response, now: now())
                retryAt = max(retryAt, now().addingTimeInterval(wait))
                guard wait <= 5, attempt < (status == 429 ? 3 : 1) else {
                    throw HTTPFailure(permitsSearch: status != 429 && wait <= 5)
                }
                // Reserve the server's complete cooldown; a later caller cannot bypass it.
                continue
            }
            if status == 404 || status == 400 { return nil }
            guard (200..<300).contains(status),
                  response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true else {
                throw HTTPFailure(permitsSearch: (500...599).contains(status))
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumBytes else { throw LyricFailure.unavailable }
                data.append(byte)
            }
            return data
        }
        throw LyricFailure.network
    }

    private static func retryDelay(_ response: HTTPURLResponse, now: Date) -> TimeInterval {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return 1 }
        if let seconds = Double(raw), seconds.isFinite, seconds >= 0 { return seconds + Double.random(in: 0.05...0.2) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        if let deadline = formatter.date(from: raw) { return max(0, deadline.timeIntervalSince(now)) + 0.1 }
        return 60
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private struct Record: Decodable {
        let trackName: String
        let artistName: String
        let albumName: String
        let duration: Double
        let instrumental: Bool
        let plainLyrics: String?
        let syncedLyrics: String?

        func matches(_ track: Track) -> Bool {
            duration.isFinite && abs(duration * 1000 - Double(track.durationMs)) <= 2_000
                && normalized(trackName) == normalized(track.title)
                && track.artists.contains { normalized($0.name) == normalized(artistName) }
        }

        func lyrics(for uri: SpotifyURI) -> TrackLyrics? {
            guard !instrumental else { return nil }
            if let syncedLyrics, let lines = parseLRC(syncedLyrics) {
                return TrackLyrics(trackURI: uri, synchronization: .lineSynced, lines: lines,
                    provider: "lrclib", providerDisplayName: "LRCLIB", isRightToLeft: false)
            }
            guard let plainLyrics, !plainLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return LyricsResolver.recoverLRCLIBTiming(TrackLyrics(trackURI: uri, synchronization: .unsynced,
                lines: plainLyrics.components(separatedBy: .newlines).map { TrackLyricLine(text: $0, startTimeMs: nil) },
                provider: "lrclib", providerDisplayName: "LRCLIB", isRightToLeft: false))
        }
    }

    // LRCLIB submissions can contain LRC in the plain field, including entries cached before normalization.
    private static func recoverLRCLIBTiming(_ lyrics: TrackLyrics) -> TrackLyrics {
        guard lyrics.provider == "lrclib", lyrics.synchronization == .unsynced,
              let lines = parseLRC(lyrics.lines.map(\.text).joined(separator: "\n")) else { return lyrics }
        return TrackLyrics(trackURI: lyrics.trackURI, synchronization: .lineSynced, lines: lines,
            provider: lyrics.provider, providerDisplayName: lyrics.providerDisplayName,
            isRightToLeft: lyrics.isRightToLeft)
    }

    private static func parseLRC(_ text: String) -> [TrackLyricLine]? {
        var lines: [(Int64, Int, String)] = []
        for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            var rest = line[...]
            var times: [Int64] = []
            while rest.first == "[", let end = rest.firstIndex(of: "]") {
                let value = rest[rest.index(after: rest.startIndex)..<end]
                let components = value.split(separator: ":", omittingEmptySubsequences: false)
                if components.count == 2, let minutes = Int64(components[0]), minutes >= 0,
                   let seconds = Double(components[1]), seconds.isFinite, (0..<60).contains(seconds), minutes < 525_600 {
                    times.append(minutes * 60_000 + Int64((seconds * 1000).rounded()))
                } else if times.isEmpty, components.count >= 2,
                          ["ar", "al", "ti", "au", "by", "re", "ve", "length", "offset"].contains(components[0].lowercased()),
                          rest[rest.index(after: end)...].trimmingCharacters(in: .whitespaces).isEmpty {
                    rest = ""; break
                } else { return nil }
                rest = rest[rest.index(after: end)...]
            }
            guard !times.isEmpty else {
                if rest.isEmpty { continue }
                return nil
            }
            for time in times { lines.append((time, lines.count, String(rest).trimmingCharacters(in: .whitespaces))) }
            guard lines.count <= 2_000 else { return nil }
        }
        guard lines.contains(where: { !$0.2.isEmpty }) else { return nil }
        return lines.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { TrackLyricLine(text: $0.2, startTimeMs: $0.0) }
    }

    private static func valid(_ lyrics: TrackLyrics, for track: Track) -> Bool {
        guard lyrics.trackURI == track.uri, !lyrics.lines.isEmpty, lyrics.lines.count <= 2_000,
              lyrics.provider.utf8.count <= 1024, lyrics.providerDisplayName.utf8.count <= 1024 else { return false }
        var bytes = 0, previous: Int64 = -1
        var hasWords = false
        for line in lyrics.lines {
            bytes += line.text.utf8.count
            guard bytes <= 262_144 else { return false }
            hasWords = hasWords || !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            switch lyrics.synchronization {
            case .lineSynced:
                guard let time = line.startTimeMs, time >= previous, time >= 0, time <= 31_536_000_000 else { return false }
                previous = time
            case .unsynced: guard line.startTimeMs == nil else { return false }
            }
        }
        return hasWords
    }

    private struct CacheEntry: Codable {
        struct Line: Codable { let text: String; let start: Int64? }
        let version: Int
        let storedAt: Date
        let uri: String
        let synchronization: LyricSynchronization
        let lines: [Line]
        let provider: String
        let displayName: String
        let rightToLeft: Bool

        var lyrics: TrackLyrics {
            LyricsResolver.recoverLRCLIBTiming(TrackLyrics(trackURI: SpotifyURI(uri)!, synchronization: synchronization,
                lines: lines.map { TrackLyricLine(text: $0.text, startTimeMs: $0.start) },
                provider: provider, providerDisplayName: displayName, isRightToLeft: rightToLeft))
        }
    }

    private func cacheURL(for track: Track) -> URL? {
        guard let cacheDirectory,
              let data = try? JSONSerialization.data(withJSONObject: [track.uri.rawValue, track.title,
                track.artists.map(\.name).joined(separator: "\u{0}"), track.albumTitle ?? "", String(track.durationMs)]) else { return nil }
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(key + ".json")
    }

    private func readCache(for track: Track) -> CacheEntry? {
        guard let url = cacheURL(for: track),
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: Self.maximumBytes + 1), data.count <= Self.maximumBytes,
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data), entry.version == 1,
              entry.uri == track.uri.rawValue, entry.storedAt.timeIntervalSince1970.isFinite,
              entry.storedAt <= now(), Self.valid(entry.lyrics, for: track) else { return nil }
        return entry
    }

    private func store(_ lyrics: TrackLyrics, for track: Track) {
        guard let url = cacheURL(for: track) else { return }
        let entry = CacheEntry(version: 1, storedAt: now(), uri: track.uri.rawValue, synchronization: lyrics.synchronization,
            lines: lyrics.lines.map { CacheEntry.Line(text: $0.text, start: $0.startTimeMs) }, provider: lyrics.provider,
            displayName: lyrics.providerDisplayName, rightToLeft: lyrics.isRightToLeft)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(entry)
            guard data.count <= Self.maximumBytes else { return }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { BopifyLog.playback.debug("lyrics cache write deferred") }
    }
}

/// A canceled or stuck provider cannot keep the visible track's fallback waiting.
private func lyricWithin(_ duration: Duration,
                         operation: @escaping @Sendable () async throws -> TrackLyrics) async throws -> TrackLyrics {
    let (stream, continuation) = AsyncThrowingStream<TrackLyrics, any Error>.makeStream()
    let reader = Task {
        do { continuation.yield(try await operation()); continuation.finish() }
        catch { continuation.finish(throwing: error) }
    }
    let timer = Task {
        do { try await Task.sleep(for: duration); continuation.finish(throwing: LyricFailure.network) }
        catch {}
    }
    continuation.onTermination = { _ in reader.cancel(); timer.cancel() }
    return try await withTaskCancellationHandler {
        var iterator = stream.makeAsyncIterator()
        guard let result = try await iterator.next() else { throw LyricFailure.unavailable }
        try Task.checkCancellation()
        return result
    } onCancel: { continuation.finish(throwing: CancellationError()) }
}
