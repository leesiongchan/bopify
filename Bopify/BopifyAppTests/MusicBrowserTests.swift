import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

@MainActor @Suite("Music browser integration", .serialized)
struct MusicBrowserTests {
    @Test func typingMultipleCharactersKeepsTheInsertionPointAndArrowKeysSelectResults() async throws {
        let environment = makePreviewEnvironment(.paused)
        defer { environment.searchPopover.close(); environment.player?.stop() }
        environment.presentation.sendAttention(.visibility(true))
        environment.presentation.sendAttention(.keyboardFocus(true))
        let controller = PlayerWindowController(previewMode: .expanded)
        let content = RecordPlayerView(player: try #require(environment.player), artworkStore: environment.artworkStore,
                                      presentation: environment.presentation, windowController: controller).environment(environment)
        let panel = StatusPanel(content: content)
        panel.isReleasedWhenClosed = false
        panel.setContentSize(controller.layout.contentSize)
        defer { panel.close() }
        panel.makeKeyAndOrderFront(nil)
        environment.showSearch()
        try await waitUntil { NSApp.windows.contains { $0.isVisible && searchField(in: $0.contentView) != nil } }
        let window = try #require(NSApp.windows.first { $0.isVisible && searchField(in: $0.contentView) != nil })
        #expect(!window.styleMask.contains(.titled))
        #expect(window.frame.width <= 330)
        let field = try #require(searchField(in: window.contentView))
        #expect(field.accessibilitySubrole() == .searchField)
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        for letter in "Mira" {
            editor.insertText(String(letter), replacementRange: editor.selectedRange())
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(field.stringValue == "Mira")
        #expect(environment.search.query == "Mira")
        try await waitUntil { environment.search.tracks.count == 2 && resultTable(in: window.contentView)?.numberOfRows == 2 }
        #expect(environment.search.tracks.count == 2)
        #expect(window.frame.height < 160)
        let table = try #require(resultTable(in: window.contentView))
        #expect(table.numberOfRows == 2)
        #expect(table.rect(ofRow: 0).height == 32)
        #expect(table.selectedRow == -1 && environment.search.selectedURI == nil)
        let delegate = try #require(field.delegate as? CatalogSearchField.Coordinator)
        #expect(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(environment.search.selectedURI == previewTracks[0].uri)
        try await waitUntil { table.selectedRow == 0 }
        #expect(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(environment.search.selectedURI == previewTracks[3].uri)
        try await waitUntil { table.selectedRow == 1 }
        #expect(table.selectedRow == 1)
        #expect(window.firstResponder === editor)
        #expect(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!environment.searchPopover.isVisible && environment.search.query == "Mira")
        environment.showSearch()
        try await waitUntil { NSApp.windows.contains { $0.isVisible && resultTable(in: $0.contentView)?.selectedRow == 1 } }
        let reopened = try #require(NSApp.windows.first { $0.isVisible && searchField(in: $0.contentView) != nil })
        let reopenedTable = try #require(resultTable(in: reopened.contentView))
        #expect(reopenedTable.selectedRow == 1)
        #expect(searchField(in: reopened.contentView)?.stringValue == "Mira")
        let rect = reopenedTable.rect(ofRow: 0)
        let point = reopenedTable.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: reopened.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: reopened.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        reopened.sendEvent(down)
        reopened.sendEvent(up)
        try await waitUntil { !environment.searchPopover.isVisible }
        #expect(!environment.searchPopover.isVisible && environment.search.query == "Mira")
        #expect(environment.search.selectedURI == previewTracks[0].uri)
    }

    @Test func scrollingLeavesSelectionAloneAndReopeningRevealsTheSelectedResult() async throws {
        let tracks = (0..<10).map { index in
            Track(uri: SpotifyURI("spotify:track:result\(index)")!, title: "Result \(index)",
                  artists: [ArtistSummary(name: "Artist")], albumTitle: nil, artwork: nil, durationMs: 180_000)
        }
        let services = BrowserServices(tracks: tracks)
        let environment = AppEnvironment(previewPlayer: PlayerModel(), favoriteService: services, searchService: services)
        defer { environment.searchPopover.close() }
        environment.presentation.sendAttention(.visibility(true))
        environment.presentation.sendAttention(.keyboardFocus(true))
        let panel = StatusPanel(content: SearchButton(environment: environment))
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.makeKeyAndOrderFront(nil)
        environment.search.updateQuery("result")
        await environment.search.search()
        environment.showSearch()
        try await waitUntil { NSApp.windows.contains { $0.isVisible && resultTable(in: $0.contentView)?.numberOfRows == 10 } }
        let window = try #require(NSApp.windows.first { $0.isVisible && resultTable(in: $0.contentView)?.numberOfRows == 10 })
        let table = try #require(resultTable(in: window.contentView))
        let scrollView = try #require(table.enclosingScrollView)
        let contentHeight = scrollView.contentSize.height - scrollView.contentInsets.top - scrollView.contentInsets.bottom
        #expect(contentHeight == 160)
        environment.search.select(tracks[9].uri)
        try await waitUntil { table.selectedRow == 9 && table.visibleRect.intersects(table.rect(ofRow: 9)) }
        table.scrollRowToVisible(0)
        #expect(environment.search.selectedURI == tracks[9].uri)
        #expect(table.visibleRect.intersects(table.rect(ofRow: 0)))
        let point = table.convert(CGPoint(x: table.bounds.midX, y: table.rect(ofRow: 0).midY), to: nil)
        let hover = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        window.sendEvent(hover)
        #expect(environment.search.selectedURI == tracks[9].uri)
        environment.searchPopover.close()
        try await waitUntil { !window.isVisible }
        environment.showSearch()
        try await waitUntil {
            NSApp.windows.contains {
                guard $0.isVisible, let table = resultTable(in: $0.contentView) else { return false }
                return table.selectedRow == 9 && table.visibleRect.intersects(table.rect(ofRow: 9))
            }
        }
        #expect(environment.search.query == "result" && environment.search.tracks == tracks)
    }

    @Test func scrollingToTheBottomLoadsPagesWithoutChangingSelectionOrEditorFocus() async throws {
        let service = PagingSearchService()
        let (environment, panel, window, table) = try await openPagingSearch(service)
        defer { environment.searchPopover.close(); panel.close(); Task { await service.releasePage() } }
        let field = try #require(searchField(in: window.contentView))
        field.selectText(nil)
        let editor = try #require(field.currentEditor())
        let selected = environment.search.tracks[1].uri
        environment.search.select(selected)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await service.offsets == [0])

        await service.holdNextPage()
        table.scrollRowToVisible(9)
        try await waitUntil { environment.search.isLoading }
        table.scrollRowToVisible(0)
        try await Task.sleep(for: .milliseconds(40))
        table.scrollRowToVisible(9)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await service.offsets == [0, 10])
        await service.releasePage()
        try await waitUntil { table.numberOfRows == 20 && !environment.search.isLoading }
        #expect(environment.search.selectedURI == selected && table.selectedRow == 1)
        #expect(window.firstResponder === editor)
        #expect(environment.search.query == "result")

        table.scrollRowToVisible(19)
        try await waitUntil { table.numberOfRows == 25 && !environment.search.hasMore }
        table.scrollRowToVisible(24)
        table.scrollRowToVisible(0)
        try await Task.sleep(for: .milliseconds(40))
        table.scrollRowToVisible(24)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await service.offsets == [0, 10, 20])
        #expect(environment.search.selectedURI == selected && window.firstResponder === editor)
    }

    @Test(arguments: [0, 1])
    func overlappingPageContinuesToFreshResultsWithoutLoadingPastTheVisiblePage(uniqueCount: Int) async throws {
        let service = PagingSearchService(secondPageUniqueCount: uniqueCount)
        let (environment, panel, _, table) = try await openPagingSearch(service)
        defer { environment.searchPopover.close(); panel.close() }
        let selected = environment.search.tracks[1].uri
        environment.search.select(selected)
        try await waitUntil { table.selectedRow == 1 }

        table.scrollRowToVisible(9)
        try await waitUntil { table.numberOfRows == 20 + uniqueCount && !environment.search.isLoading }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await service.offsets == [0, 10, 20])
        #expect(environment.search.hasMore && environment.search.selectedURI == selected)

        table.scrollRowToVisible(19 + uniqueCount)
        try await waitUntil { table.numberOfRows == 25 && !environment.search.hasMore }
        #expect(await service.offsets == [0, 10, 20, 30])
        #expect(environment.search.selectedURI == selected)
    }

    @Test func failedAutomaticPageKeepsResultsUntilExplicitRetry() async throws {
        let service = PagingSearchService()
        let (environment, panel, _, table) = try await openPagingSearch(service)
        defer { environment.searchPopover.close(); panel.close() }
        let original = environment.search.tracks
        environment.search.select(original[1].uri)
        try await waitUntil { table.selectedRow == 1 }
        await service.failNextPages(.unavailable)
        table.scrollRowToVisible(9)
        try await waitUntil { environment.search.error == .unavailable }
        table.scrollRowToVisible(0)
        try await Task.sleep(for: .milliseconds(40))
        table.scrollRowToVisible(9)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await service.offsets == [0, 10])
        #expect(environment.search.tracks == original && table.numberOfRows == 10)
        #expect(environment.search.selectedURI == original[1].uri)

        await service.failNextPages(nil)
        await environment.search.retry(at: Date())
        try await waitUntil { table.numberOfRows == 20 }
        #expect(environment.search.error == nil)
        #expect(await service.offsets == [0, 10, 10])
        #expect(environment.search.selectedURI == original[1].uri)
    }

    @Test func closingSearchRejectsAnAutomaticPageThatFinishesLate() async throws {
        let service = PagingSearchService()
        let (environment, panel, window, table) = try await openPagingSearch(service)
        defer { environment.searchPopover.close(); panel.close(); Task { await service.releasePage() } }
        let original = environment.search.tracks
        await service.holdNextPage()
        table.scrollRowToVisible(9)
        try await waitUntil { environment.search.isLoading }
        environment.searchPopover.close()
        try await waitUntil { !window.isVisible }
        await service.releasePage()
        try await Task.sleep(for: .milliseconds(150))
        #expect(environment.search.tracks == original && !environment.search.isLoading)
        #expect(environment.search.query == "result" && environment.search.hasMore)
        #expect(await service.offsets == [0, 10])
    }

    private func openPagingSearch(_ service: PagingSearchService) async throws -> (AppEnvironment, StatusPanel, NSWindow, NSTableView) {
        let environment = AppEnvironment(previewPlayer: PlayerModel(), favoriteService: BrowserServices(), searchService: service)
        environment.presentation.sendAttention(.visibility(true))
        environment.presentation.sendAttention(.keyboardFocus(true))
        let panel = StatusPanel(content: SearchButton(environment: environment))
        panel.isReleasedWhenClosed = false
        panel.makeKeyAndOrderFront(nil)
        environment.search.updateQuery("result")
        await environment.search.search()
        environment.showSearch()
        try await waitUntil { NSApp.windows.contains { $0.isVisible && resultTable(in: $0.contentView)?.numberOfRows == 10 } }
        let window = try #require(NSApp.windows.first { $0.isVisible && resultTable(in: $0.contentView)?.numberOfRows == 10 })
        return (environment, panel, window, try #require(resultTable(in: window.contentView)))
    }

    private func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    @Test func dismissingAndReopeningSearchKeepsQueryResultsAndSelection() async {
        let environment = makePreviewEnvironment(.paused)
        defer { environment.player?.stop() }
        environment.presentation.sendAttention(.visibility(true))
        environment.search.updateQuery("Mira")
        await environment.search.search()
        environment.search.select(environment.search.tracks[1].uri)
        let tracks = environment.search.tracks
        let selected = environment.search.selectedURI
        environment.showSearch()
        environment.searchPopover.close()
        #expect(environment.search.query == "Mira" && environment.search.tracks == tracks)
        #expect(environment.search.selectedURI == selected && !environment.searchPopover.isVisible)
        environment.showSearch()
        #expect(environment.searchPopover.isVisible && environment.search.query == "Mira")
        environment.searchPopover.close()
        #expect(environment.search.query == "Mira" && environment.search.tracks == tracks)
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

    @Test func playingSearchResultDismissesAndRetainsTheQuery() async {
        let environment = makePreviewEnvironment(.paused)
        defer { environment.player?.stop() }
        environment.presentation.sendAttention(.visibility(true))
        environment.search.updateQuery("Mira")
        await environment.search.search()
        environment.showSearch()
        environment.playSearchResult(previewTracks[0])
        #expect(!environment.searchPopover.isVisible && environment.search.query == "Mira")
        #expect(!environment.search.tracks.isEmpty)
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
        #expect(!environment.searchPopover.isVisible)
    }
}

@MainActor private func searchField(in view: NSView?) -> NSTextField? {
    if let field = view as? NSTextField, field.identifier?.rawValue == "catalog-search-input" { return field }
    return view?.subviews.lazy.compactMap { searchField(in: $0) }.first
}

@MainActor private func resultTable(in view: NSView?) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    return view?.subviews.lazy.compactMap { resultTable(in: $0) }.first
}

private struct BrowserServices: LibraryService, TrackSearchService, LibraryCollectionsService {
    var tracks = [previewTracks[0]]
    func savedState(for uri: SpotifyURI) async throws -> Bool { false }
    func save(_ uri: SpotifyURI) async throws {}
    func remove(_ uri: SpotifyURI) async throws {}
    func searchTracks(query: String, offset: Int, limit: Int) async throws -> TrackSearchPage {
        TrackSearchPage(tracks: tracks, nextOffset: nil)
    }
    func savedCollections(_ kind: LibraryCollectionKind, cursor: LibraryCollectionCursor, limit: Int) async throws -> LibraryCollectionsPage {
        LibraryCollectionsPage(items: [LibraryCollection(uri: SpotifyURI("spotify:playlist:sample")!,
            title: "Sample", subtitle: "Owner", artwork: nil)], nextCursor: nil)
    }
}

private actor PagingSearchService: TrackSearchService {
    private(set) var offsets: [Int] = []
    private let secondPageUniqueCount: Int?
    private var failure: LibraryError?
    private var shouldHold = false
    private var held: CheckedContinuation<Void, Never>?
    private let tracks = (0..<25).map { index in
        Track(uri: SpotifyURI("spotify:track:paged\(index)")!, title: "Result \(index)",
              artists: [ArtistSummary(name: "Artist")], albumTitle: nil, artwork: nil, durationMs: 180_000)
    }

    init(secondPageUniqueCount: Int? = nil) { self.secondPageUniqueCount = secondPageUniqueCount }

    func holdNextPage() { shouldHold = true }
    func releasePage() { held?.resume(); held = nil }
    func failNextPages(_ failure: LibraryError?) { self.failure = failure }

    func searchTracks(query: String, offset: Int, limit: Int) async throws -> TrackSearchPage {
        offsets.append(offset)
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation { held = $0 }
        }
        if let failure { throw failure }
        let overlap = secondPageUniqueCount.map { limit - $0 } ?? 0
        let trackOffset = offset >= limit ? offset - overlap : offset
        return TrackSearchPage(tracks: Array(tracks.dropFirst(trackOffset).prefix(limit)),
                               nextOffset: trackOffset + limit < tracks.count ? offset + limit : nil)
    }
}
