enum RecordAppearanceFamily: CaseIterable, Hashable {
    case material, pattern
}

enum RecordAppearanceChoice: Hashable {
    case material(RecordDesign)
    case pattern(VinylDesign)

    var family: RecordAppearanceFamily {
        switch self {
        case .material: .material
        case .pattern: .pattern
        }
    }

    static func choices(in family: RecordAppearanceFamily) -> [Self] {
        switch family {
        case .material: RecordDesign.allCases.map(Self.material)
        case .pattern: VinylDesign.allCases.map(Self.pattern)
        }
    }

    var index: Int { Self.choices(in: family).firstIndex(of: self)! }
    var nameKey: String {
        switch self {
        case .material(let design): design.nameKey
        case .pattern(let design): design.nameKey
        }
    }
    var accessibilityIdentifier: String { nameKey }
}

enum RecordAppearanceFocus: Hashable {
    case choice(RecordAppearanceChoice), motion
}
