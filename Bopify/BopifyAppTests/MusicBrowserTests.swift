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
        try await waitUntil { searchWindow() != nil }
        let window = try #require(searchWindow())
        #expect(!window.styleMask.contains(.titled) && window.frame.width <= 330)
        let field = try #require(searchField(in: window.contentView))
        #expect(field.accessibilitySubrole() == .searchField)
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        for letter in "Mira" {
            editor.insertText(String(letter), replacementRange: editor.selectedRange())
            await Task.yield()
        }
        #expect(field.stringValue == "Mira" && environment.search.query == "Mira")
        try await waitUntil { environment.search.results.filter { $0.kind == .song }.count == 2 && resultTable(in: window.contentView) != nil }
        let table = try #require(resultTable(in: window.contentView))
        #expect(table.selectedRow == -1 && environment.search.selectedURI == nil)
        let delegate = try #require(field.delegate as? CatalogSearchField.Coordinator)
        #expect(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(environment.search.selectedURI == SpotifyURI("spotify:artist:preview0"))
        try await waitUntil { table.selectedRow >= 0 }
        let firstRow = table.selectedRow
        #expect(table.rect(ofRow: firstRow).height == 32)
        #expect(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(environment.search.selectedURI == SpotifyURI("spotify:artist:preview1"))
        try await waitUntil { table.selectedRow > firstRow }
        #expect(window.firstResponder === editor)
        #expect(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        environment.showSearch()
        try await waitUntil { searchWindow().flatMap { resultTable(in: $0.contentView) }?.selectedRow == firstRow + 1 }
        let reopened = try #require(searchWindow())
        let reopenedTable = try #require(resultTable(in: reopened.contentView))
        #expect(searchField(in: reopened.contentView)?.stringValue == "Mira")
        let rect = reopenedTable.rect(ofRow: firstRow)
        let point = reopenedTable.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: reopened.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            reopened.sendEvent(event)
        }
        try await waitUntil { !environment.searchPopover.isVisible }
        #expect(environment.search.query == "Mira" && environment.search.selectedURI == SpotifyURI("spotify:artist:preview0"))
    }

    @Test func scrollingLeavesSelectionAloneAndReopeningRevealsTheSelectedResult() async throws {
        let tracks = (0..<10).map { index in
            Track(uri: SpotifyURI("spotify:track:result\(index)")!, title: "Result \(index)",
                  artists: [ArtistSummary(name: "Artist")], albumTitle: nil, artwork: nil, durationMs: 180_000)
        }
        let (environment, panel, window) = try await openSearch(BrowserServices(tracks: tracks))
        defer { environment.searchPopover.close(); panel.close() }
        await environment.search.loadMore(.song)
        try await waitUntil { environment.search.results.count == 10 }
        let table = try #require(resultTable(in: window.contentView))
        let scroll = try #require(table.enclosingScrollView)
        try await waitUntil { table.numberOfRows >= 10 }
        #expect(scroll.contentSize.height - scroll.contentInsets.top - scroll.contentInsets.bottom == 292)
        environment.search.select(tracks[0].uri)
        try await waitUntil { table.selectedRow >= 0 }
        let firstRow = table.selectedRow
        environment.search.select(tracks[9].uri)
        try await waitUntil { table.selectedRow > firstRow && table.visibleRect.intersects(table.rect(ofRow: table.selectedRow)) }
        let selectedRow = table.selectedRow
        table.scrollRowToVisible(firstRow)
        #expect(environment.search.selectedURI == tracks[9].uri)
        #expect(table.visibleRect.intersects(table.rect(ofRow: firstRow)))
        environment.searchPopover.close()
        environment.showSearch()
        try await waitUntil { searchWindow().flatMap { resultTable(in: $0.contentView) }?.selectedRow == selectedRow }
        let reopened = try #require(searchWindow())
        let reopenedTable = try #require(resultTable(in: reopened.contentView))
        try await waitUntil { reopenedTable.visibleRect.intersects(reopenedTable.rect(ofRow: selectedRow)) }
        #expect(environment.search.results == tracks.map(CatalogSearchResult.song))
    }

    @Test func mixedResultsHaveNoHeadingsAndOneMoreControl() async throws {
        var service = groupedServices()
        service.collections[.artist]?[0] = LibraryCollection(uri: SpotifyURI("spotify:artist:sample0")!,
            title: "Result", subtitle: "", artwork: nil)
        let (environment, panel, window) = try await openSearch(service)
        defer { environment.searchPopover.close(); panel.close() }
        let table = try #require(resultTable(in: window.contentView))
        let scroll = try #require(table.enclosingScrollView)
        #expect(abs(table.frame.width - 300) < 1)
        #expect(scroll.contentSize.height - scroll.contentInsets.top - scroll.contentInsets.bottom == 288)
        #expect(table.numberOfRows == 9 && searchGroupRows(table).isEmpty)
        for row in 0..<table.numberOfRows { #expect(table.rect(ofRow: row).height == 32) }
        #expect(environment.search.results.first?.uri == SpotifyURI("spotify:artist:sample0"))
        #expect(Set(environment.search.results.map(\.kind)) == Set(CatalogSearchKind.allCases))
        environment.search.moveSelection(by: 1)
        try await waitUntil { table.selectedRow == 0 }
        environment.search.moveSelection(by: 1)
        try await waitUntil { table.selectedRow == 1 }
    }

    @Test func singleMoreLoadsUnfinishedTypesAndDisappearsAtExhaustion() async throws {
        let service = PagingSearchService()
        let (environment, panel, window) = try await openSearch(service)
        defer { environment.searchPopover.close(); panel.close() }
        let table = try #require(resultTable(in: window.contentView))
        for count in [21, 31, 34] {
            try await waitUntil { table.numberOfRows == environment.search.results.count + 1 }
            try pressSearchControl(in: table, row: environment.search.results.count)
            try await waitUntil { environment.search.results.count == count && environment.search.groups.allSatisfy { !$0.isLoading } }
        }
        try await waitUntil { table.numberOfRows == 34 }
        #expect(environment.search.groups.allSatisfy { !$0.hasMore })
        #expect(await service.requests.count == 7)
        #expect(await service.requests.suffix(2) == [
            BrowserRequest(kinds: [.song], offset: 12, limit: 10),
            BrowserRequest(kinds: [.song], offset: 22, limit: 10)])
    }

    @Test func filteredFirstPageKeepsMoreAndRetryUntilResultsAreExhausted() async throws {
        let service = PagingSearchService()
        await service.filterInitialPage()
        let (environment, panel, window) = try await openSearch(service)
        defer { environment.searchPopover.close(); panel.close() }
        #expect(environment.search.hasSearched && environment.search.results.isEmpty)
        let table = try #require(resultTable(in: window.contentView))
        #expect(table.numberOfRows == 1)
        await service.failNextPages(.unavailable)
        try pressSearchControl(in: table, row: 0)
        try await waitUntil { environment.search.groups.first?.error == .unavailable }
        try await waitUntil { table.numberOfRows == 1 }
        await service.failNextPages(nil)
        try pressSearchControl(in: table, row: 0)
        try await waitUntil { environment.search.results.count == 10 }
        #expect(await service.requests.map(\.offset) == [0, 2, 2])
        #expect(environment.search.results.allSatisfy { $0.kind == .song })
    }

    @Test func paginationAuthorizationFailureReturnsToSetup() async throws {
        let service = PagingSearchService()
        let environment = AppEnvironment(previewPlayer: PlayerModel(), favoriteService: BrowserServices(), searchService: service)
        let host = NSHostingView(rootView: PlayerRootView(environment: environment).frame(width: 410, height: 560))
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 410, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        environment.search.updateQuery("result")
        await environment.search.search()
        #expect(environment.search.results.count == 8 && environment.search.error == nil)
        await service.failNextPages(.authorizationRequired)
        await environment.search.loadMore(.song)
        try await waitUntil { environment.authState == .needsLibraryAuthorization && environment.player == nil }
        #expect(environment.search.query.isEmpty && environment.search.results.isEmpty)
    }

    @Test func shortMixedSearchDoesNotClipResults() async throws {
        let (environment, panel, window) = try await openSearch(BrowserServices())
        defer { environment.searchPopover.close(); panel.close() }
        let table = try #require(resultTable(in: window.contentView))
        let scroll = try #require(table.enclosingScrollView)
        let visible = scroll.contentSize.height - scroll.contentInsets.top - scroll.contentInsets.bottom
        #expect(visible >= table.frame.height)
        #expect(visible < 292)
    }

    @Test func emptyGroupsStayHiddenAndEmptySearchDoesNotRefetchOnReopen() async throws {
        let services = BrowserServices(tracks: [])
        let (environment, panel, window) = try await openSearch(services)
        defer { environment.searchPopover.close(); panel.close() }
        #expect(window.frame.height < 100)
        #expect(resultTable(in: window.contentView) == nil && environment.search.hasSearched)
        environment.searchPopover.close()
        environment.showSearch()
        try await waitUntil { searchWindow() != nil }
        #expect(environment.search.hasSearched && !environment.search.isLoading)
    }

    @Test func cancelledInitialSearchRestartsWhenReopened() async throws {
        let service = PagingSearchService()
        await service.holdNextPage()
        let (environment, panel, _) = try await openSearch(service, preload: false)
        defer { environment.searchPopover.close(); panel.close(); Task { await service.releasePage() } }
        await service.waitUntilHeld()
        environment.searchPopover.close()
        await service.releasePage()
        environment.showSearch()
        try await waitUntil { environment.search.hasSearched }
        #expect(await service.requests.count == 2)
        #expect(environment.search.results.count == 8)
    }

    @Test func singleMoreRetainsSelectionAndEditorFocus() async throws {
        let service = PagingSearchService()
        let (environment, panel, window) = try await openSearch(service)
        defer { environment.searchPopover.close(); panel.close(); Task { await service.releasePage() } }
        let table = try #require(resultTable(in: window.contentView))
        let field = try #require(searchField(in: window.contentView))
        field.selectText(nil)
        let editor = try #require(field.currentEditor())
        let selected = try #require(environment.search.results.last?.uri)
        environment.search.select(selected)
        table.scrollRowToVisible(table.numberOfRows - 1)
        await Task.yield()
        #expect(await service.requests.count == 1)
        await service.holdNextPage(.song)
        let more = environment.search.results.count
        try pressSearchControl(in: table, row: more)
        try pressSearchControl(in: table, row: more)
        await service.waitUntilHeld()
        try await waitUntil { environment.search.groups.filter { $0.kind != .song }.allSatisfy { !$0.isLoading && $0.results.count == 3 } }
        #expect(await service.requests.count == 5)
        #expect(environment.search.groups.first { $0.kind == .song }?.isLoading == true)
        await service.releasePage()
        try await waitUntil { environment.search.results.count == 21 }
        #expect(environment.search.selectedURI == selected)
        try await waitUntil { table.selectedRow >= 0 && table.visibleRect.intersects(table.rect(ofRow: table.selectedRow)) }
        #expect(window.firstResponder === editor)
        #expect(Set(await service.requests.dropFirst().map(\.kinds)) == Set(CatalogSearchKind.allCases.map { Set([$0]) }))
    }

    @Test func typeRetryAndLateReplyRespectDismissal() async throws {
        let service = PagingSearchService()
        let (environment, panel, window) = try await openSearch(service)
        defer { environment.searchPopover.close(); panel.close(); Task { await service.releasePage() } }
        let table = try #require(resultTable(in: window.contentView))
        await service.failNextPages(.unavailable, for: .song)
        try pressSearchControl(in: table, row: environment.search.results.count)
        try await waitUntil { environment.search.groups.first { $0.kind == .song }?.error == .unavailable &&
            environment.search.groups.allSatisfy { !$0.isLoading } }
        #expect(environment.search.results.count == 11 && environment.search.error == nil)
        let original = environment.search.results
        try await waitUntil { table.numberOfRows == 12 }
        await service.failNextPages(nil, for: .song)
        await service.holdNextPage(.song)
        try pressSearchControl(in: table, row: original.count)
        await service.waitUntilHeld()
        environment.searchPopover.close()
        await service.releasePage()
        for _ in 0..<10 { await Task.yield() }
        #expect(environment.search.results == original)
        #expect(environment.search.groups.first { $0.kind == .song }?.nextOffset == 2)
        environment.showSearch()
        try await waitUntil { searchWindow() != nil }
        #expect(await service.requests.count == 6)
        #expect(await service.requests.last == BrowserRequest(kinds: [.song], offset: 2, limit: 10))
    }

    @Test(arguments: CatalogSearchKind.allCases)
    func arrowKeysCrossGroupsAndReturnPlaysEachKind(_ kind: CatalogSearchKind) async throws {
        let engine = LiveLyricTestEngine()
        let player = PlayerModel(engine: engine)
        player.start()
        let (environment, panel, window) = try await openSearch(groupedServices(), player: player)
        defer { environment.searchPopover.close(); panel.close(); player.stop() }
        let field = try #require(searchField(in: window.contentView))
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        let delegate = try #require(field.delegate as? CatalogSearchField.Coordinator)
        let result = try #require(environment.search.results.first { $0.kind == kind })
        for _ in 0..<environment.search.results.count {
            #expect(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
            if environment.search.selectedURI == result.uri { break }
        }
        #expect(environment.search.selectedURI == result.uri)
        #expect(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        try await waitUntil { engine.loadRequests.last == PlayRequest(contextURI: result.uri) }
        #expect(!environment.searchPopover.isVisible && environment.search.query == "result")
        #expect(environment.search.results.count == 8)
    }

    @Test func compositionAndAccessibleLabelsWorkForAllKinds() async throws {
        let title = "とても長い検索結果 🎵 Résumé and the quiet morning beyond the horizon"
        let (environment, panel, window) = try await openSearch(groupedServices(title: title))
        defer { environment.searchPopover.close(); panel.close() }
        for result in environment.search.results {
            let type = switch result.kind {
            case .song: String(localized: "search.type.song")
            case .album: String(localized: "search.type.album")
            case .artist: String(localized: "search.type.artist")
            case .playlist: String(localized: "search.type.playlist")
            }
            let expected = result.kind == .artist ? "\(type), \(result.title)" : "\(type), \(result.title), \(result.subtitle)"
            #expect(result.searchAccessibilityLabel == expected)
            #expect(result.searchAccessibilityLabel.contains(title))
        }
        let field = try #require(searchField(in: window.contentView))
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        let delegate = try #require(field.delegate as? CatalogSearchField.Coordinator)
        #expect(!delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        #expect(editor.hasMarkedText())
        #expect(!delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(!delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        editor.unmarkText()
        #expect(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!environment.searchPopover.isVisible)
    }

    private func openSearch(_ service: any CatalogSearchService, preload: Bool = true,
                            player: PlayerModel = PlayerModel()) async throws -> (AppEnvironment, StatusPanel, NSWindow) {
        let environment = AppEnvironment(previewPlayer: player, favoriteService: BrowserServices(), searchService: service)
        environment.presentation.sendAttention(.visibility(true))
        environment.presentation.sendAttention(.keyboardFocus(true))
        let panel = StatusPanel(content: SearchButton(environment: environment))
        panel.isReleasedWhenClosed = false
        panel.makeKeyAndOrderFront(nil)
        environment.search.updateQuery("result")
        if preload { await environment.search.search() }
        environment.showSearch()
        try await waitUntil { searchWindow() != nil }
        return (environment, panel, try #require(searchWindow()))
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
        environment.search.select(environment.search.results[1].uri)
        let results = environment.search.results
        let selected = environment.search.selectedURI
        environment.showSearch()
        environment.searchPopover.close()
        #expect(environment.search.query == "Mira" && environment.search.results == results)
        #expect(environment.search.selectedURI == selected && !environment.searchPopover.isVisible)
        environment.showSearch()
        #expect(environment.searchPopover.isVisible && environment.search.query == "Mira")
        environment.searchPopover.close()
        #expect(environment.search.results == results)
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
        environment.playSearchResult(.song(previewTracks[0]))
        #expect(!environment.searchPopover.isVisible && environment.search.query == "Mira")
        #expect(!environment.search.results.isEmpty)
    }

    @Test func signOutClearsSearchAndCollectionsAndClosesSearch() async {
        let services = BrowserServices()
        let environment = AppEnvironment(previewPlayer: PlayerModel(), favoriteService: services,
            searchService: services, collectionsService: services)
        environment.search.updateQuery("song")
        await environment.search.search()
        await environment.collections.reveal(at: Date())
        #expect(!environment.search.results.isEmpty && !environment.collections.items.isEmpty)
        environment.showSearch()
        await environment.signOut()
        #expect(environment.search.query.isEmpty && environment.search.results.isEmpty)
        #expect(environment.collections.items.isEmpty && !environment.searchPopover.isVisible)
    }
}

@MainActor private func searchWindow() -> NSWindow? {
    NSApp.windows.first { $0.isVisible && searchField(in: $0.contentView) != nil }
}

@MainActor private func searchField(in view: NSView?) -> NSTextField? {
    if let field = view as? NSTextField, field.identifier?.rawValue == "catalog-search-input" { return field }
    return view?.subviews.lazy.compactMap { searchField(in: $0) }.first
}

@MainActor private func resultTable(in view: NSView?) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    return view?.subviews.lazy.compactMap { resultTable(in: $0) }.first
}

@MainActor private func searchGroupRows(_ table: NSTableView) -> [Int] {
    (0..<table.numberOfRows).filter { row in
        if let outline = table as? NSOutlineView, let item = outline.item(atRow: row) {
            return outline.delegate?.outlineView?(outline, isGroupItem: item) ?? false
        }
        return table.delegate?.tableView?(table, isGroupRow: row) ?? false
    }
}

@MainActor private func pressSearchControl(in table: NSTableView, row: Int) throws {
    table.scrollRowToVisible(row)
    let view = try #require(table.rowView(atRow: row, makeIfNecessary: true))
    let window = try #require(table.window)
    let point = view.convert(CGPoint(x: view.bounds.maxX - 18, y: view.bounds.midY), to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        window.sendEvent(event)
    }
}

private nonisolated struct BrowserRequest: Equatable, Sendable {
    let kinds: Set<CatalogSearchKind>
    let offset: Int
    let limit: Int
}

private nonisolated struct BrowserServices: LibraryService, CatalogSearchService, LibraryCollectionsService {
    var tracks = [previewTracks[0]]
    var collections: [CatalogSearchKind: [LibraryCollection]] = [:]
    func savedState(for uri: SpotifyURI) async throws -> Bool { false }
    func save(_ uri: SpotifyURI) async throws {}
    func remove(_ uri: SpotifyURI) async throws {}
    func search(query: String, kinds: Set<CatalogSearchKind>, offset: Int, limit: Int) async throws -> [CatalogSearchKind: CatalogSearchPage] {
        Dictionary(uniqueKeysWithValues: kinds.map { kind in
            let all: [CatalogSearchResult] = switch kind {
            case .song: tracks.map(CatalogSearchResult.song)
            case .album: (collections[kind] ?? []).map(CatalogSearchResult.album)
            case .artist: (collections[kind] ?? []).map(CatalogSearchResult.artist)
            case .playlist: (collections[kind] ?? []).map(CatalogSearchResult.playlist)
            }
            let page = Array(all.dropFirst(offset).prefix(limit))
            return (kind, CatalogSearchPage(results: page, nextOffset: offset + page.count < all.count ? offset + page.count : nil))
        })
    }
    func savedCollections(_ kind: LibraryCollectionKind, cursor: LibraryCollectionCursor, limit: Int) async throws -> LibraryCollectionsPage {
        LibraryCollectionsPage(items: [LibraryCollection(uri: SpotifyURI("spotify:playlist:sample")!,
            title: "Sample", subtitle: "Owner", artwork: nil)], nextCursor: nil)
    }
}

nonisolated private func groupedServices(title: String = "Result") -> BrowserServices {
    let tracks = (0..<25).map { Track(uri: SpotifyURI("spotify:track:paged\($0)")!, title: "\(title) \($0)",
        artists: [ArtistSummary(name: "Artist")], albumTitle: nil, artwork: nil, durationMs: 180_000) }
    let collections = Dictionary(uniqueKeysWithValues: [CatalogSearchKind.album, .artist, .playlist].map { kind in
        (kind, (0..<3).map { LibraryCollection(uri: SpotifyURI("spotify:\(kind.rawValue):sample\($0)")!,
            title: "\(title) \($0)", subtitle: kind == .artist ? "" : "Owner", artwork: nil) })
    })
    return BrowserServices(tracks: tracks, collections: collections)
}

private actor PagingSearchService: CatalogSearchService {
    private(set) var requests: [BrowserRequest] = []
    private var failure: LibraryError?
    private var failures: [CatalogSearchKind: LibraryError] = [:]
    private var heldKind: CatalogSearchKind?
    private var filteredInitialPage = false
    func filterInitialPage() { filteredInitialPage = true }
    private var shouldHold = false
    private var held: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func holdNextPage(_ kind: CatalogSearchKind? = nil) { shouldHold = true; heldKind = kind }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func releasePage() { held?.resume(); held = nil }
    func failNextPages(_ failure: LibraryError?, for kind: CatalogSearchKind? = nil) {
        if let kind { failures[kind] = failure } else { self.failure = failure }
    }
    func search(query: String, kinds: Set<CatalogSearchKind>, offset: Int, limit: Int) async throws -> [CatalogSearchKind: CatalogSearchPage] {
        requests.append(BrowserRequest(kinds: kinds, offset: offset, limit: limit))
        if shouldHold && (heldKind.map { kinds == [$0] } ?? true) {
            shouldHold = false
            await withCheckedContinuation { held = $0; started?.resume(); started = nil }
        }
        if let failure { throw failure }
        for kind in kinds { if let failure = failures[kind] { throw failure } }
        if filteredInitialPage && offset == 0 {
            return Dictionary(uniqueKeysWithValues: kinds.map {
                ($0, CatalogSearchPage(results: [], nextOffset: $0 == .song ? 2 : nil))
            })
        }
        return try await groupedServices().search(query: query, kinds: kinds, offset: offset, limit: limit)
    }
}
