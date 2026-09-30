import SwiftUI

struct PlayerControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlayerControlBody(configuration: configuration)
    }
}

extension ButtonStyle where Self == PlayerControlButtonStyle {
    static var playerControl: PlayerControlButtonStyle { PlayerControlButtonStyle() }
}

private struct PlayerControlBody: View {
    let configuration: ButtonStyleConfiguration
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
        configuration.label
            .contentShape(Capsule())
            .background(.primary.opacity(fill), in: Capsule())
            .scaleEffect(scale)
            // Snappy press, bouncy release so the click visibly lands.
            .animation(configuration.isPressed ? .easeOut(duration: 0.08) : .spring(duration: 0.35, bounce: 0.5), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .onHover { isHovered = $0 }
    }
}
