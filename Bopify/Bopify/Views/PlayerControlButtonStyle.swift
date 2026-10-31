import SwiftUI

struct PlaybackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlaybackButtonBody(configuration: configuration)
    }
}

private struct PlaybackButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pressed: Bool { isEnabled && configuration.isPressed }
    private var hovered: Bool { isEnabled && isHovered }

    var body: some View {
        configuration.label
            .contentShape(Circle())
            .background(.primary.opacity(pressed ? 0.22 : hovered ? 0.12 : 0), in: Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(pressed ? 0.22 : hovered ? 0.12 : 0), lineWidth: 0.75))
            .scaleEffect(reduceMotion ? 1 : pressed ? 0.96 : 1)
            .animation(reduceMotion ? nil : pressed ? .easeOut(duration: 0.06) : .spring(duration: 0.2, bounce: 0),
                       value: pressed)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .onHover { isHovered = $0 }
    }
}

struct SongRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SongRowButtonBody(configuration: configuration)
    }
}

extension ButtonStyle where Self == SongRowButtonStyle {
    static var songRow: SongRowButtonStyle { SongRowButtonStyle() }
}

private struct SongRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .background(.primary.opacity(!isEnabled ? 0 : configuration.isPressed ? 0.12 : isHovered ? 0.07 : 0),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) {
                if isEnabled && (isHovered || configuration.isPressed) {
                    Image(systemName: "play.fill").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
                        .padding(.leading, 6)
                        .accessibilityHidden(true).allowsHitTesting(false)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

struct PlayerControlButtonStyle: ButtonStyle {
    /// nil for plain actions; toggles tint their icon with the accent color while on.
    var isOn: Bool? = nil
    var dimsWhenOff = false
    func makeBody(configuration: Configuration) -> some View {
        PlayerControlBody(configuration: configuration, isOn: isOn, dimsWhenOff: dimsWhenOff)
    }
}

extension ButtonStyle where Self == PlayerControlButtonStyle {
    static var playerControl: PlayerControlButtonStyle { PlayerControlButtonStyle() }
    static func playerToggle(isOn: Bool, dimsWhenOff: Bool = false) -> PlayerControlButtonStyle {
        PlayerControlButtonStyle(isOn: isOn, dimsWhenOff: dimsWhenOff)
    }
}

private struct PlayerControlBody: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool?
    let dimsWhenOff: Bool
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Primary rather than white so the highlight reads on light glass too; disabled controls never invite a click.
    private var fill: Double { !isEnabled ? 0 : configuration.isPressed ? 0.2 : isHovered ? 0.12 : 0 }
    private var scale: Double {
        guard isEnabled, !reduceMotion else { return 1 }
        return configuration.isPressed ? 0.86 : isHovered ? 1.06 : 1
    }
    var body: some View {
        label
            .contentShape(Capsule())
            .background(.primary.opacity(fill), in: Capsule())
            .scaleEffect(scale)
            // Snappy press, bouncy release so the click visibly lands.
            .animation(configuration.isPressed ? .easeOut(duration: 0.08) : .spring(duration: 0.35, bounce: 0.5), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .animation(.easeOut(duration: 0.18), value: isOn)
            .onHover { isHovered = $0 }
    }
    @ViewBuilder private var label: some View {
        if let isOn {
            configuration.label.foregroundStyle(isOn ? AnyShapeStyle(.tint) : dimsWhenOff ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        } else {
            configuration.label
        }
    }
}
