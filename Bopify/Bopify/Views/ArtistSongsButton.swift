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
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?

    private var isPresented: Binding<Bool> {
        Binding(get: { presentation.activePopover == .artist }, set: { value in
            if value { presentation.presentPopover(.artist) }
            else if presentation.activePopover == .artist { presentation.dismissPopover() }
        })
    }

    var body: some View {
        if let artist = track.artists.first {
            HStack(spacing: 0) {
                Button {
                    isPresented.wrappedValue.toggle()
                    BopifyLog.library.debug("artist popular songs toggled")
                } label: {
                    HStack(spacing: 3) {
                        Text(artist.name).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                }
                .buttonStyle(.plain)
                .disabled(environment == nil || !player.isEngineReady || track.uri.kind != .track)
                .help(String(localized: "artist.popularSongs.help", defaultValue: "Show popular songs"))
                .accessibilityLabel(String(localized: "artist.popularSongs.accessibility", defaultValue: "Show popular songs by \(artist.name)"))
                .popover(isPresented: isPresented, arrowEdge: .bottom) {
                    if let environment {
                        ArtistSongsPopover(track: track, player: player, artworkStore: artworkStore,
                                           presentation: presentation, request: environment.requestArtistTopTracks(for:))
                            .id(track.uri)
                    }
                }
                if track.artists.count > 1 {
                    Text(", " + track.artists.dropFirst().map(\.name).joined(separator: ", ")).lineLimit(1)
                }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .onChange(of: track.uri) { _, _ in dismiss() }
            .onChange(of: player.engineEpoch) { _, _ in dismiss() }
            .onDisappear { dismiss() }
        }
    }

    private func dismiss() {
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.result?.artistName ?? track.artists.first?.name ?? "")
                    .font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text(String(localized: "artist.popularSongs.title", defaultValue: "Popular songs"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let result = model.result {
                if result.tracks.isEmpty {
                    notice(String(localized: "artist.popularSongs.empty", defaultValue: "No popular songs available."))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(result.tracks.prefix(10)), id: \.uri) { song in row(song) }
                        }
                    }
                    .scrollIndicators(.visible)
                    .frame(height: min(CGFloat(result.tracks.count) * 64, 360))
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
        .padding(16).frame(width: 320)
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
            HStack(spacing: 12) {
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
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(song.title).font(.system(size: 13)).lineLimit(1)
                    Text(song.artists.map(\.name).joined(separator: ", "))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(playbackTime(song.durationMs))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
