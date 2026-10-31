import Foundation
import Observation
import BopifyDomain
import os

@MainActor @Observable
final class RecordDesignPickerModel {
    enum Direction { case left, right, up, down }
    var focused: RecordDesign
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        focused = .resolve(defaults.string(forKey: RecordDesign.preferenceKey))
    }

    func move(_ direction: Direction) {
        let index = RecordDesign.allCases.firstIndex(of: focused) ?? 0
        switch direction {
        case .left: focused = RecordDesign.allCases[max(0, index - 1)]
        case .right: focused = RecordDesign.allCases[min(RecordDesign.allCases.count - 1, index + 1)]
        case .up, .down: break
        }
    }

    func activate() { select(focused) }

    func select(_ design: RecordDesign) {
        focused = design
        guard defaults.string(forKey: RecordDesign.preferenceKey) != design.rawValue else { return }
        defaults.set(design.rawValue, forKey: RecordDesign.preferenceKey)
        BopifyLog.playback.debug("record design selected design=\(design.rawValue, privacy: .public)")
    }
}
