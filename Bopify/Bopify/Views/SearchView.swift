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
            HStack(spacing: 10) {
                CatalogSearchField(text: Binding(get: { text }, set: {
                    text = $0
                    model.updateQuery($0)
                }), focusRevision: environment.searchWindow.focusRevision,
                onNavigate: model.moveSelection(by:), onPlay: playSelection,
                onDismiss: { environment.searchWindow.close() })
                .frame(height: 30)
                if model.isLoading { ProgressView().controlSize(.small).accessibilityLabel(Text("search.loading")) }
            }
            .padding(14)
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.tracks, id: \.uri) { song in row(song).id(song.uri) }
                        if model.error != nil { errorState.padding(12) }
                        else if model.hasMore {
                            Button("search.more") { Task { await model.loadMore() } }
                                .disabled(model.isLoading).padding(12)
                        } else if model.tracks.isEmpty {
                            Text(model.query.isEmpty ? "search.prompt" : model.isLoading ? "search.loading" : "search.empty")
                                .foregroundStyle(.secondary).padding(.vertical, 60)
                                .frame(maxWidth: .infinity)
                        }
                    }.padding(8)
                }
                .onChange(of: model.selectedURI) { _, uri in if let uri { scroll.scrollTo(uri) } }
            }
        }
        .frame(minWidth: 340, minHeight: 260)
        .task(id: model.query) { await model.search() }
        .onExitCommand { environment.searchWindow.close() }
    }

    private func row(_ song: Track) -> some View {
        Button {
            model.select(song.uri)
            environment.playSearchResult(song)
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let url = song.artwork?.url, let image = environment.artworkStore.image(for: url) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        ZStack { Color.primary.opacity(0.06); Image(systemName: "music.note").foregroundStyle(.secondary) }
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 5)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(song.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(playbackTime(song.durationMs)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(6).contentShape(Rectangle())
            .background(Color.accentColor.opacity(model.selectedURI == song.uri ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.songRow).disabled(!canPlay)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(model.selectedURI == song.uri ? .isSelected : [])
        .help([song.title, song.subtitle].joined(separator: " · "))
        .task(id: ArtworkLoadRequest(url: song.artwork?.url, retryRevision: environment.artworkStore.retryRevision)) {
            if let url = song.artwork?.url { await environment.artworkStore.load(url) }
        }
    }

    @ViewBuilder private var errorState: some View {
        if model.error == .authorizationRequired {
            VStack(spacing: 10) {
                Text("search.permission").foregroundStyle(.secondary)
                Button("search.enable") { Task { await environment.enableSearch() } }
                    .disabled(environment.isEnablingLibrary)
                if environment.isEnablingLibrary {
                    Button("library.cancelAuthorization", action: environment.cancelLibraryAuthorization)
                }
                if let notice = environment.libraryAuthorizationNotice { Text(notice).font(.caption) }
            }
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
        environment.playSearchResult(song)
    }
}

#if DEBUG
#Preview("Search Spotify") { SearchView(environment: makePreviewEnvironment()) }
#endif
