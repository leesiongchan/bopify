import SwiftUI

/// Artwork colors stay in the content layer beneath the glass controls.
struct PlayerSurface<Content: View>: View {
    let image: Image?
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static var width: CGFloat { 360 }
    static var height: CGFloat { 460 }

    var body: some View {
        content()
            .padding(24)
            .frame(width: Self.width, height: Self.height)
            .background {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    if !reduceTransparency && contrast != .increased {
                        if let image {
                            image.resizable().scaledToFill()
                                .frame(width: Self.width, height: Self.height)
                                .blur(radius: 48)
                                .opacity(colorScheme == .dark ? 0.45 : 0.2)
                        } else {
                            Ellipse()
                                .fill(Color.indigo.opacity(colorScheme == .dark ? 0.28 : 0.12))
                                .frame(width: 300, height: 260)
                                .blur(radius: 60)
                                .offset(x: -80, y: -100)
                        }
                        LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
                .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.primary.opacity(contrast == .increased ? 0.6 : 0.1), lineWidth: 1)
                    .allowsHitTesting(false)
            }
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
