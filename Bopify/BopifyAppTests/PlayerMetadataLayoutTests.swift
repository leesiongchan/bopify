import AppKit
import Testing
import SwiftUI
import BopifyDomain
import BopifyPlayback

@MainActor @Suite("Player metadata layout", .serialized)
struct PlayerMetadataLayoutTests {
    @Test func missingEmptyAndLongMetadataKeepTheSameRenderedHeight() async throws {
        let environment = makePreviewEnvironment(.paused)
        let player = try #require(environment.player)
        defer { player.stop() }
        func metadata(_ track: Track?) -> some View {
            PlayerTrackMetadata(track: track, player: player, artworkStore: environment.artworkStore,
                                presentation: environment.presentation)
                .environment(environment).frame(width: 232)
        }
        let host = NSHostingView(rootView: metadata(previewTracks[1]))
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 232, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        await settle(host)
        let loadedHeight = host.fittingSize.height
        #expect(loadedHeight > 30)

        let uri = SpotifyURI("spotify:track:metadata-layout")!
        let variants: [Track?] = [
            nil,
            Track(uri: uri, title: "", artists: [], albumTitle: nil, artwork: nil, durationMs: 180_000),
            Track(uri: uri, title: "Loaded song", artists: [ArtistSummary(name: "Singer")],
                  albumTitle: nil, artwork: nil, durationMs: 180_000),
            Track(uri: uri, title: String(repeating: "Long song title ", count: 10),
                  artists: (0..<5).map { ArtistSummary(name: "Singer with a very long name " + String($0)) },
                  albumTitle: nil, artwork: nil, durationMs: 180_000),
        ]
        for track in variants {
            host.rootView = metadata(track)
            await settle(host)
            #expect(abs(host.fittingSize.height - loadedHeight) < 0.5)
        }
    }

    private func settle(_ host: NSView) async {
        try? await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
    }
}
