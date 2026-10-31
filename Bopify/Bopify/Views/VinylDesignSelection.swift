/// A handoff owns its appearance until it ends; preference changes apply to the settled record.
struct VinylDesignSelection {
    private(set) var selected: VinylDesign
    private var handoff: VinylDesign?

    init(rawValue: String? = nil) { selected = .resolve(rawValue) }

    var appearance: VinylDesign { handoff ?? selected }

    mutating func select(rawValue: String?) { selected = .resolve(rawValue) }
    mutating func beginHandoff() { handoff = selected }
    mutating func finishHandoff() { handoff = nil }
}
