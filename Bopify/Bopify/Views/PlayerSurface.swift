import SwiftUI

struct PlayerSurface<Content: View>: View {
    var cornerRadius: CGFloat = 28
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                if reduceTransparency || contrast == .increased {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(shape.strokeBorder(.primary.opacity(0.4), lineWidth: 1))
                } else {
                    Color.clear.glassEffect(.regular, in: shape)
                }
            }
    }
}

private struct PlayerGlass: ViewModifier {
    /// Regular glass frosts more than clear glass, keeping text legible over artwork.
    var prominent = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.5), lineWidth: 1).allowsHitTesting(false))
        } else {
            content.glassEffect(prominent ? .regular : .clear, in: Capsule())
        }
    }
}

extension View {
    func playerGlass(prominent: Bool = false) -> some View { modifier(PlayerGlass(prominent: prominent)) }
}
