#if DEBUG
import AppKit
import Testing

@MainActor @Suite("Lyric ribbon preview", .serialized)
struct LyricRibbonPreviewTests {
    private let suite = "lyric-preview-tests-\(UUID().uuidString)"
    private var preferences: UserDefaults { UserDefaults(suiteName: suite)! }

    @Test func injectedClockTicksPauseFreezesAndHiddenTimeCatchesUp() async throws {
        let clock = LyricTestClock()
        let gate = LyricSleepGate()
        let session = LyricRibbonPreviewSession(now: { clock.value }, sleep: { _ in try await gate.wait() }, defaults: preferences)
        defer { session.shutdown(); preferences.removePersistentDomain(forName: suite) }
        session.show()
        try await lyricEventually { await gate.count > 0 }
        clock.value = 1
        await gate.release()
        try await lyricEventually { session.model.snapshot.positionMs == 73_000 }
        session.setPlaying(false)
        #expect(!session.isClockRunning)
        clock.value = 10
        session.show()
        #expect(session.model.snapshot.positionMs == 73_000)
        session.setPlaying(true)
        session.hide()
        clock.value = 15
        session.show()
        #expect(session.model.snapshot.positionMs == 78_000)
        session.shutdown()
        await gate.release()
    }

    @Test func cancellationRejectsLateTickAfterHiding() async throws {
        let clock = LyricTestClock()
        let gate = LyricSleepGate()
        let session = LyricRibbonPreviewSession(now: { clock.value }, sleep: { _ in try await gate.wait() }, defaults: preferences)
        defer { session.shutdown(); preferences.removePersistentDomain(forName: suite) }
        session.show()
        try await lyricEventually { await gate.count > 0 }
        session.hide()
        let hiddenPosition = session.model.snapshot.positionMs
        clock.value = 5
        await gate.release()
        for _ in 0..<20 { await Task.yield() }
        #expect(session.model.snapshot.positionMs == hiddenPosition)
        #expect(!session.isClockRunning)
    }

    @Test func correctionKeepsHoldAndSeekReleasesIt() {
        let session = LyricRibbonPreviewSession(defaults: preferences)
        defer { session.shutdown(); preferences.removePersistentDomain(forName: suite) }
        session.setPlaying(false)
        session.show()
        session.model.beginReading()
        session.advance(by: 5_000, explicitSeek: false)
        #expect(session.model.isReading)
        session.advance(by: 5_000, explicitSeek: true)
        #expect(!session.model.isReading)
        session.model.beginReading()
        session.advance(by: 100_000, explicitSeek: false)
        #expect(session.model.isReading)
        #expect(!session.model.snapshot.isPlaying)
        #expect(!session.isClockRunning)
        session.model.backToLive()
        #expect(session.model.projection?.interval == .ended)
    }

    @Test func fixturesAndRepeatedOccurrencesReplaceHeldContent() {
        let session = LyricRibbonPreviewSession(defaults: preferences)
        defer { session.shutdown(); preferences.removePersistentDomain(forName: suite) }
        session.setPlaying(false)
        session.show()
        let recording = session.model.snapshot.recordingID
        let firstOccurrence = session.model.snapshot.occurrenceID
        session.model.beginReading()
        session.selectFixture(.timed)
        #expect(!session.model.isReading)
        #expect(session.model.snapshot.recordingID == recording)
        #expect(session.model.snapshot.occurrenceID != firstOccurrence)
        session.selectFixture(.plain)
        if case .plain = session.model.content {} else { Issue.record("Expected plain fixture") }
        for (fixture, content) in [(LyricPreviewFixture.instrumental, LyricContent.instrumental),
            (.noMatch, .noMatch), (.failure, .failure), (.loading, .loading)] {
            session.selectFixture(fixture)
            #expect(session.model.content == content)
        }
        for fixture in [LyricPreviewFixture.long, .rtl] {
            session.selectFixture(fixture)
            if case .timed = session.model.content {} else { Issue.record("Expected timed fixture") }
        }
    }
}

@MainActor private final class LyricTestClock { var value: TimeInterval = 0 }

private actor LyricSleepGate {
    private var pending: [CheckedContinuation<Void, Error>] = []
    var count: Int { pending.count }
    func wait() async throws { try await withCheckedThrowingContinuation { pending.append($0) } }
    func release() {
        let continuations = pending
        pending.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

@MainActor private func lyricEventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(await condition())
}
#endif
