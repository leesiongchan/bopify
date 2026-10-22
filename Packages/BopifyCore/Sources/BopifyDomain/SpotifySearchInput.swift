import Foundation

/// Classifies pasted input without changing the URI contract used by playback.
public enum SpotifySearchInput: Equatable, Sendable {
    case text(String), resource(SpotifyURI), invalidLink, unsupportedLink

    public init(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("spotify:") {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, Self.supports(parts[1]) else { self = .unsupportedLink; return }
            guard parts.count == 3 else { self = .invalidLink; return }
            self = Self.resource(kind: parts[1], id: parts[2])
            return
        }
        let url = URLComponents(string: value)
        let startsWithURL = url?.scheme.map { value.lowercased().hasPrefix("\($0.lowercased())://") } ?? false
        guard startsWithURL || value.lowercased().hasPrefix("http:") || value.lowercased().hasPrefix("https:") else {
            self = .text(value)
            return
        }
        guard !value.contains(where: \.isWhitespace),
              let url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil else { self = .invalidLink; return }
        let host = url.host?.lowercased()
        if host == "spotify.link" || host == "spoti.fi" { self = .unsupportedLink; return }
        guard host == "open.spotify.com", !url.percentEncodedPath.contains("%"), url.path.hasPrefix("/") else {
            self = .invalidLink
            return
        }
        var parts = url.path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        if let prefix = parts.first, prefix.hasPrefix("intl-") {
            guard prefix.utf8.count == 7, prefix.dropFirst(5).utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0)
            }) else { self = .invalidLink; return }
            parts.removeFirst()
        }
        guard let kind = parts.first, !kind.isEmpty else { self = .invalidLink; return }
        guard Self.supports(kind) else { self = .unsupportedLink; return }
        guard parts.count == 2 else { self = .invalidLink; return }
        self = Self.resource(kind: kind, id: parts[1])
    }

    private static func supports(_ kind: String) -> Bool {
        CatalogSearchKind(rawValue: kind) != nil
    }

    private static func resource(kind: String, id: String) -> Self {
        guard !id.isEmpty, id.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }), let uri = SpotifyURI("spotify:\(kind):\(id)") else { return .invalidLink }
        return .resource(uri)
    }
}
