import Foundation
import Observation

@MainActor @Observable
final class StartupWindowLayout {
    struct MeasurementKey: Hashable {
        let identity: String
        let width: CGFloat
        init(identity: String, width: CGFloat) {
            self.identity = identity
            self.width = (width * 2).rounded() / 2
        }
    }
    private(set) var recordScale: CGFloat = 0.88
    private var screenRecordScale: CGFloat = 0.88
    private var allocatedRecordScale: CGFloat = 0.88
    private var isCompactStep = false
    private var availableHeight: CGFloat?
    private var contentHeight: CGFloat = 160
    private var requestedContentHeight: CGFloat = 160
    private struct Target: Equatable {
        let contentHeight: CGFloat
        let recordScale: CGFloat
    }
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var contraction: Task<Void, Never>?
    @ObservationIgnored private var pendingTarget: Target?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var measurements: [MeasurementKey: CGFloat] = [:]
    @ObservationIgnored private var preparedIdentities: Set<String> = []
    @ObservationIgnored private var measuredIdentity: String?

    var isManaged: Bool { availableHeight != nil }
    var height: CGFloat {
        // Match AppKit's integral frame height so repeated measurements do not reapply it.
        let desired = ceil(82 + 324 * allocatedRecordScale + contentHeight)
        return min(desired, availableHeight ?? desired)
    }

    init(sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func remember(contentHeight: CGFloat, for key: MeasurementKey, prepared: Bool = false) {
        guard contentHeight.isFinite, contentHeight > 0, key.width.isFinite, key.width >= 100 else { return }
        guard measuredIdentity == nil || measuredIdentity == key.identity else { return }
        measurements[key] = contentHeight
        if prepared { preparedIdentities.insert(key.identity) }
    }

    func measuredHeight(for key: MeasurementKey) -> CGFloat? { measurements[key] }

    func hasPreparedMeasurement(for identity: String) -> Bool { preparedIdentities.contains(identity) }

    func activateContent(_ identity: String?) {
        guard measuredIdentity != identity else { return }
        measuredIdentity = identity
        measurements = [:]
        preparedIdentities = []
    }

    func prepare(contentHeight: CGFloat, step: StartupStep, immediately: Bool) {
        guard contentHeight.isFinite, contentHeight > 0 else { return }
        requestedContentHeight = contentHeight
        isCompactStep = step.isCompact
        updateGeometry(immediate: immediately)
    }

    func useStep(_ step: StartupStep) {
        guard step.isCompact != isCompactStep else { return }
        isCompactStep = step.isCompact
        updateGeometry()
    }

    func useScreen(height: CGFloat) {
        guard height.isFinite, height >= 1 else { return }
        let available = floor(height)
        guard availableHeight != available else { return }
        availableHeight = available
        // Reserve room for the largest form once per screen, never once per step.
        screenRecordScale = min(0.88, max(0.25, (available - 82 - 360) / 324))
        updateGeometry(immediate: true)
    }

    func measure(contentHeight next: CGFloat) {
        let hasUnappliedTarget = pendingTarget == nil
            && (abs(next - contentHeight) >= 0.5 || allocatedRecordScale != recordScale)
        guard next.isFinite, next > 0, abs(next - requestedContentHeight) >= 0.5 || hasUnappliedTarget else { return }
        requestedContentHeight = next
        updateGeometry()
    }

    private func updateGeometry(immediate: Bool = false) {
        let fittingScale = availableHeight.map { ($0 - 82 - requestedContentHeight) / 324 } ?? 0.55
        let scale = isCompactStep ? min(0.55, screenRecordScale, max(0.12, fittingScale)) : screenRecordScale
        let target = Target(contentHeight: requestedContentHeight, recordScale: scale)
        recordScale = scale
        guard immediate || target != pendingTarget else { return }
        cancelPendingResize()
        let currentHeight = 82 + 324 * allocatedRecordScale + contentHeight
        let targetHeight = 82 + 324 * target.recordScale + target.contentHeight
        if immediate || targetHeight >= currentHeight {
            contentHeight = target.contentHeight
            allocatedRecordScale = target.recordScale
            return
        }
        // Hold the outgoing total until its fade finishes; combining both layouts' largest parts overshoots.
        pendingTarget = target
        let mine = generation, sleep = self.sleep
        contraction = Task { [weak self] in
            do { try await sleep(.milliseconds(330)) }
            catch { return }
            guard let self, self.generation == mine, !Task.isCancelled else { return }
            self.contentHeight = target.contentHeight
            self.allocatedRecordScale = target.recordScale
            self.pendingTarget = nil
            self.contraction = nil
        }
    }

    func cancelPendingResize() {
        generation &+= 1
        contraction?.cancel()
        contraction = nil
        pendingTarget = nil
    }
}
