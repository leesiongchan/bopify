/// A cover handoff retains its material until the settled record can adopt the latest choice.
struct RecordDesignSelection {
    private(set) var selected: RecordDesign
    private var handoff: RecordDesign?

    init(rawValue: String? = nil) { selected = .resolve(rawValue) }

    var appearance: RecordDesign { handoff ?? selected }

    mutating func select(rawValue: String?) { selected = .resolve(rawValue) }
    mutating func beginHandoff() { handoff = selected }
    mutating func finishHandoff() { handoff = nil }
}
