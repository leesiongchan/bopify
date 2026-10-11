import SwiftUI
import BopifyPlayback

struct PressingAppearance: Hashable {
    let seed: Float
    let palette: ArtworkPalette
    static let neutral = Self(seed: 0, palette: .neutral)
}

struct VinylPressingView: View {
    let seed: Float
    let palette: ArtworkPalette
    let diameter: CGFloat

    var body: some View {
        Group {
            switch palette {
            case let .marble(c0, c1, c2):
                Rectangle().fill(.white)
                    .colorEffect(ShaderLibrary.pressing(.float2(Float(diameter), Float(diameter)), .float(seed),
                                                       .color(c0.color), .color(c1.color), .color(c2.color)))
            case let .tinted(tint):
                Circle().fill(Color(red: 0.035, green: 0.055, blue: 0.05))
                    .overlay(Circle().fill(AngularGradient(colors: [
                        .clear, tint.color.opacity(0.12), .clear, tint.color.opacity(0.07), .clear
                    ], center: .center)))
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }
}

private extension ArtworkColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}
