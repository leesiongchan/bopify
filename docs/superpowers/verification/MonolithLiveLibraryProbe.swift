import Foundation
import BopifyAuth
import BopifyDomain
import BopifyLibrary

@main struct MonolithLiveLibraryProbe {
    static func main() async {
        let auth = SpotifyAuthService(clientID: dashboardLibraryClientID,
                                      store: KeychainTokenStore(service: "my.snsoft.bopify.library"))
        let library = SpotifyLibraryClient { scopes in try await auth.validAccessToken(requiredScopes: scopes) }
        do {
            let page = try await library.savedTracks(offset: 0, limit: 1)
            print("PASS: live saved-track request; decoded track count=\(page.tracks.count)")
        } catch {
            // Only print a known category; never print tokens, URLs, or response bodies.
            switch error {
            case LibraryError.authorizationRequired: print("BLOCKED: existing session lacks library read authorization")
            case LibraryError.forbidden: print("BLOCKED: Spotify denied endpoint access for this client")
            case LibraryError.rateLimited: print("BLOCKED: Spotify returned 429 without a quota marker")
            case LibraryError.quotaExceeded: print("BLOCKED: Spotify reported library quota exhaustion")
            default: print("BLOCKED: live saved-track request unavailable")
            }
            exit(77)
        }
    }
}
