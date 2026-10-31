enum VinylDesign: String, CaseIterable, Sendable {
    case original, undertow, strata, bloom, rhapsody, carnival

    static let preferenceKey = "player.vinylDesign"

    static func resolve(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .original
    }

    var nameKey: String { "vinyl.design.\(rawValue)" }
}
