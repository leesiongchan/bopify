import Foundation
import Testing

@MainActor @Suite("Unified appearance preferences")
struct RecordAppearancePickerModelTests {
    private func isolated() -> CountingAppearanceDefaults {
        CountingAppearanceDefaults(suiteName: "appearance.\(UUID())")!
    }

    @Test func openingAndFocusWriteNothing() {
        let defaults = isolated()
        let model = RecordAppearancePickerModel(defaults: defaults)
        model.move(.right)
        model.move(.down)
        #expect(defaults.writes.isEmpty)
        #expect(model.selectedMaterial == .classic)
        #expect(model.selectedPattern == .original)
    }

    @Test func activationSavesOnlyItsFamily() {
        let defaults = isolated()
        defaults.set("carnival", forKey: VinylDesign.preferenceKey)
        defaults.set("keep", forKey: "unrelated")
        defaults.writes.removeAll()
        let model = RecordAppearancePickerModel(defaults: defaults)
        model.move(.right)
        model.activateFocused()
        #expect(defaults.writes == [RecordDesign.preferenceKey])
        #expect(defaults.string(forKey: RecordDesign.preferenceKey) == "glass")
        #expect(defaults.string(forKey: VinylDesign.preferenceKey) == "carnival")
        #expect(defaults.string(forKey: "unrelated") == "keep")
    }

    @Test func invalidIDsUseExistingFallbacks() {
        let defaults = isolated()
        defaults.set("unknown", forKey: RecordDesign.preferenceKey)
        defaults.set("drift", forKey: VinylDesign.preferenceKey)
        defaults.writes.removeAll()
        let model = RecordAppearancePickerModel(defaults: defaults)
        #expect(model.selectedMaterial == .classic)
        #expect(model.selectedPattern == .original)
        model.select(.material(.classic))
        model.select(.pattern(.original))
        #expect(defaults.writes.isEmpty)
        #expect(defaults.string(forKey: VinylDesign.preferenceKey) == "drift")
    }

    @Test func sameChoiceDoesNotRewrite() {
        let defaults = isolated()
        let model = RecordAppearancePickerModel(defaults: defaults)
        model.select(.material(.glass))
        model.select(.pattern(.bloom))
        defaults.writes.removeAll()
        model.select(.material(.glass))
        model.select(.pattern(.bloom))
        #expect(defaults.writes.isEmpty)
    }

    @Test func focusTraversesGroupsAndClamps() {
        let model = RecordAppearancePickerModel(defaults: isolated())
        model.move(.last)
        #expect(model.focused == .choice(.material(.nacre)))
        model.move(.down)
        #expect(model.focused == .choice(.pattern(.strata)))
        model.move(.last)
        model.move(.right)
        #expect(model.focused == .choice(.pattern(.carnival)))
        model.move(.up)
        #expect(model.focused == .choice(.material(.nacre)))
        model.move(.first)
        model.move(.left)
        #expect(model.focused == .choice(.material(.classic)))
    }

    @Test func externalDefaultsRefreshDoesNotSave() {
        let defaults = isolated()
        let model = RecordAppearancePickerModel(defaults: defaults)
        defaults.set("glass", forKey: RecordDesign.preferenceKey)
        defaults.set("rhapsody", forKey: VinylDesign.preferenceKey)
        defaults.writes.removeAll()
        model.refreshPreferences()
        #expect(model.selectedMaterial == .glass)
        #expect(model.selectedPattern == .rhapsody)
        #expect(defaults.writes.isEmpty)
    }

    @Test func tabTraversalIncludesEveryChoiceAndMotion() {
        let model = RecordAppearancePickerModel(defaults: isolated())
        let expected = RecordAppearanceFamily.allCases.flatMap { RecordAppearanceChoice.choices(in: $0) }.map(RecordAppearanceFocus.choice) + [.motion]
        for value in expected.dropFirst() {
            model.moveTab(backward: false)
            #expect(model.focused == value)
        }
        model.moveTab(backward: false)
        #expect(model.focused == expected.first)
        model.moveTab(backward: true)
        #expect(model.focused == .motion)
    }

    @Test func motionFocusActivatesOnlyPreviewPause() {
        let defaults = isolated()
        let model = RecordAppearancePickerModel(defaults: defaults)
        model.focused = .motion
        model.move(.left)
        model.activateFocused()
        #expect(model.focused == .motion)
        #expect(model.isMotionPaused)
        #expect(defaults.writes.isEmpty)
    }
}

nonisolated private final class CountingAppearanceDefaults: UserDefaults, @unchecked Sendable {
    var writes: [String] = []
    override func set(_ value: Any?, forKey defaultName: String) {
        writes.append(defaultName)
        super.set(value, forKey: defaultName)
    }
}
