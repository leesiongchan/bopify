import Foundation
import CoreGraphics

struct RecordAppearanceGeometry {
    struct Pose {
        let centre: CGPoint
        let angle: Double
        let lift: Double
        let scale: CGFloat = 1
    }
    struct SilhouettePart {
        let centre: CGPoint
        let radius: CGFloat
    }
    let sceneWidth: CGFloat
    let deckFrame: CGRect
    let sceneHeight: CGFloat
    let recordDiameter: CGFloat
    var armLength: CGFloat { recordDiameter * 0.86 }

    init(sceneWidth: CGFloat) {
        self.sceneWidth = sceneWidth
        let width = min(604, sceneWidth * 0.68)
        let height = width * 1042 / 1509
        deckFrame = CGRect(x: (sceneWidth - width) / 2, y: 10, width: width, height: height)
        recordDiameter = width * 570 / 1509
        sceneHeight = ceil(max(height + 24, recordDiameter * 1.85 + 24))
    }
    func sourcePoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: deckFrame.minX + x * deckFrame.width / 1509,
                y: deckFrame.minY + y * deckFrame.width / 1509)
    }
    func platterCenter(in family: RecordAppearanceFamily) -> CGPoint {
        sourcePoint(family == .material ? 428 : 1082, 504)
    }
    func tonearmPivot(in family: RecordAppearanceFamily) -> CGPoint {
        let point = sourcePoint(family == .material ? 635 : 874, 165)
        return CGPoint(x: point.x, y: point.y - 18)
    }
    func home(for choice: RecordAppearanceChoice) -> CGPoint {
        let first = recordDiameter * 0.80 + 4
        let last = sceneHeight - recordDiameter / 2 - 14
        let count = RecordAppearanceChoice.choices(in: choice.family).count
        return CGPoint(x: choice.family == .material ? 0 : sceneWidth,
                       y: first + (last - first) * CGFloat(choice.index) / CGFloat(count - 1))
    }
    func extracted(for choice: RecordAppearanceChoice) -> CGPoint {
        let x = recordDiameter * 0.54 + 4
        return CGPoint(x: choice.family == .material ? x : sceneWidth - x, y: home(for: choice).y)
    }
    func pose(for frame: RecordAppearanceMotion.RecordFrame, peek: Bool) -> Pose {
        func point(_ placement: RecordAppearanceMotion.Placement) -> CGPoint {
            switch placement {
            case .edge: home(for: frame.choice)
            case .extracted: extracted(for: frame.choice)
            case .platter: platterCenter(in: frame.choice.family)
            }
        }
        let a = point(frame.from), b = point(frame.to)
        var centre = CGPoint(x: a.x + (b.x - a.x) * frame.progress, y: a.y + (b.y - a.y) * frame.progress)
        if peek && frame.from == .edge && frame.to == .edge {
            centre.x += frame.choice.family == .material ? 8 : -8
        }
        return Pose(centre: centre, angle: frame.motorAngle + frame.travelAngle, lift: frame.lift)
    }
    /// Conservative union of circles bounds the exact native arm, cartridge and counterweight.
    func parkedArmSilhouette(in family: RecordAppearanceFamily) -> [SilhouettePart] {
        let pivot = tonearmPivot(in: family)
        let direction: CGFloat = family == .material ? -1 : 1
        var parts = (0...40).map { index in
            SilhouettePart(centre: CGPoint(x: pivot.x + direction * armLength * CGFloat(index) / 40, y: pivot.y), radius: 3.5)
        }
        parts.append(SilhouettePart(centre: pivot, radius: 12))
        parts.append(SilhouettePart(centre: CGPoint(x: pivot.x - direction * 17, y: pivot.y), radius: 10))
        parts.append(SilhouettePart(centre: CGPoint(x: pivot.x + direction * armLength, y: pivot.y), radius: 11))
        return parts
    }
}
