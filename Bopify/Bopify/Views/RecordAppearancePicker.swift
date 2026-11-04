import AppKit
import SwiftUI

struct RecordAppearancePicker: View {
    let model: RecordAppearancePickerModel
    var onClose: () -> Void = {}
    @FocusState private var focused: RecordAppearanceFocus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private let strings = RecordAppearanceResources.bundle

    init(model: RecordAppearancePickerModel, onClose: @escaping () -> Void = {}) {
        self.model = model
        self.onClose = onClose
        RecordAppearanceResources.prepare()
    }
    var body: some View {
        GeometryReader { size in
            let geometry = RecordAppearanceGeometry(sceneWidth: size.size.width)
            VStack(spacing: 0) {
                Text("appearance.title", bundle: strings).font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity).frame(height: 38)
                    .background(Color(red: 0.18, green: 0.22, blue: 0.18))
                Text("appearance.help", bundle: strings).font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                    .frame(height: 42)
                RecordAppearanceScene(model: model).frame(maxHeight: geometry.sceneHeight)
                Spacer(minLength: 4)
                HStack(alignment: .top, spacing: 20) {
                    options(.material).frame(width: (size.size.width - 60) * 0.38)
                    options(.pattern)
                }.fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 14)
                footer
            }
            .frame(width: size.size.width, height: size.size.height, alignment: .top)
            .background(alignment: .topLeading) { cloth(width: size.size.width, height: size.size.height) }
            .clipped()
        }
        .foregroundStyle(Color(red: 0.89, green: 0.91, blue: 0.85))
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .onExitCommand(perform: onClose)
        .defaultFocus($focused, model.focused)
        .onChange(of: model.focused, initial: true) { _, value in focused = value }
        .onChange(of: focused) { _, value in if let value { model.focused = value } }
    }
    private func cloth(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.16, green: 0.19, blue: 0.09)
            RecordAppearanceCloth().frame(width: width, height: max(0, height - 38)).offset(y: 38)
        }.frame(width: width, height: height, alignment: .topLeading).clipped().accessibilityHidden(true)
    }
    private func options(_ family: RecordAppearanceFamily) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(LocalizedStringKey(family == .material ? "appearance.material" : "appearance.pattern"), bundle: strings)
                .font(.system(size: 22, weight: .semibold)).tracking(-0.4)
                .accessibilityAddTraits(.isHeader)
            RecordAppearanceOptionLayout {
                ForEach(RecordAppearanceChoice.choices(in: family), id: \.self) { choice in
                    let selected = isSelected(choice)
                    Button { model.select(choice) } label: {
                        Text(LocalizedStringKey(choice.nameKey), bundle: strings)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(RecordAppearanceButtonStyle(selected: selected, focused: model.focused == .choice(choice), increasedContrast: contrast == .increased))
                    .focusable(interactions: .edit).focusEffectDisabled().focused($focused, equals: .choice(choice))
                    .accessibilityLabel(Text(LocalizedStringKey(choice.nameKey), bundle: strings))
                    .accessibilityValue(selected ? Text("vinyl.selected", bundle: strings) : Text("vinyl.notSelected", bundle: strings))
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                    .accessibilityIdentifier(choice.accessibilityIdentifier)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
    private func isSelected(_ choice: RecordAppearanceChoice) -> Bool {
        switch choice {
        case .material(let design): model.selectedMaterial == design
        case .pattern(let design): model.selectedPattern == design
        }
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(red: 0.79, green: 0.87, blue: 0.57)).frame(width: 4, height: 4).accessibilityHidden(true)
            Text(summary).font(.system(size: 11))
            Spacer()
            Button { model.isMotionPaused.toggle() } label: {
                Text(LocalizedStringKey(model.isMotionPaused ? "appearance.resume" : "appearance.pause"), bundle: strings)
            }
            .buttonStyle(RecordAppearanceButtonStyle(selected: false, focused: model.focused == .motion, increasedContrast: contrast == .increased))
            .focusable(interactions: .edit).focusEffectDisabled().focused($focused, equals: .motion)
            .disabled(reduceMotion)
            .accessibilityValue(Text(LocalizedStringKey(reduceMotion || model.isMotionPaused ? "appearance.motionStopped" : "appearance.motionPlaying"), bundle: strings))
            .accessibilityIdentifier("appearance.motion")
        }.padding(.horizontal, 20).frame(height: 44)
            .background(Color(red: 0.07, green: 0.12, blue: 0.08).opacity(0.72))
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5) }
    }
    private var summary: String {
        let material = strings.localizedString(forKey: model.selectedMaterial.nameKey, value: nil, table: nil)
        let pattern = strings.localizedString(forKey: model.selectedPattern.nameKey, value: nil, table: nil)
        return String(format: strings.localizedString(forKey: "appearance.summary", value: "%@ + %@", table: nil), material, pattern)
    }
}

private struct RecordAppearanceButtonStyle: ButtonStyle {
    let selected: Bool
    let focused: Bool
    let increasedContrast: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12))
            .padding(.horizontal, 10).frame(minHeight: 32)
            .foregroundStyle(selected ? Color(red: 0.10, green: 0.15, blue: 0.10) : Color(red: 0.90, green: 0.93, blue: 0.85))
            .background {
                RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: selected
                    ? [Color(red: 0.76, green: 0.80, blue: 0.68), Color(red: 0.59, green: 0.65, blue: 0.52)]
                    : [Color(red: 0.24, green: 0.29, blue: 0.17).opacity(0.94), Color(red: 0.13, green: 0.18, blue: 0.10).opacity(0.94)], startPoint: .top, endPoint: .bottom))
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Color.white.opacity(0.9) : Color.white.opacity(increasedContrast ? 0.65 : selected ? 0.55 : 0.23), lineWidth: focused ? 1.5 : 0.7))
            .opacity(configuration.isPressed ? 0.78 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct RecordAppearanceCloth: View {
    var image: CGImage? = RecordAppearanceResources.corduroyTile

    var body: some View {
        Canvas { context, size in
            guard let pixels = image else { return }
            // One source pixel per Retina pixel; mirrored edges meet without a colour jump.
            let tile = CGSize(width: CGFloat(pixels.width) / 2, height: CGFloat(pixels.height) / 2)
            let texture = context.resolve(Image(decorative: pixels, scale: 2).interpolation(.none))
            for row in 0..<Int(ceil(size.height / tile.height)) {
                for column in 0..<Int(ceil(size.width / tile.width)) {
                    let mirrorX = !column.isMultiple(of: 2)
                    let mirrorY = !row.isMultiple(of: 2)
                    var placement = context
                    placement.translateBy(x: CGFloat(column + (mirrorX ? 1 : 0)) * tile.width,
                                          y: CGFloat(row + (mirrorY ? 1 : 0)) * tile.height)
                    placement.scaleBy(x: mirrorX ? -1 : 1, y: mirrorY ? -1 : 1)
                    placement.draw(texture, in: CGRect(origin: .zero, size: tile))
                }
            }
        }
        .background(Color(red: 0.16, green: 0.19, blue: 0.09))
        .overlay(Color.black.opacity(0.14))
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
