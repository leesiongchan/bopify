import SwiftUI
import BopifyPlayback

struct RecordAppearanceScene: View {
    let model: RecordAppearancePickerModel
    @State private var motion: RecordAppearanceMotion
    @State private var hovered: RecordAppearanceChoice?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: RecordAppearancePickerModel) {
        self.model = model
        _motion = State(initialValue: RecordAppearanceMotion(material: model.selectedMaterial, pattern: model.selectedPattern, at: .now))
    }
    var body: some View {
        GeometryReader { size in
            let geometry = RecordAppearanceGeometry(sceneWidth: size.size.width)
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !motion.needsFrames)) { context in
                ZStack(alignment: .topLeading) {
                    RecordAppearanceDeck(geometry: geometry, snapshot: motion.snapshot)
                    ForEach(motion.snapshot.records, id: \.choice) { frame in record(frame, geometry: geometry) }
                    RecordAppearanceDeck(geometry: geometry, snapshot: motion.snapshot, hardwareOnly: true).zIndex(100)
                }
                .frame(width: geometry.sceneWidth, height: geometry.sceneHeight)
                .clipped()
                .onChange(of: context.date) { _, _ in motion.advance(to: .now) }
            }
            .onChange(of: size.size.width) { _, _ in
                motion.settle(material: model.selectedMaterial, pattern: model.selectedPattern, at: .now)
            }
        }
        .onAppear {
            motion.setReducedMotion(reduceMotion, at: .now)
            motion.setPaused(model.isMotionPaused, at: .now)
            motion.setVisible(model.isPreviewVisible, at: .now)
        }
        .onDisappear { motion.setVisible(false, at: .now) }
        .onChange(of: model.selectedMaterial) { _, value in motion.select(.material(value), at: .now) }
        .onChange(of: model.selectedPattern) { _, value in motion.select(.pattern(value), at: .now) }
        .onChange(of: model.isMotionPaused) { _, value in motion.setPaused(value, at: .now) }
        .onChange(of: model.isPreviewVisible) { _, value in
            if value { motion.settle(material: model.selectedMaterial, pattern: model.selectedPattern, at: .now) }
            motion.setVisible(value, at: .now)
        }
        .onChange(of: reduceMotion) { _, value in motion.setReducedMotion(value, at: .now) }
        .accessibilityHidden(true)
    }
    private func record(_ frame: RecordAppearanceMotion.RecordFrame, geometry: RecordAppearanceGeometry) -> some View {
        let peek = hovered == frame.choice || model.focused == .choice(frame.choice)
        let pose = geometry.pose(for: frame, peek: peek)
        return RecordAppearanceSample(choice: frame.choice, diameter: geometry.recordDiameter, angle: pose.angle)
            .compositingGroup()
            .shadow(color: .black.opacity(0.55), radius: 2 + pose.lift * 7, x: 1, y: 3 + pose.lift * 8)
            .position(pose.centre).zIndex(frame.zIndex)
            .contentShape(Circle())
            .onHover { hovered = $0 ? frame.choice : nil }
            .onTapGesture { model.select(frame.choice) }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: peek)
    }
}

struct RecordAppearanceSample: View {
    let choice: RecordAppearanceChoice
    let diameter: CGFloat
    var angle = 0.0
    private var material: RecordDesign {
        if case .material(let design) = choice { return design }
        return .classic
    }
    private var pattern: VinylDesign {
        if case .pattern(let design) = choice { return design }
        return .original
    }
    private var palette: ArtworkPalette {
        if choice.family == .material { return .tinted(ArtworkColor(red: 0.52, green: 0.57, blue: 0.49)) }
        return .marble(ArtworkColor(red: 0.9333, green: 0.5098, blue: 0.4510),
                       ArtworkColor(red: 0.7255, green: 0.8392, blue: 0.7608),
                       ArtworkColor(red: 0.9569, green: 0.8745, blue: 0.6078))
    }
    var body: some View {
        ZStack {
            ZStack {
                VinylPressingView(seed: 42, palette: palette, design: pattern, recordDesign: material, diameter: diameter)
                Circle().fill(choice.family == .material ? Color(red: 0.69, green: 0.72, blue: 0.64) : Color(red: 0.92, green: 0.80, blue: 0.57))
                    .frame(width: diameter * 0.43, height: diameter * 0.43)
                    .overlay {
                        Image(systemName: "mountain.2.fill").font(.system(size: diameter * 0.22))
                            .foregroundStyle(choice.family == .material ? Color(red: 0.33, green: 0.41, blue: 0.34) : Color(red: 0.65, green: 0.36, blue: 0.28))
                    }
                    .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 0.5))
                Circle().fill(.black.opacity(0.7)).frame(width: 3, height: 3)
            }.rotationEffect(.degrees(angle))
            RecordMaterialSheen(design: material, diameter: diameter, labelRatio: 0.43)
        }.frame(width: diameter, height: diameter).accessibilityHidden(true)
    }
}
