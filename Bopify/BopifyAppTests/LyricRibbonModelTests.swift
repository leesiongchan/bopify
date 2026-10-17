#if DEBUG
import Testing

@MainActor @Suite("Lyric ribbon reading")
struct LyricRibbonModelTests {
    private func model() throws -> LyricRibbonModel {
        let model = LyricRibbonModel(snapshot: lyricTestSnapshot())
        model.show()
        model.completeLoad(.timed(try lyricTestDocument()), token: model.beginLoad())
        return model
    }

    @Test func holdAndCatchUpHaveIndependentReadingTime() throws {
        let model = try model()
        model.holdText()
        let revision = model.scrollResetRevision
        model.update(lyricTestSnapshot(position: 87_000))
        #expect(model.isHeld)
        #expect(model.projection?.current?.startMs == 70_000)
        #expect(model.snapshot.positionMs == 87_000)
        #expect(model.scrollResetRevision == revision)
        model.backToLive()
        #expect(!model.isHeld)
        #expect(model.projection?.current?.startMs == 80_000)
        #expect(model.scrollResetRevision > revision)
    }

    @Test func correctionAndPausePreserveHold() throws {
        let model = try model()
        model.holdText()
        var input = lyricTestSnapshot(position: 15_000)
        input.isPlaying = false
        model.update(input)
        #expect(model.isHeld)
        #expect(model.projection?.current?.startMs == 70_000)
        #expect(!model.snapshot.isPlaying)
        input.isPlaying = true
        model.update(input)
        #expect(model.isHeld)
    }

    @Test func seekRevisionReleasesHold() throws {
        let model = try model()
        model.holdText()
        var input = lyricTestSnapshot(position: 22_000)
        input.seekRevision = 1
        model.update(input)
        #expect(!model.isHeld)
        #expect(model.projection?.current?.startMs == 20_000)
    }

    @Test func sameRecordingNewOccurrenceClearsHold() throws {
        let model = try model()
        model.holdText()
        var input = lyricTestSnapshot(position: 0)
        input.occurrenceID = "second"
        input.title = "Next occurrence"
        model.update(input)
        #expect(!model.isHeld)
        #expect(model.content == .loading)
        #expect(model.projection == nil)
        #expect(model.snapshot.title == "Next occurrence")
    }

    @Test func newSessionClearsHold() throws {
        let model = try model()
        model.holdText()
        var input = lyricTestSnapshot()
        input.sessionID = "replacement"
        model.update(input)
        #expect(!model.isHeld)
        #expect(model.content == .loading)
    }

    @Test func lateResultCannotReplaceNewOccurrence() throws {
        let model = try model()
        let old = model.beginLoad()
        var input = lyricTestSnapshot()
        input.occurrenceID = "replacement"
        model.update(input)
        let fresh = model.beginLoad()
        model.completeLoad(.plain("Fresh passage"), token: fresh)
        model.completeLoad(.timed(try lyricTestDocument()), token: old)
        #expect(model.content == .plain("Fresh passage"))
    }

    @Test func hideInvalidatesPendingLoad() throws {
        let model = try model()
        let pending = model.beginLoad()
        model.hide()
        model.completeLoad(.plain("Late passage"), token: pending)
        #expect(model.content == .loading)
        #expect(!model.isVisible)
        #expect(!model.isHeld)
    }

    @Test func heldPassageSurvivesPlaybackEnd() throws {
        let model = try model()
        model.holdText()
        var input = lyricTestSnapshot(position: 100_000)
        input.isPlaying = false
        model.update(input)
        #expect(model.projection?.current?.startMs == 70_000)
        model.backToLive()
        #expect(model.projection?.interval == .ended)
    }

    @Test func plainAndUnavailableContentDisableHold() throws {
        let model = try model()
        for content: LyricContent in [.plain("Words"), .loading, .instrumental, .noMatch, .failure] {
            model.completeLoad(content, token: model.beginLoad())
            model.holdText()
            #expect(!model.isHeld)
            #expect(model.projection == nil)
        }
    }

    @Test func reopenProjectsCurrentTime() throws {
        let model = try model()
        model.holdText()
        model.hide()
        model.update(lyricTestSnapshot(position: 87_000))
        model.show()
        #expect(!model.isHeld)
        #expect(model.projection?.current?.startMs == 80_000)
        #expect(model.isVisible)
    }
}

nonisolated func lyricTestSnapshot(position: Int64 = 72_000) -> LyricPlaybackSnapshot {
    LyricPlaybackSnapshot(sessionID: "session", occurrenceID: "first", recordingID: "original-sample",
        title: "Window Seat", artist: "Soft Weather", positionMs: position, durationMs: 100_000,
        isPlaying: true, seekRevision: 0)
}
#endif
