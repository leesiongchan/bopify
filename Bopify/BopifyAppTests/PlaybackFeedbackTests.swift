import AppKit
import SwiftUI
import Testing
import BopifyDomain
import BopifyPlayback
import CoreGraphics

@MainActor @Suite("Turntable feedback", .serialized)
struct PlaybackFeedbackTests {
    @Test func aSlowLoadHoldsTheCoverAtTheSpindleUntilConfirmation() throws {
        let start = SuspendingClock.now
        var timing = RecordLoadTiming(startedAt: start)
        #expect(timing.progress(at: start.advanced(by: .seconds(2))) == 0.36)
        #expect(timing.finishedAt == nil)
        timing.confirm(at: start.advanced(by: .seconds(2)))
        #expect(timing.progress(at: start.advanced(by: .seconds(2))) == 0.36)
        #expect(RecordLoadStage(progress: timing.progress(at: start.advanced(by: .seconds(2)))).expansion == 0)
        #expect(RecordLoadStage(progress: timing.progress(at: start.advanced(by: .seconds(2.4)))).expansion > 0)
        let finished = try #require(timing.finishedAt)
        #expect(timing.progress(at: finished) == 1)
    }

    @Test func coverArrivesAtOriginalSizeBeforeVinylExpands() {
        let source = CGRect(x: 250, y: 250, width: 76, height: 76)
        let target = CGRect(x: 25, y: 25, width: 182, height: 182)
        for progress in [0.0, 0.1, 0.2, 0.35, 0.36] {
            let stage = RecordLoadStage(progress: progress)
            #expect(stage.expansion == 0)
        }
        let launch = CoverFlowLaunch(itemURI: SpotifyURI("spotify:track:arrival")!, sourceFrame: source, artwork: nil)
        let arrived = launch.arrivalFrame(at: target)
        #expect(arrived.size == source.size)
        #expect(abs(arrived.midX - target.midX) < 0.001)
        #expect(abs(arrived.midY - target.midY) < 0.001)
        #expect(RecordLoadStage(progress: 0.6).expansion > 0)
        #expect(RecordLoadStage(progress: 0.6).expansion < 1)
        #expect(RecordLoadStage(progress: 1).expansion == 1)
    }

    @Test func anAlreadySpinningRecordKeepsDrivingDuringSelectionLoading() {
        #expect(RecordMotorRequest.resolve(phase: .loading, ready: true, active: true,
            visible: true, pressed: false, loadingFromPlaying: true) == .drive)
        #expect(RecordMotorRequest.resolve(phase: .loading, ready: true, active: true,
            visible: true, pressed: false) == .snap)
    }

    @Test func coverFlightHasVisibleFramesAndDisappearsAtRest() async throws {
        let artwork = makePreviewArtworkStore().image(for: previewArtworkURL(0))
        let launch = CoverFlowLaunch(itemURI: SpotifyURI("spotify:track:preview0")!,
                                    sourceFrame: CGRect(x: 125, y: 125, width: 76, height: 76), artwork: artwork)
        let target = CGRect(x: 20, y: 20, width: 142, height: 142)
        for progress in [0.0, 0.18, 0.32] {
            let pixels = try await snapshot(RecordLoadTransition(launch: launch, destination: target, progress: progress))
            #expect(pixels > 50)
        }
        let finished = try await snapshot(RecordLoadTransition(launch: launch, destination: target, progress: 1))
        #expect(finished == 0)
    }

    private func snapshot<Content: View>(_ content: Content) async throws -> Int {
        let host = NSHostingView(rootView: content.frame(width: 240, height: 240).background(.black)
            .environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 240, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var visible = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   max(color.redComponent, color.greenComponent, color.blueComponent) > 0.1 { visible += 1 }
            }
        }
        return visible
    }
}
