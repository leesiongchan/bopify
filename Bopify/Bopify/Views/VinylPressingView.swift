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
    var design: VinylDesign = .original
    let diameter: CGFloat

    var body: some View {
        Group {
            switch palette {
            case let .some(.marble(c0, c1, c2)):
                Rectangle().fill(.white)
                    .colorEffect(pressingShader(c0, c1, c2))
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

    private func pressingShader(_ c0: ArtworkColor, _ c1: ArtworkColor, _ c2: ArtworkColor) -> Shader {
        let library = ShaderLibrary.bundle(Bundle(for: VinylShaderBundle.self))
        let size = Shader.Argument.float2(Float(diameter), Float(diameter))
        switch design {
        case .undertow, .drift, .strata:
            let style: Float = design == .undertow ? 0 : design == .drift ? 1 : 2
            return library.vinylContours(size, .float(seed), .color(c0.color), .color(c1.color), .color(c2.color), .float(style))
        case .original:
            return library.pressing(size, .float(seed), .color(c0.color), .color(c1.color), .color(c2.color))
        case .bloom, .rhapsody, .carnival:
            let colors = VinylDesignPalette.resolve(.marble(c0, c1, c2), design: design)!
            let arguments: [Shader.Argument] = [size, .float(seed), .color(colors.primary.color),
                .color(colors.secondary.color), .color(colors.accent.color), .color(colors.paper.color)]
            let function: ShaderFunction
            switch design {
            case .bloom: function = library.vinylBloom
            case .rhapsody: function = library.vinylRhapsody
            default: function = library.vinylCarnival
            }
            return Shader(function: function, arguments: arguments)
        }
    }
}

private final class VinylShaderBundle: NSObject {}

private extension ArtworkColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}
