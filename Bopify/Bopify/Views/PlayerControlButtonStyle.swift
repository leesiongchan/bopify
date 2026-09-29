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
    var body: some View {
        configuration.label
            .contentShape(Capsule())
            .background(.white.opacity(isHovered ? 0.08 : 0), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .onHover { isHovered = $0 }
    }
}
