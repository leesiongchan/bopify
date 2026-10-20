import SwiftUI
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

struct SearchView: View {
    let environment: AppEnvironment
    @State private var text = ""
    private var model: SearchModel { environment.search }
    private var canPlay: Bool { environment.authState == .signedIn && environment.player?.isEngineReady == true }

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
                if !model.tracks.isEmpty {
                    ScrollViewReader { scroll in
                        List(selection: Binding(get: { model.selectedURI }, set: { uri in
                            if let uri { model.select(uri) }
                        })) {
                            ForEach(model.tracks, id: \.uri) { song in
                                row(song).tag(song.uri).id(song.uri)
                                    .listRowInsets(EdgeInsets())
                                    .listRowSeparator(.hidden)
                            }
                        }
                        .listStyle(.plain)
                        .environment(\.defaultMinListRowHeight, 32)
                        .scrollContentBackground(.hidden)
                        .frame(height: CGFloat(min(5, model.tracks.count)) * 32)
                        .onAppear { if let uri = model.selectedURI { scroll.scrollTo(uri) } }
                        .onChange(of: model.selectedURI) { _, uri in if let uri { scroll.scrollTo(uri) } }
                    }
                }
                if model.error != nil { errorState.font(.caption).padding(6) }
                else if model.hasMore {
                    Button("search.more") { Task { await model.loadMore() } }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .disabled(model.isLoading).frame(height: 24)
                } else if model.tracks.isEmpty {
                    Text(model.isLoading ? "search.loading" : "search.empty")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(6)
                }
            }
        }
        .frame(width: 300)
        .task(id: model.query) {
            if model.tracks.isEmpty && model.error == nil { await model.search() }
        }
        .onExitCommand { environment.searchPopover.close() }
    }

    private func row(_ song: Track) -> some View {
        Button {
            model.select(song.uri)
            play(song)
        } label: {
            HStack(spacing: 6) {
                Group {
                    if let url = song.artwork?.url, let image = environment.artworkStore.image(for: url) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        ZStack { Color.primary.opacity(0.06); Image(.bopRecord).foregroundStyle(.secondary) }
                    }
                }
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4)).accessibilityHidden(true)
                HStack(spacing: 4) {
                    Text(song.title).fontWeight(.medium).lineLimit(1).layoutPriority(1)
                    Text("·").foregroundStyle(.secondary)
                    Text(song.subtitle).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 4)
            .frame(height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).modifier(SearchResultHover()).disabled(!canPlay)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(model.selectedURI == song.uri ? .isSelected : [])
        .help([song.title, song.subtitle].joined(separator: " · "))
        .task(id: ArtworkLoadRequest(url: song.artwork?.url, retryRevision: environment.artworkStore.retryRevision)) {
            if let url = song.artwork?.url { await environment.artworkStore.load(url) }
        }
    }

    @ViewBuilder private var errorState: some View {
        if model.error == .authorizationRequired {
            Text("librarySetup.accessExpired").foregroundStyle(.secondary)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 10) {
                    Text(errorText).foregroundStyle(.secondary)
                    let remaining = model.retryAfter.map { max(0, Int(ceil($0.timeIntervalSince(context.date)))) } ?? 0
                    if remaining > 0 { Text("library.retryIn \(remaining)").font(.caption).foregroundStyle(.secondary) }
                    Button("library.retry") { Task { await model.retry(at: Date()) } }
                        .disabled(model.isLoading || remaining > 0)
                }
            }
        }
    }

    private var errorText: LocalizedStringKey {
        switch model.error {
        case .quotaExceeded: "library.quotaExceeded"
        case .rateLimited: "library.rateLimited"
        default: "search.unavailable"
        }
    }
    private func playSelection() {
        guard let song = model.tracks.first(where: { $0.uri == model.selectedURI }) else { return }
        play(song)
    }

    private func play(_ song: Track) {
        guard canPlay else { return }
        environment.playSearchResult(song)
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
