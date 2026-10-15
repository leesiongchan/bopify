import Foundation
import BopifyAuth
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

/// One real recently-played, top-items and station request. Prints counts and categories only:
/// never tokens, URIs, titles or response bodies. Creates a short-lived "Bopify Probe" Connect device.
@main struct LibraryTabsLiveProbe {
    static func main() async {
        var blocked = false
        guard let clientID = ProcessInfo.processInfo.environment["BOPIFY_LIBRARY_CLIENT_ID"]
            .flatMap(LibraryAuthorization.normalized) else {
            print("BLOCKED: set BOPIFY_LIBRARY_CLIENT_ID to your Dashboard app's client ID")
            exit(77)
        }
        let auth = SpotifyAuthService(clientID: clientID,
                                      store: KeychainTokenStore(service: "com.leesiongchan.bopify.library"),
                                      callbackPort: 8898, callbackPath: "/callback")
        let library = SpotifyLibraryClient { scopes in try await auth.validAccessToken(requiredScopes: scopes) }
        var seed: SpotifyURI?
        do {
            let plays = try await library.recentlyPlayed()
            seed = plays.first?.track.uri
            print("PASS: recently played count=\(plays.count) withContext=\(plays.filter { $0.contextURI != nil }.count)")
        } catch { blocked = true; print("BLOCKED: recently played \(category(error))") }
        do {
            let tracks = try await library.topItems(.tracks)
            let artists = try await library.topItems(.artists)
            print("PASS: top items tracks=\(tracks.count) artists=\(artists.count)")
            seed = seed ?? tracks.first?.uri ?? artists.first?.uri
        } catch { blocked = true; print("BLOCKED: top items \(category(error))") }
        guard let seed else { print("BLOCKED: no seed available"); exit(77) }
        do {
            let token = try await SpotifyAuthService(clientID: librespotClientID).validAccessToken()
            let engine = try await LibrespotEngine(accessToken: token, deviceName: "Bopify Probe")
            do {
                let mix = try await engine.requestRadio(seed: seed)
                print("PASS: station seedKind=\(seed.kind) contextKind=\(mix.contextURI.kind) tracks=\(mix.tracks.count)")
            } catch { blocked = true; print("BLOCKED: station \(category(error))") }
            await engine.shutdown()
        } catch { blocked = true; print("BLOCKED: playback engine \(category(error))") }
        exit(blocked ? 77 : 0)
    }

    static func category(_ error: any Error) -> String {
        switch error {
        case let failure as RadioFailure: "radio.\(failure.rawValue)"
        case let failure as LibraryError: "library.\(failure)"
        case let failure as PlayerError: "player.\(failure)"
        default: "unexpected"
        }
    }
}
