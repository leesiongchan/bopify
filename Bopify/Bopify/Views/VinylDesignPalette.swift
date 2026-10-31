import BopifyPlayback

struct VinylDesignPalette: Equatable, Sendable {
    let primary: ArtworkColor
    let secondary: ArtworkColor
    let accent: ArtworkColor
    let paper: ArtworkColor

    static func resolve(_ source: ArtworkPalette, design: VinylDesign) -> Self? {
        guard case let .marble(c0, c1, c2) = source else { return nil }
        switch design {
        case .original, .undertow, .drift, .strata:
            return Self(primary: c0, secondary: c1, accent: c2, paper: c2)
        case .bloom, .rhapsody, .carnival:
            return Self(primary: vivid(c0), secondary: vivid(c1), accent: vivid(c2), paper: c2)
        }
    }

    private static func vivid(_ color: ArtworkColor) -> ArtworkColor {
        let r = color.red, g = color.green, b = color.blue
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        // A neutral slot is useful as paper/ink; its undefined hue must not turn red.
        guard delta > 1e-6 else { return color }
        let lightness = (high + low) / 2
        let saturation = max(0.78, delta / (1 - abs(2 * lightness - 1)))
        var hue: Double
        if high == r { hue = (g - b) / delta + (g < b ? 6 : 0) }
        else if high == g { hue = (b - r) / delta + 2 }
        else { hue = (r - g) / delta + 4 }
        hue /= 6
        let l = min(0.62, max(0.45, lightness * 0.76))
        let a = saturation * min(l, 1 - l)
        func channel(_ n: Double) -> Double {
            let k = (n + hue * 12).truncatingRemainder(dividingBy: 12)
            return min(1, max(0, l - a * max(-1, min(k - 3, 9 - k, 1))))
        }
        return ArtworkColor(red: channel(0), green: channel(8), blue: channel(4))
    }
}
