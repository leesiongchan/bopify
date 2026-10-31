import SwiftUI
import BopifyPlayback

struct PressingAppearance: Hashable {
    let seed: Float
    let palette: ArtworkPalette
    static let neutral = Self(seed: 0, palette: .neutral)
}

struct VinylPressingView: View {
    var seed: Float = 0
    var palette: ArtworkPalette? = nil
    let diameter: CGFloat

    var body: some View {
        Group {
            switch palette {
            case let .some(.marble(c0, c1, c2)):
                Rectangle().fill(.white)
                    .colorEffect(ShaderLibrary.bundle(Bundle(for: VinylShaderBundle.self))
                        .pressing(.float2(Float(diameter), Float(diameter)), .float(seed),
                                  .color(c0.color), .color(c1.color), .color(c2.color)))
            case let .some(.tinted(tint)):
                Circle().fill(Color(red: 0.035, green: 0.055, blue: 0.05))
                    .overlay(Circle().fill(AngularGradient(colors: [
                        .clear, tint.color.opacity(0.12), .clear, tint.color.opacity(0.07), .clear
                    ], center: .center)))
            case nil:
                Rectangle().fill(.black)
                    .colorEffect(ShaderLibrary.bundle(Bundle(for: VinylShaderBundle.self))
                        .vinylDisc(.float2(Float(diameter), Float(diameter))))
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }
}

private final class VinylShaderBundle: NSObject {}

private extension ArtworkColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}
