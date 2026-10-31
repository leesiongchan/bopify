import Foundation
import Observation
import BopifyDomain
import os

@MainActor @Observable
final class VinylDesignPickerModel {
    enum Direction { case left, right, up, down }
    var focused: VinylDesign
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        focused = .resolve(defaults.string(forKey: VinylDesign.preferenceKey))
    }

    func move(_ direction: Direction) {
        let index = VinylDesign.allCases.firstIndex(of: focused) ?? 0
        let target: Int
        switch direction {
        case .left: target = max(0, index - 1)
        case .right: target = min(VinylDesign.allCases.count - 1, index + 1)
        case .up: target = index < 3 ? index : index - 3
        case .down: target = index + 3 < VinylDesign.allCases.count ? index + 3 : index
        }
        focused = VinylDesign.allCases[target]
    }

    func activate() { select(focused) }

    func select(_ design: VinylDesign) {
        focused = design
        guard defaults.string(forKey: VinylDesign.preferenceKey) != design.rawValue else { return }
        defaults.set(design.rawValue, forKey: VinylDesign.preferenceKey)
        BopifyLog.playback.debug("vinyl design selected design=\(design.rawValue, privacy: .public)")
    }
}
