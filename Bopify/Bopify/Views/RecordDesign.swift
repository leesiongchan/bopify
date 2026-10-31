import BopifyPlayback

enum RecordDesign: String, CaseIterable, Sendable {
    case classic, glass, nacre

    static let preferenceKey = "player.recordDesign"
    static let glassSmokeDensity: Float = 0.50

    static func resolve(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .classic
    }

    var nameKey: String { "record.design.\(rawValue)" }

    func resolved(for palette: ArtworkPalette?) -> Self {
        guard case .some(.tinted) = palette else { return .classic }
        return self
    }
}
