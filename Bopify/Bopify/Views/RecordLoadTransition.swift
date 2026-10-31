import SwiftUI
import BopifyDomain
import BopifyPlayback

struct CoverFlowLaunch: Identifiable {
    static let coordinateSpace = "bopify.recordLoad"
    static let duration = 1.8
    let id = UUID()
    let startedAt = SuspendingClock.now
    let itemURI: SpotifyURI
    let sourceFrame: CGRect
    let artwork: NSImage?

    func arrivalFrame(at destination: CGRect) -> CGRect {
        CGRect(x: destination.midX - sourceFrame.width / 2, y: destination.midY - sourceFrame.height / 2,
               width: sourceFrame.width, height: sourceFrame.height)
    }
}

struct RecordLoadTiming {
    let startedAt: SuspendingClock.Instant
    private(set) var readyAt: SuspendingClock.Instant?

    var finishedAt: SuspendingClock.Instant? {
        readyAt.map { max($0, startedAt.advanced(by: .seconds(CoverFlowLaunch.duration * 0.36)))
            .advanced(by: .seconds(CoverFlowLaunch.duration * 0.64)) }
    }

    mutating func confirm(at time: SuspendingClock.Instant) {
        if readyAt == nil { readyAt = time }
    }

    func progress(at time: SuspendingClock.Instant) -> Double {
        if let finishedAt, time >= finishedAt { return 1 }
        let elapsed = max(0, (startedAt.duration(to: time) / .seconds(1))) / CoverFlowLaunch.duration
        guard elapsed >= 0.36 else { return elapsed }
        guard let readyAt else { return 0.36 }
        let expansionStart = max(readyAt, startedAt.advanced(by: .seconds(CoverFlowLaunch.duration * 0.36)))
        return min(1, 0.36 + max(0, (expansionStart.duration(to: time) / .seconds(1))) / CoverFlowLaunch.duration)
    }
}

/// Shared staging keeps the flight and the real record's reveal synchronized.
struct RecordLoadStage {
    let progress: Double

    var travel: Double { eased(0, 0.36) }
    var expansion: Double { eased(0.4, 0.95) }
    var rounding: Double { eased(0.22, 0.36) }
    var coverOpacity: Double { 1 - eased(0.36, 0.44) }
    var incomingOpacity: Double { eased(0.36, 0.48) }

    private func eased(_ start: Double, _ end: Double) -> Double {
        let t = min(1, max(0, (progress - start) / (end - start)))
        return t * t * (3 - 2 * t)
    }
}

/// The incoming image deforms into the spindle while the outgoing record remains underneath.
struct RecordLoadTransition: View {
    let launch: CoverFlowLaunch
    let destination: CGRect
    let progress: Double
    var reduceMotion = false
    var rotationAngle = 0.0

    var body: some View {
        let stage = RecordLoadStage(progress: progress)
        if !reduceMotion, stage.coverOpacity > 0, let artwork = launch.artwork {
            Group {
                if stage.travel < 1 {
                    funnel(artwork: artwork, stage: stage)
                } else {
                    let frame = launch.arrivalFrame(at: destination)
                    Image(nsImage: artwork).resizable().scaledToFill()
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(Circle())
                        .rotationEffect(.radians(rotationAngle))
                        .position(x: frame.midX, y: frame.midY)
                }
            }
                .shadow(color: .black.opacity(0.35), radius: 8, y: 6)
                .opacity(stage.coverOpacity)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func funnel(artwork: NSImage, stage: RecordLoadStage) -> some View {
        GeometryReader { geometry in
            let source = launch.sourceFrame
            ZStack(alignment: .topLeading) {
                Color.clear
                Image(nsImage: artwork).resizable().scaledToFill()
                    .frame(width: source.width, height: source.height).clipped()
                    .offset(x: source.minX, y: source.minY)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .layerEffect(ShaderLibrary.bundle(Bundle(for: RecordLoadShaderBundle.self)).spindlePull(
                .float4(Float(source.minX), Float(source.minY), Float(source.width), Float(source.height)),
                .float2(Float(destination.midX), Float(destination.midY)),
                .float(Float(stage.travel)), .float(Float(stage.rounding)), .float(Float(rotationAngle))),
                maxSampleOffset: geometry.size)
        }
    }
}

private final class RecordLoadShaderBundle: NSObject {}
