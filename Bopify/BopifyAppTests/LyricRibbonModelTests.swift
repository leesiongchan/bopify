import Testing

@MainActor @Suite("Lyric ribbon reading")
struct LyricRibbonModelTests {
    private func model() throws -> LyricRibbonModel {
        let model = LyricRibbonModel(snapshot: lyricTestSnapshot())
        model.show()
        model.completeLoad(.timed(try lyricTestDocument()), token: model.beginLoad())
        return model
    }

    @Test func manualReadingKeepsLiveProjectionWithoutMovingViewport() throws {
        let model = try model()
        model.beginReading()
        let revision = model.scrollResetRevision
        model.update(lyricTestSnapshot(position: 87_000))
        #expect(model.isReading)
        #expect(model.projection?.current?.startMs == 80_000)
        #expect(model.snapshot.positionMs == 87_000)
        #expect(model.scrollResetRevision == revision)
        model.backToLive()
        #expect(!model.isReading)
        #expect(model.projection?.current?.startMs == 80_000)
        #expect(model.scrollResetRevision > revision)
    }

    @Test func correctionAndPausePreserveReadingViewport() throws {
        let model = try model()
        model.beginReading()
        let revision = model.scrollResetRevision
        var input = lyricTestSnapshot(position: 15_000)
        input.isPlaying = false
        model.update(input)
        #expect(model.isReading)
        #expect(model.projection?.current?.startMs == 10_000)
        #expect(model.scrollResetRevision == revision)
        #expect(!model.snapshot.isPlaying)
        input.isPlaying = true
        model.update(input)
        #expect(model.isReading)
    }

    @Test func seekWithinSameCueStillResetsManualViewport() throws {
        let model = try model()
        model.beginReading()
        let revision = model.scrollResetRevision
        var input = lyricTestSnapshot(position: 73_000)
        input.seekRevision = 1
        model.update(input)
        #expect(!model.isReading)
        #expect(model.projection?.current?.startMs == 70_000)
        #expect(model.scrollResetRevision > revision)
    }

    @Test func sameRecordingNewOccurrenceClearsReading() throws {
        let model = try model()
        model.beginReading()
        var input = lyricTestSnapshot(position: 0)
        input.occurrenceID = "second"
        input.title = "Next occurrence"
        model.update(input)
        #expect(!model.isReading)
        #expect(model.content == .loading)
        #expect(model.projection == nil)
        #expect(model.snapshot.title == "Next occurrence")
    }

    @Test func newSessionClearsReading() throws {
        let model = try model()
        model.beginReading()
        var input = lyricTestSnapshot()
        input.sessionID = "replacement"
        model.update(input)
        #expect(!model.isReading)
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
        #expect(!model.isReading)
    }

    @Test func manualReadingPreservesViewportAtPlaybackEnd() throws {
        let model = try model()
        model.beginReading()
        let revision = model.scrollResetRevision
        var input = lyricTestSnapshot(position: 100_000)
        input.isPlaying = false
        model.update(input)
        #expect(model.isReading)
        #expect(model.projection?.interval == .ended)
        #expect(model.scrollResetRevision == revision)
        model.backToLive()
        #expect(!model.isReading)
        #expect(model.scrollResetRevision > revision)
        #expect(model.projection?.interval == .ended)
    }

    @Test func plainAndUnavailableContentDisableReading() throws {
        let model = try model()
        for content: LyricContent in [.plain("Words"), .loading, .instrumental, .noMatch, .failure] {
            model.completeLoad(content, token: model.beginLoad())
            model.beginReading()
            #expect(!model.isReading)
            #expect(model.projection == nil)
        }
    }

    @Test func reopenProjectsCurrentTime() throws {
        let model = try model()
        model.beginReading()
        model.hide()
        model.update(lyricTestSnapshot(position: 87_000))
        model.show()
        #expect(!model.isReading)
        #expect(model.projection?.current?.startMs == 80_000)
        #expect(model.isVisible)
    }

    @Test func showingAnAlreadyVisibleReaderPreservesScroll() throws {
        let model = try model()
        model.beginReading()
        let revision = model.scrollResetRevision
        model.show()
        #expect(model.isReading)
        #expect(model.scrollResetRevision == revision)
    }

    @Test(arguments: [Int64(0), 40_000, 100_000])
    func timedDocumentCanBeReadOutsideCurrentCues(position: Int64) throws {
        let model = try model()
        model.update(lyricTestSnapshot(position: position))
        let revision = model.scrollResetRevision
        model.beginReading()
        model.beginReading()
        #expect(model.isReading)
        #expect(model.scrollResetRevision == revision)
    }

    @Test func hiddenDocumentCannotBeginReading() throws {
        let model = try model()
        model.hide()
        model.beginReading()
        #expect(!model.isReading)
    }

    @Test func loadAndIdleChangesResumeFollowing() throws {
        let model = try model()
        model.beginReading()
        let token = model.beginLoad()
        #expect(!model.isReading)
        #expect(model.projection == nil)
        model.completeLoad(.timed(try lyricTestDocument()), token: token)
        model.beginReading()
        model.setIdle(.otherDevice)
        #expect(!model.isReading)
        #expect(model.projection == nil)
    }

    @Test func followingMovesOnlyWhenCueChanges() throws {
        let model = try model()
        let revision = model.scrollResetRevision
        model.update(lyricTestSnapshot(position: 73_000))
        #expect(model.scrollResetRevision == revision)
        model.update(lyricTestSnapshot(position: 87_000))
        #expect(model.scrollResetRevision > revision)
        #expect(model.projection?.current?.startMs == 80_000)
    }
}

nonisolated func lyricTestSnapshot(position: Int64 = 72_000) -> LyricPlaybackSnapshot {
    LyricPlaybackSnapshot(sessionID: "session", occurrenceID: "first", recordingID: "original-sample",
        title: "Window Seat", artist: "Soft Weather", positionMs: position, durationMs: 100_000,
        isPlaying: true, seekRevision: 0)
}
