import SwiftUI

/// Artwork colors stay in the content layer beneath the glass controls.
struct PlayerSurface<Content: View>: View {
    var palette: ArtworkPalette = .neutral
    @ViewBuilder let content: () -> Content
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var canvas: Color { Color(red: 8.0 / 255, green: 9.0 / 255, blue: 13.0 / 255) }

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack {
                    Self.canvas
                    if !reduceTransparency && contrast != .increased {
                        GeometryReader { geometry in
                            ZStack {
                                RadialGradient(colors: [palette.primary.opacity(0.4), .clear], center: .topLeading,
                                               startRadius: 0, endRadius: geometry.size.width * 0.95)
                                RadialGradient(colors: [palette.secondary.opacity(0.22), .clear], center: .topTrailing,
                                               startRadius: 0, endRadius: geometry.size.width * 0.8)
                            }
                            .frame(height: geometry.size.height * 0.7)
                            .mask(LinearGradient(colors: [.white, .white, .clear], startPoint: .top, endPoint: .bottom))
                        }
                    }
                }
                .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(contrast == .increased ? 0.6 : 0.12), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: reduceMotion ? 0.16 : 0.72), value: palette)
            .environment(\.colorScheme, .dark)
    }
}

/// Glass is reserved for controls; the player itself is a content surface.
struct PlayerGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.5), lineWidth: 1).allowsHitTesting(false))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 1).allowsHitTesting(false))
        }
    }
}
