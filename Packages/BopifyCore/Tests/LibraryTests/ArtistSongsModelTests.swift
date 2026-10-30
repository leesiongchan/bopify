import Foundation
import Testing
import BopifyDomain
@testable import BopifyLibrary

@Suite("Artist songs model", .timeLimit(.minutes(1))) @MainActor
struct ArtistSongsModelTests {
    private let source = SpotifyURI("spotify:track:source")!

    private func response(_ source: SpotifyURI) -> ArtistTopTracks {
        ArtistTopTracks(trackURI: source, tracks: [testTrack("song")])
    }

    @Test func dismissingDropsAnUncooperativeLateReply() async {
        let model = ArtistSongsModel()
        let (started, signal) = AsyncStream.makeStream(of: Void.self)
        var finish: CheckedContinuation<ArtistTopTracks, Never>?
        let loading = Task {
            await model.load(for: source) { _ in
                await withCheckedContinuation { finish = $0; signal.yield(()) }
            }
        }
        for await _ in started { break }
        #expect(model.isLoading)
        model.cancel()
        finish?.resume(returning: response(source))
        await loading.value
        #expect(model.result == nil)
        #expect(!model.isLoading)
        #expect(model.playRequest(for: testTrack("song")) == nil)
    }

    @Test func newerTrackWinsOverAnOlderReply() async {
        let model = ArtistSongsModel()
        let (started, signal) = AsyncStream.makeStream(of: Void.self)
        var finish: CheckedContinuation<ArtistTopTracks, Never>?
        let old = Task {
            await model.load(for: source) { _ in
                await withCheckedContinuation { finish = $0; signal.yield(()) }
            }
        }
        for await _ in started { break }
        let newer = testTrack("newer").uri
        await model.load(for: newer) { response($0) }
        finish?.resume(returning: response(source))
        await old.value
        #expect(model.result?.trackURI == newer)
    }

    @Test func switchingSingersOnTheSameTrackRejectsTheFirstSingersLateReply() async {
        let model = ArtistSongsModel()
        let (started, signal) = AsyncStream.makeStream(of: Void.self)
        var finish: CheckedContinuation<ArtistTopTracks, Never>?
        let first = Task {
            await model.load(for: source) { _ in
                await withCheckedContinuation { finish = $0; signal.yield(()) }
            }
        }
        for await _ in started { break }
        await model.load(for: source) {
            ArtistTopTracks(trackURI: $0, tracks: [testTrack("other")])
        }
        finish?.resume(returning: response(source))
        await first.value
        #expect(model.playRequest(for: testTrack("other")) == PlayRequest(contextURI: testTrack("other").uri))
        #expect(model.playRequest(for: testTrack("song")) == nil)
    }

    @Test func failedLoadCanRetryAndWrongSourceCannotBeShown() async {
        let model = ArtistSongsModel()
        await model.load(for: source) { _ in throw ArtistTopTracksFailure.network }
        #expect(model.error == .network)
        await model.load(for: source) { _ in response(testTrack("wrong").uri) }
        #expect(model.error == .unavailable)
        #expect(model.result == nil)
        await model.load(for: source) { response($0) }
        #expect(model.error == nil)
        #expect(model.result?.tracks.count == 1)
    }
}
