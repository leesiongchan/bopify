import Foundation
import Testing
@testable import BopifyAuth

@Test func soloistKeysRejectEmptyWhitespaceAndControlCharacters() throws {
    #expect(try SoloistKeyStore.validated("  fixture-key\n") == "fixture-key")
    for raw in ["", " \n", "two keys", "key\u{0}value", String(repeating: "a", count: 4097)] {
        #expect(throws: SoloistKeyError.self) { try SoloistKeyStore.validated(raw) }
    }
    #expect(CredentialNamespace.allCases.contains(.soloist))
}

@Test func soloistConsentAddsPlaybackScopesWithoutDroppingLibraryAccess() async throws {
    let opened = AsyncStream<URL>.makeStream()
    let service = SpotifyAuthService(clientID: "fixture", store: InMemoryTokenStore(),
        openURL: { opened.continuation.yield($0) })
    let scopes: Set<String> = ["user-read-playback-state", "user-modify-playback-state"]
    let consent = Task { try await service.authorizeLibrary(additionalScopes: scopes) }
    var iterator = opened.stream.makeAsyncIterator()
    let url = try #require(await iterator.next())
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let requested = Set((items.first { $0.name == "scope" }?.value ?? "").split(separator: " ").map(String.init))
    #expect(requested == LibraryAuthorization.requiredScopes.union(scopes))
    consent.cancel()
    _ = await consent.result
}
