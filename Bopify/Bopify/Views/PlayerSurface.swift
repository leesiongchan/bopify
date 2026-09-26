import SwiftUI
import BopifyPlayback

struct PlayerSurface<Content: View>: View {
    var mode: PlayerMode = .expanded
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if mode != .compact {
                    let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
                    if reduceTransparency || contrast == .increased {
                        shape.fill(Color(nsColor: .windowBackgroundColor))
                            .overlay(shape.strokeBorder(.primary.opacity(0.4), lineWidth: 1))
                    } else if #available(macOS 26.0, *) {
                        Color.clear.glassEffect(.regular, in: shape)
                    } else {
                        shape.fill(.ultraThinMaterial)
                            .overlay(shape.strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                    }
                }
            }
    }
}

struct PlayerGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.5), lineWidth: 1).allowsHitTesting(false))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.clear, in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 1).allowsHitTesting(false))
        }
    }
}
