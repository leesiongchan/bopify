import Foundation

public struct ArtworkColor: Sendable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    private var linearRGB: (Double, Double, Double) {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return (linear(red), linear(green), linear(blue))
    }

    fileprivate var chroma: Double {
        let (r, g, b) = linearRGB
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return hypot(a, b)
    }
}

public enum ArtworkPalette: Sendable, Hashable {
    case marble(ArtworkColor, ArtworkColor, ArtworkColor)
    case tinted(ArtworkColor)
    public static let neutral = ArtworkPalette.tinted(ArtworkColor(red: 0.035, green: 0.055, blue: 0.05))
    private static let marbleChromaThreshold = 0.05

    public static func classify(_ samples: [(color: ArtworkColor, weight: Double)]) -> ArtworkPalette {
        let colours = samples.filter {
            $0.weight.isFinite && $0.weight > 0
                && $0.color.red.isFinite && $0.color.green.isFinite && $0.color.blue.isFinite
        }.sorted {
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            return ($0.color.red, $0.color.green, $0.color.blue) < ($1.color.red, $1.color.green, $1.color.blue)
        }.map(\.color)
        guard let dominant = colours.first else { return .neutral }
        guard colours.contains(where: { $0.chroma >= marbleChromaThreshold }) else { return .tinted(dominant) }
        return .marble(dominant, colours.count > 1 ? colours[1] : dominant, colours.count > 2 ? colours[2] : dominant)
    }
}
