import Foundation
import Observation
import BopifyDomain
import os

@MainActor @Observable
final class RecordAppearancePickerModel {
    enum NavigationDirection { case left, right, up, down, first, last }

    private(set) var selectedMaterial: RecordDesign
    private(set) var selectedPattern: VinylDesign
    var focused: RecordAppearanceFocus
    var isMotionPaused = false
    var isPreviewVisible = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let material = RecordDesign.resolve(defaults.string(forKey: RecordDesign.preferenceKey))
        selectedMaterial = material
        selectedPattern = .resolve(defaults.string(forKey: VinylDesign.preferenceKey))
        focused = .choice(.material(material))
    }

    func refreshPreferences() {
        selectedMaterial = .resolve(defaults.string(forKey: RecordDesign.preferenceKey))
        selectedPattern = .resolve(defaults.string(forKey: VinylDesign.preferenceKey))
    }

    func select(_ choice: RecordAppearanceChoice) {
        focused = .choice(choice)
        switch choice {
        case .material(let design):
            guard selectedMaterial != design else { return }
            selectedMaterial = design
            defaults.set(design.rawValue, forKey: RecordDesign.preferenceKey)
            BopifyLog.playback.debug("record design selected design=\(design.rawValue, privacy: .public)")
        case .pattern(let design):
            guard selectedPattern != design else { return }
            selectedPattern = design
            defaults.set(design.rawValue, forKey: VinylDesign.preferenceKey)
            BopifyLog.playback.debug("vinyl design selected design=\(design.rawValue, privacy: .public)")
        }
    }

    func activateFocused() {
        switch focused {
        case .choice(let choice): select(choice)
        case .motion: isMotionPaused.toggle()
        }
    }

    func moveTab(backward: Bool) {
        let order = RecordAppearanceFamily.allCases.flatMap { RecordAppearanceChoice.choices(in: $0) }
            .map(RecordAppearanceFocus.choice) + [.motion]
        let index = order.firstIndex(of: focused) ?? 0
        focused = order[(index + (backward ? order.count - 1 : 1)) % order.count]
    }

    func move(_ direction: NavigationDirection) {
        guard case .choice(let choice) = focused else { return }
        var family = choice.family
        var index = choice.index
        switch direction {
        case .left: index -= 1
        case .right: index += 1
        case .first: index = 0
        case .last: index = RecordAppearanceChoice.choices(in: family).count - 1
        case .up: family = .material
        case .down: family = .pattern
        }
        let choices = RecordAppearanceChoice.choices(in: family)
        focused = .choice(choices[min(max(0, index), choices.count - 1)])
    }
}
