import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
import BopifyAuth
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

@MainActor @Suite("Music browser integration", .serialized)
struct MusicBrowserTests {
    @Test func typingMultipleCharactersKeepsTheInsertionPointAndArrowKeysSelectResults() async throws {
        let environment = makePreviewEnvironment(.paused)
        defer { environment.searchWindow.close(); environment.player?.stop() }
        environment.showSearch()
        try await Task.sleep(for: .milliseconds(100))
        let window = try #require(NSApp.windows.first { $0.title == String(localized: "search.title") && $0.isVisible })
        let field = try #require(searchField(in: window.contentView))
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        for letter in "Mira" {
            editor.insertText(String(letter), replacementRange: editor.selectedRange())
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(field.stringValue == "Mira")
        #expect(environment.search.query == "Mira")
        try await Task.sleep(for: .milliseconds(400))
        #expect(environment.search.tracks.count == 2)
        let delegate = try #require(field.delegate as? CatalogSearchField.Coordinator)
        #expect(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(environment.search.selectedURI == previewTracks[3].uri)
        #expect(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!environment.searchWindow.isVisible && environment.search.query.isEmpty)
    }

    @Test func commandFFindsMusicEvenWhileEditing() throws {
        let panel = StatusPanel(content: TextField("Example", text: .constant("text")))
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        var opened = 0
        panel.onSearch = { opened += 1 }
        let editor = NSTextView()
        panel.contentView?.addSubview(editor)
        panel.makeFirstResponder(editor)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "f",
            charactersIgnoringModifiers: "f", isARepeat: false, keyCode: UInt16(kVK_ANSI_F)))
        #expect(panel.performKeyEquivalent(with: event))
        #expect(opened == 1)
    }

    @Test func searchConsentRequestsNoPersonalLibraryScopes() async {
        let scopes = BrowserScopes()
        let environment = AppEnvironment(previewPlayer: PlayerModel(), favoriteService: BrowserServices(),
            authorizeLibraryScopes: { await scopes.record($0) })
        await environment.enableSearch()
        #expect(await scopes.values == [Set<String>()])
        await environment.prepareForQuit()
    }

    @Test func noScopeConsentResumesAfterInitialClientSetup() async throws {
        let scopes = BrowserScopes()
        let auth = SpotifyAuthService(clientID: String(repeating: "0", count: 32), store: BrowserTokenStore(), openURL: { _ in })
        let environment = AppEnvironment(previewPlayer: PlayerModel(), favoriteService: BrowserServices(),
            authorizeLibraryScopes: { await scopes.record($0) }, libraryAuth: auth, previewLibraryClientID: nil)
        await environment.enableSearch()
        #expect(await scopes.values.isEmpty)
        await environment.setLibraryClientID(String(repeating: "0", count: 32))
        for _ in 0..<100 {
            if await !scopes.values.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await scopes.values == [Set<String>()])
        environment.librarySetupWindow.close()
        await environment.prepareForQuit()
    }

    @Test func libraryConsentRequestsOnlyCollectionReadScopes() async {
        let scopes = BrowserScopes()
        let environment = AppEnvironment(previewPlayer: PlayerModel(), favoriteService: BrowserServices(),
            authorizeLibraryScopes: { await scopes.record($0) })
        await environment.enableCollections()
        #expect(await scopes.values == [["user-library-read", "playlist-read-private", "playlist-read-collaborative"]])
        await environment.prepareForQuit()
    }

    @Test func signOutClearsSearchAndCollectionsAndClosesSearch() async {
        let services = BrowserServices()
        let environment = AppEnvironment(previewPlayer: PlayerModel(), favoriteService: services,
            searchService: services, collectionsService: services)
        environment.search.updateQuery("song")
        await environment.search.search()
        await environment.collections.reveal(at: Date())
        #expect(!environment.search.tracks.isEmpty && !environment.collections.items.isEmpty)
        environment.showSearch()
        await environment.signOut()
        #expect(environment.search.query.isEmpty && environment.search.tracks.isEmpty)
        #expect(environment.collections.items.isEmpty)
        #expect(!environment.searchWindow.isVisible)
    }
}

@MainActor private func searchField(in view: NSView?) -> NSSearchField? {
    if let field = view as? NSSearchField { return field }
    return view?.subviews.lazy.compactMap { searchField(in: $0) }.first
}

private actor BrowserScopes {
    var values: [Set<String>] = []
    func record(_ scopes: Set<String>) { values.append(scopes) }
}

private struct BrowserTokenStore: TokenStoring {
    func load() throws -> TokenSet? { nil }
    func save(_ tokens: TokenSet) throws {}
    func clear() throws {}
}

private struct BrowserServices: LibraryService, TrackSearchService, LibraryCollectionsService {
    func savedState(for uri: SpotifyURI) async throws -> Bool { false }
    func save(_ uri: SpotifyURI) async throws {}
    func remove(_ uri: SpotifyURI) async throws {}
    func searchTracks(query: String, offset: Int, limit: Int) async throws -> TrackSearchPage {
        TrackSearchPage(tracks: [previewTracks[0]], nextOffset: nil)
    }
    func savedCollections(_ kind: LibraryCollectionKind, offset: Int, limit: Int) async throws -> LibraryCollectionsPage {
        LibraryCollectionsPage(items: [LibraryCollection(uri: SpotifyURI("spotify:playlist:sample")!,
            title: "Sample", subtitle: "Owner", artwork: nil)], nextOffset: nil)
    }
}
