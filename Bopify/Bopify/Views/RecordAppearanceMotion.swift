import Foundation

/// Explicit time keeps both decks on one clock and makes every interruption deterministic.
struct RecordAppearanceMotion {
    typealias Instant = SuspendingClock.Instant
    enum Phase { case play, prepare, swap, settle, restore, lower, returning }
    enum Placement { case edge, extracted, platter }
    enum Timing {
        static let prepare = 0.46, swap = 0.86, settle = 0.08, restore = 0.28, lower = 0.16
        static let returning = 0.24, needleLift = 0.14, armPark = 0.26, deceleration = 0.38
    }
    struct DeckSnapshot {
        let phase: Phase
        let mounted: RecordAppearanceChoice?
        let desired: RecordAppearanceChoice
        let labelChoice: RecordAppearanceChoice
        let armAngle: Double
        let needleLift: Double
        let speed: Double
    }
    struct RecordFrame {
        let choice: RecordAppearanceChoice
        var from: Placement
        var to: Placement
        var progress: Double = 0
        var travelAngle: Double = 0
        var motorAngle: Double = 0
        var lift: Double = 0
        var zIndex: Double { Double((choice.family == .material ? 20 : 24) + choice.index) }
    }
    struct Snapshot {
        let material: DeckSnapshot
        let pattern: DeckSnapshot
        let records: [RecordFrame]
        func deck(in family: RecordAppearanceFamily) -> DeckSnapshot { family == .material ? material : pattern }
    }
    private struct Deck {
        var mounted: RecordAppearanceChoice
        var desired: RecordAppearanceChoice
        var incoming: RecordAppearanceChoice?
        var phase: Phase = .play
        var began = 0.0
        var prepareArm: Double?
        var prepareNeedle = 0.0
        var prepareSpeed = 45.0
        var returnProgress = 0.0
        var returnArm = 0.0
        var returnNeedle = 0.0
        var returnSpeed = 0.0
        var angles: [RecordAppearanceChoice: Double] = [:]
    }
    private let epoch: Instant
    private var time = 0.0
    private var material: Deck
    private var pattern: Deck
    private var visible = false
    private var reduced = false
    private var paused = false

    init(material: RecordDesign, pattern: VinylDesign, at: Instant) {
        epoch = at
        self.material = Deck(mounted: .material(material), desired: .material(material))
        self.pattern = Deck(mounted: .pattern(pattern), desired: .pattern(pattern))
    }
    var needsFrames: Bool {
        visible && !reduced && (!paused || material.phase != .play || pattern.phase != .play)
    }
    var snapshot: Snapshot {
        Snapshot(material: deckSnapshot(material), pattern: deckSnapshot(pattern),
                 records: frames(material) + frames(pattern))
    }
    mutating func select(_ choice: RecordAppearanceChoice, at: Instant) {
        advance(to: at)
        if choice.family == .material { request(choice, deck: &material) }
        else { request(choice, deck: &pattern) }
    }
    private func request(_ choice: RecordAppearanceChoice, deck: inout Deck) {
        guard deck.desired != choice else { return }
        deck.desired = choice
        guard visible && !reduced else { settleDeck(&deck, choice: choice); return }
        if deck.phase == .play { begin(&deck) }
        else if deck.phase == .prepare, deck.incoming != choice {
            let state = deckSnapshot(deck)
            deck.returnProgress = ease((time - deck.began) / Timing.prepare)
            deck.returnArm = state.armAngle
            deck.returnNeedle = state.needleLift
            deck.returnSpeed = state.speed
            deck.phase = .returning
            deck.began = time
        }
    }
    mutating func advance(to instant: Instant) {
        let parts = epoch.duration(to: instant).components
        let target = max(time, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        advanceDeck(&material, to: target)
        advanceDeck(&pattern, to: target)
        time = target
    }
    mutating func setPaused(_ paused: Bool, at: Instant) {
        advance(to: at)
        self.paused = paused
    }
    mutating func setReducedMotion(_ reduced: Bool, at: Instant) {
        advance(to: at)
        self.reduced = reduced
        if reduced { settleLatest() }
    }
    mutating func setVisible(_ visible: Bool, at: Instant) {
        advance(to: at)
        self.visible = visible
        if !visible { settleLatest() }
    }
    mutating func settle(material: RecordDesign, pattern: VinylDesign, at: Instant) {
        advance(to: at)
        settleDeck(&self.material, choice: .material(material))
        settleDeck(&self.pattern, choice: .pattern(pattern))
    }
    private mutating func settleLatest() {
        settleDeck(&material, choice: material.desired)
        settleDeck(&pattern, choice: pattern.desired)
    }
    private func settleDeck(_ deck: inout Deck, choice: RecordAppearanceChoice) {
        deck.mounted = choice
        deck.desired = choice
        deck.incoming = nil
        deck.phase = .play
        deck.began = time
    }
    private func begin(_ deck: inout Deck) {
        guard deck.desired != deck.mounted else { return }
        deck.incoming = deck.desired
        deck.phase = .prepare
        deck.began = time
        deck.prepareArm = nil
        deck.prepareNeedle = 0
        deck.prepareSpeed = paused ? 0 : 45
    }
    private func duration(_ phase: Phase) -> Double {
        switch phase {
        case .play: .infinity
        case .prepare: Timing.prepare
        case .swap: Timing.swap
        case .settle: Timing.settle
        case .restore: Timing.restore
        case .lower: Timing.lower
        case .returning: Timing.returning
        }
    }
    private func advanceDeck(_ deck: inout Deck, to target: Double) {
        var cursor = time
        while cursor < target {
            let end = min(target, deck.began + duration(deck.phase))
            if visible && !reduced && !paused {
                // The smootherstep antiderivative integrates deceleration without frame-rate drift.
                if deck.phase == .play {
                    deck.angles[deck.mounted, default: 0] += 45 * (end - cursor)
                } else if deck.phase == .prepare {
                    func integral(_ elapsed: Double) -> Double {
                        let u = min(max(elapsed / Timing.deceleration, 0), 1)
                        return Timing.deceleration * (u - pow(u, 6) + 3 * pow(u, 5) - 2.5 * pow(u, 4))
                    }
                    deck.angles[deck.mounted, default: 0] += deck.prepareSpeed * (integral(end - deck.began) - integral(cursor - deck.began))
                } else if deck.phase == .returning {
                    func integral(_ elapsed: Double) -> Double {
                        let u = min(max(elapsed / Timing.returning, 0), 1)
                        return Timing.returning * (u - pow(u, 6) + 3 * pow(u, 5) - 2.5 * pow(u, 4))
                    }
                    deck.angles[deck.mounted, default: 0] += deck.returnSpeed * (integral(end - deck.began) - integral(cursor - deck.began))
                }
            }
            cursor = end
            guard end + 1e-9 >= deck.began + duration(deck.phase) else { break }
            deck.began = end
            switch deck.phase {
            case .play: break
            case .prepare: deck.phase = .swap
            case .swap:
                deck.angles[deck.mounted, default: 0] -= 180
                if let incoming = deck.incoming {
                    deck.angles[incoming, default: 0] += 180
                    deck.mounted = incoming
                }
                deck.incoming = nil
                deck.phase = .settle
            case .settle: deck.phase = .restore
            case .restore: deck.phase = .lower
            case .lower:
                deck.phase = .play
                if deck.desired != deck.mounted {
                    deck.incoming = deck.desired
                    deck.phase = .prepare
                    deck.prepareArm = nil
                    deck.prepareNeedle = 0
                    deck.prepareSpeed = paused ? 0 : 45
                }
            case .returning:
                deck.incoming = nil
                if deck.desired != deck.mounted {
                    deck.incoming = deck.desired
                    deck.phase = .prepare
                    deck.prepareArm = parkAngle(deck)
                    deck.prepareNeedle = 1
                    deck.prepareSpeed = 0
                } else { deck.phase = .restore }
            }
        }
    }
    private func ease(_ value: Double) -> Double {
        let x = min(max(value, 0), 1)
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
    private func playAngle(_ deck: Deck) -> Double { deck.mounted.family == .material ? 3 : -3 }
    private func parkAngle(_ deck: Deck) -> Double { deck.mounted.family == .material ? 90 : -90 }
    private func deckSnapshot(_ deck: Deck) -> DeckSnapshot {
        let elapsed = max(0, time - deck.began)
        let progress = ease(elapsed / duration(deck.phase))
        let play = playAngle(deck), park = parkAngle(deck)
        let arm: Double
        let lift: Double
        switch deck.phase {
        case .play: arm = play; lift = 0
        case .prepare:
            let origin = deck.prepareArm ?? play
            arm = origin + (park - origin) * ease((elapsed - Timing.needleLift) / Timing.armPark)
            lift = deck.prepareNeedle + (1 - deck.prepareNeedle) * ease(elapsed / Timing.needleLift)
        case .swap, .settle: arm = park; lift = 1
        case .restore: arm = park + (play - park) * progress; lift = 1
        case .lower: arm = play; lift = 1 - progress
        case .returning:
            arm = deck.returnArm + (park - deck.returnArm) * progress
            lift = deck.returnNeedle + (1 - deck.returnNeedle) * ease(elapsed / Timing.needleLift)
        }
        var speed = 0.0
        if visible && !reduced && !paused {
            if deck.phase == .play { speed = 45 }
            if deck.phase == .prepare { speed = deck.prepareSpeed * (1 - ease(elapsed / Timing.deceleration)) }
            if deck.phase == .returning { speed = deck.returnSpeed * (1 - progress) }
        }
        return DeckSnapshot(phase: deck.phase, mounted: deck.phase == .swap ? nil : deck.mounted,
                            desired: deck.desired, labelChoice: deck.mounted, armAngle: arm, needleLift: lift, speed: speed)
    }
    private func frames(_ deck: Deck) -> [RecordFrame] {
        let progress = ease((time - deck.began) / duration(deck.phase))
        return RecordAppearanceChoice.choices(in: deck.mounted.family).map { choice in
            let mounted = choice == deck.mounted
            var frame = RecordFrame(choice: choice, from: mounted ? .platter : .edge,
                                    to: mounted ? .platter : .edge, motorAngle: deck.angles[choice, default: 0])
            if deck.phase == .swap {
                if mounted {
                    frame.from = .platter; frame.to = .edge; frame.progress = progress
                    frame.travelAngle = -180 * progress
                    frame.lift = sin(.pi * progress) * 0.7
                } else if choice == deck.incoming {
                    frame.from = .extracted; frame.to = .platter; frame.progress = progress
                    frame.travelAngle = 55 + 125 * progress
                    frame.lift = 0.45 + sin(.pi * progress) * 0.3 - 0.45 * progress
                }
            } else if choice == deck.incoming {
                frame.from = .edge; frame.to = .extracted
                frame.progress = deck.phase == .returning ? deck.returnProgress * (1 - progress) : progress
                frame.travelAngle = 55 * frame.progress
                frame.lift = 0.45 * frame.progress
            }
            return frame
        }
    }
}
