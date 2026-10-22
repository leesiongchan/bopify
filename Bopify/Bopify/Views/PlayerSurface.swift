import SwiftUI

struct PlayerSurface<Content: View>: View {
    var cornerRadius: CGFloat = 28
    var artwork: Image? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedArtwork: ArtworkLayer?
    @ViewBuilder let content: () -> Content

    private struct ArtworkLayer: Identifiable {
        let id = UUID()
        let image: Image
    }

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
                        .background {
                            GeometryReader { geometry in
                                ZStack {
                                    if let displayedArtwork {
                                        displayedArtwork.image.resizable().scaledToFill()
                                            .frame(width: geometry.size.width, height: geometry.size.height)
                                            .overlay((colorScheme == .dark ? Color.black : .white).opacity(0.25))
                                            .id(displayedArtwork.id)
                                            .transition(.opacity)
                                    }
                                }
                                .blur(radius: 40)
                                .opacity(0.45)
                                .animation(.easeInOut(duration: reduceMotion ? 0.16 : 0.7), value: displayedArtwork?.id)
                            }
                            .clipShape(shape)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                }
            }
            .onChange(of: artwork, initial: true) { _, image in
                displayedArtwork = image.map { ArtworkLayer(image: $0) }
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
