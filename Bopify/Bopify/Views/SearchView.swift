import SwiftUI
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

struct SearchView: View {
    let environment: AppEnvironment
    @State private var text = ""
    private var model: SearchModel { environment.search }
    private var canPlay: Bool { environment.authState == .signedIn && environment.player?.isEngineReady == true }
    private var visibleGroups: [CatalogSearchGroup] { model.groups.filter { !$0.results.isEmpty || $0.hasMore || $0.error != nil } }
    private var resultsHeight: CGFloat {
        min(292, visibleGroups.reduce(0) { $0 + 32 + CGFloat($1.results.count) * 32 + ($1.error == nil ? 0 : 44) })
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        _text = State(initialValue: environment.search.query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                CatalogSearchField(text: Binding(get: { text }, set: {
                    text = $0
                    model.updateQuery($0)
                }), focusRevision: environment.searchPopover.focusRevision,
                onNavigate: model.moveSelection(by:), onPlay: playSelection,
                onDismiss: { environment.searchPopover.close() })
                .frame(height: 24)
                if model.isLoading { ProgressView().controlSize(.small).accessibilityLabel(Text("search.loading")) }
                if !text.isEmpty {
                    Button {
                        text = ""
                        model.updateQuery("")
                        environment.showSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 20, height: 24)
                    }
                    .buttonStyle(.plain).accessibilityLabel(Text("search.clear"))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            if !model.query.isEmpty {
                Divider().padding(.horizontal, 4)
                if !visibleGroups.isEmpty { resultList }
                if let error = model.error { errorState(error).font(.caption).padding(6) }
                else if visibleGroups.isEmpty {
                    Text(model.isLoading ? "search.loading" : "search.empty")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(6)
                        .accessibilityIdentifier("catalog-search-empty")
                }
            }
        }
        .frame(width: 300)
        .task(id: model.query) {
            if !model.hasSearched && model.error == nil { await model.search() }
        }
        .onExitCommand { environment.searchPopover.close() }
    }

    private var resultList: some View {
        ScrollViewReader { scroll in
            List(selection: Binding(get: { model.selectedURI }, set: { uri in
                if let uri { model.select(uri) }
            })) {
                ForEach(visibleGroups, id: \.kind) { group in
                    groupHeader(group)
                        .selectionDisabled()
                        .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                    ForEach(group.results, id: \.uri) { result in
                        row(result).tag(result.uri).id(result.uri)
                            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                    }
                    if let error = group.error {
                        errorState(error, kind: group.kind)
                            .frame(height: 44).padding(.horizontal, 4)
                            .selectionDisabled()
                            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 32)
            .scrollContentBackground(.hidden)
            .frame(height: resultsHeight)
            .task(id: environment.searchPopover.focusRevision) { await revealSelection(in: scroll) }
            .task(id: model.selectedURI) { await revealSelection(in: scroll) }
            .task(id: model.results.map(\.uri)) { await revealSelection(in: scroll) }
        }
    }

    private func revealSelection(in scroll: ScrollViewProxy) async {
        await Task.yield()
        guard !Task.isCancelled, let uri = model.selectedURI else { return }
        scroll.scrollTo(uri, anchor: .center)
    }

    private func groupHeader(_ group: CatalogSearchGroup) -> some View {
        HStack {
            Text(group.kind.title).fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("catalog-search-group-\(group.kind.rawValue)")
            Spacer()
            if group.isLoading {
                ProgressView().controlSize(.mini).accessibilityLabel(Text("search.loading"))
            } else if group.hasMore && group.error == nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Button("search.more") {
                        environment.showSearch()
                        Task { await model.loadMore(group.kind) }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.retryAfter.map { $0 > context.date } ?? false)
                    .accessibilityLabel(Text("search.more \(group.kind.title)"))
                    .accessibilityIdentifier("catalog-search-more-\(group.kind.rawValue)")
                }
            }
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(.horizontal, 4).frame(height: 32).textCase(nil)
    }

    private func row(_ result: CatalogSearchResult) -> some View {
        Button {
            model.select(result.uri)
            play(result)
        } label: {
            HStack(spacing: 6) {
                Group {
                    if let url = result.artwork?.url, let image = environment.artworkStore.image(for: url) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        ZStack { Color.primary.opacity(0.06); Image(.bopRecord).foregroundStyle(.secondary) }
                    }
                }
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: result.kind == .artist ? 11 : 4)).accessibilityHidden(true)
                HStack(spacing: 4) {
                    Text(result.title).fontWeight(.medium).lineLimit(1).layoutPriority(1)
                    if !result.subtitle.isEmpty {
                        Text("·").foregroundStyle(.secondary)
                        Text(result.subtitle).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: result.kind.symbol).font(.system(size: 11))
                    .foregroundStyle(.secondary).frame(width: 12).accessibilityHidden(true)
            }
            .padding(.horizontal, 4)
            .frame(height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).modifier(SearchResultHover()).disabled(!canPlay)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(result.searchAccessibilityLabel)
        .accessibilityIdentifier("catalog-search-result-\(result.uri.rawValue)")
        .accessibilityAddTraits(model.selectedURI == result.uri ? .isSelected : [])
        .help(result.searchAccessibilityLabel)
        .task(id: ArtworkLoadRequest(url: result.artwork?.url, retryRevision: environment.artworkStore.retryRevision)) {
            if let url = result.artwork?.url { await environment.artworkStore.load(url) }
        }
    }

    private func errorState(_ failure: LibraryError, kind: CatalogSearchKind? = nil) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let delay = model.retryAfter.map { ceil($0.timeIntervalSince(context.date)) } ?? 0
            let remaining = max(0, Int(exactly: delay) ?? Int.max)
            if let kind {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(errorText(failure)).foregroundStyle(.secondary).lineLimit(2)
                        if remaining > 0 { Text("library.retryIn \(remaining)").foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 4)
                    retryButton(kind: kind, at: context.date, remaining: remaining)
                }
                .font(.caption)
            } else {
                VStack(spacing: 10) {
                    Text(errorText(failure)).foregroundStyle(.secondary)
                    if remaining > 0 { Text("library.retryIn \(remaining)").font(.caption).foregroundStyle(.secondary) }
                    if failure != .authorizationRequired { retryButton(kind: nil, at: context.date, remaining: remaining) }
                }
            }
        }
    }

    private func retryButton(kind: CatalogSearchKind?, at date: Date, remaining: Int) -> some View {
        Button("library.retry") {
            environment.showSearch()
            Task {
                if let kind { await model.retry(kind, at: date) }
                else { await model.retry(at: date) }
            }
        }
        .disabled(model.isLoading || remaining > 0)
        .accessibilityLabel(kind.map { Text("search.retry \($0.title)") } ?? Text("library.retry"))
        .accessibilityIdentifier("catalog-search-retry-\(kind?.rawValue ?? "all")")
    }

    private func errorText(_ error: LibraryError) -> LocalizedStringKey {
        switch error {
        case .authorizationRequired: "librarySetup.accessExpired"
        case .quotaExceeded: "library.quotaExceeded"
        case .rateLimited: "library.rateLimited"
        default: "search.unavailable"
        }
    }

    private func playSelection() {
        guard let result = model.results.first(where: { $0.uri == model.selectedURI }) else { return }
        play(result)
    }

    private func play(_ result: CatalogSearchResult) {
        guard canPlay else { return }
        environment.playSearchResult(result)
    }
}

extension CatalogSearchResult {
    var searchAccessibilityLabel: String {
        [kind.typeTitle, title, subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

private extension CatalogSearchKind {
    var title: String {
        switch self {
        case .song: String(localized: "search.group.songs")
        case .album: String(localized: "search.group.albums")
        case .artist: String(localized: "search.group.artists")
        case .playlist: String(localized: "search.group.playlists")
        }
    }
    var typeTitle: String {
        switch self {
        case .song: String(localized: "search.type.song")
        case .album: String(localized: "search.type.album")
        case .artist: String(localized: "search.type.artist")
        case .playlist: String(localized: "search.type.playlist")
        }
    }
    var symbol: String {
        switch self {
        case .song: "music.note"
        case .album: "opticaldisc"
        case .artist: "person"
        case .playlist: "music.note.list"
        }
    }
}

private struct SearchResultHover: ViewModifier {
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .listRowBackground(Color.primary.opacity(isEnabled && isHovered ? 0.1 : 0))
            .onHover { isHovered = $0 }
            .onDisappear { isHovered = false }
    }
}

#if DEBUG
#Preview("Search Spotify") { SearchView(environment: makePreviewEnvironment()) }
#endif
