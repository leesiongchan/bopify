import SwiftUI
import os
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

struct ArtistSongsButton: View {
    let track: Track
    let player: PlayerModel
    let artworkStore: ArtworkStore
    let presentation: PlayerPresentation
    @State private var selectedArtistIndex: Int?
    @State private var hoveredArtistIndex: Int?
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?
    private var canRequest: Bool { environment != nil && player.isEngineReady && track.uri.kind == .track }

    private func isPresented(for index: Int) -> Binding<Bool> {
        Binding(get: { selectedArtistIndex == index && presentation.activePopover == .artist }, set: { value in
            if value { selectedArtistIndex = index; presentation.presentPopover(.artist) }
            else if selectedArtistIndex == index { dismiss() }
        })
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(track.artists.enumerated()), id: \.offset) { index, artist in
                    if index > 0 { Text(", ").foregroundStyle(.tertiary) }
                    Button {
                        isPresented(for: index).wrappedValue.toggle()
                        BopifyLog.library.debug("artist popular songs toggled index=\(index, privacy: .public)")
                    } label: {
                        Text(artist.name).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(hoveredArtistIndex == index && canRequest ? .primary : .secondary)
                            .underline(hoveredArtistIndex == index && canRequest)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering && canRequest { hoveredArtistIndex = index }
                        else if hoveredArtistIndex == index { hoveredArtistIndex = nil }
                    }
                    .disabled(!canRequest)
                    .help(artist.name)
                    .accessibilityLabel(String(localized: "artist.popularSongs.accessibility", defaultValue: "Show popular songs by \(artist.name)"))
                    .popover(isPresented: isPresented(for: index), arrowEdge: .bottom) {
                        if let environment {
                            ArtistSongsPopover(track: track, player: player, artworkStore: artworkStore,
                                               presentation: presentation, request: { source in
                                try await environment.requestArtistTopTracks(for: source, artistIndex: index)
                            })
                            .id("\(track.uri.rawValue):\(index)")
                        }
                    }
                }
            }
        }
        .font(.system(size: 12))
        .scrollIndicators(.hidden)
        .frame(height: 18)
        .onChange(of: track.uri) { _, _ in dismiss() }
        .onChange(of: player.engineEpoch) { _, _ in dismiss() }
        .onDisappear { dismiss() }
    }

    private func dismiss() {
        selectedArtistIndex = nil
        if presentation.activePopover == .artist { presentation.dismissPopover() }
    }
}

private struct ArtistSongsPopover: View {
    let track: Track
    let player: PlayerModel
    let artworkStore: ArtworkStore
    let presentation: PlayerPresentation
    let request: @MainActor (SpotifyURI) async throws -> ArtistTopTracks
    @State private var model = ArtistSongsModel()
    @State private var retryRevision = 0

    private var sourceIsCurrent: Bool {
        let displayedURI = player.state.mirror?.trackURI ?? player.state.queue?.current?.uri ?? player.state.currentTrack?.uri
        return displayedURI == track.uri && presentation.activePopover == .artist
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let result = model.result {
                if result.tracks.isEmpty {
                    notice(String(localized: "artist.popularSongs.empty", defaultValue: "No popular songs available."))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(result.tracks.prefix(10)), id: \.uri) { song in row(song) }
                        }
                    }
                    .scrollIndicators(.visible)
                    .frame(height: min(CGFloat(result.tracks.count) * 45 - 1, 314))
                }
            } else if model.error != nil {
                VStack(spacing: 12) {
                    notice(String(localized: "artist.popularSongs.unavailable", defaultValue: "Couldn't load popular songs."))
                    Button(String(localized: "artist.popularSongs.retry", defaultValue: "Retry")) { retryRevision += 1 }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 100)
                    .accessibilityLabel(String(localized: "artist.popularSongs.loading", defaultValue: "Loading popular songs"))
            }
        }
        .padding(6).frame(width: 280)
        .onExitCommand { presentation.dismissPopover() }
        .task(id: retryRevision) {
            await model.load(for: track.uri, request: request)
        }
        .onDisappear { model.cancel() }
    }

    private func notice(_ message: String) -> some View {
        Text(message).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity).padding(.vertical, 20)
    }

    private func row(_ song: Track) -> some View {
        Button {
            guard sourceIsCurrent, player.isEngineReady, let selection = model.playRequest(for: song) else { return }
            player.load(selection)
            presentation.dismissPopover()
            BopifyLog.library.debug("artist popular song selected")
        } label: {
            HStack(spacing: 8) {
                Group {
                    if let url = song.artwork?.url, let image = artworkStore.image(for: url) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color(white: 0.12)
                            Image(systemName: "music.note").foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 5)).accessibilityHidden(true)
                Text(song.title).font(.system(size: 12)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(playbackTime(song.durationMs))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(6).contentShape(Rectangle())
        }
        .buttonStyle(.songRow)
        .disabled(!player.isEngineReady || !sourceIsCurrent)
        .accessibilityElement(children: .combine)
        .task(id: ArtworkLoadRequest(url: song.artwork?.url, retryRevision: artworkStore.retryRevision)) {
            if let url = song.artwork?.url { await artworkStore.load(url) }
        }
    }
}

#if DEBUG
func previewArtistSongs() -> some View {
    let environment = makePreviewEnvironment()
    let track = environment.player!.state.currentTrack!
    let presentation = PlayerPresentation()
    presentation.isVisible = true
    presentation.presentPopover(.artist)
    return ArtistSongsPopover(track: track, player: environment.player!, artworkStore: environment.artworkStore,
                              presentation: presentation) { source in
        ArtistTopTracks(trackURI: source, artistURI: SpotifyURI("spotify:artist:preview")!,
                        artistName: track.artists.first!.name, tracks: previewTracks)
    }
}

#Preview("Artist popular songs") { previewArtistSongs() }
#endif
