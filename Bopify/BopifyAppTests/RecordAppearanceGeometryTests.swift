import Testing
import Foundation
import CoreGraphics

struct RecordAppearanceGeometryTests {
    @Test(arguments: [CGFloat(758), CGFloat(898)])
    func halfVisibleHomesAndFullyVisibleExtraction(_ width: CGFloat) {
        let g = RecordAppearanceGeometry(sceneWidth: width)
        for family in RecordAppearanceFamily.allCases {
            for choice in RecordAppearanceChoice.choices(in: family) {
                #expect(g.home(for: choice).x == (family == .material ? 0 : width))
                let extracted = g.extracted(for: choice)
                #expect(extracted.x - g.recordDiameter / 2 >= 0)
                #expect(extracted.x + g.recordDiameter / 2 <= width)
            }
        }
    }
    @Test(arguments: [CGFloat(758), CGFloat(898)])
    func constantDiameterFixedLayersAndStraightTravel(_ width: CGFloat) {
        let g = RecordAppearanceGeometry(sceneWidth: width)
        let choice = RecordAppearanceChoice.pattern(.bloom)
        let initial = RecordAppearanceMotion.RecordFrame(choice: choice, from: .extracted, to: .platter)
        let end = RecordAppearanceMotion.RecordFrame(choice: choice, from: .extracted, to: .platter, progress: 1)
        let middle = RecordAppearanceMotion.RecordFrame(choice: choice, from: .extracted, to: .platter, progress: 0.5)
        let a = g.pose(for: initial, peek: false), b = g.pose(for: end, peek: false)
        let mid = g.pose(for: middle, peek: true)
        #expect(abs(mid.centre.x - (a.centre.x + b.centre.x) / 2) < 0.001)
        #expect(abs(mid.centre.y - (a.centre.y + b.centre.y) / 2) < 0.001)
        #expect([a.scale, b.scale, mid.scale] == [1, 1, 1])
        #expect(initial.zIndex == end.zIndex && initial.zIndex == middle.zIndex)
        let home = RecordAppearanceMotion.RecordFrame(choice: choice, from: .edge, to: .edge)
        #expect(abs(g.pose(for: home, peek: true).centre.x - g.pose(for: home, peek: false).centre.x) <= 8)
    }
    @Test(arguments: [CGSize(width: 758, height: 1000), CGSize(width: 898, height: 1000),
                      CGSize(width: 850, height: 410), CGSize(width: 760, height: 335)])
    func parkedFullSilhouetteClearsEveryCrossing(_ size: CGSize) {
        let g = RecordAppearanceGeometry(sceneWidth: size.width, maximumHeight: size.height)
        for family in RecordAppearanceFamily.allCases {
            let choice = RecordAppearanceChoice.choices(in: family)[0]
            for step in 0...100 {
                let t = Double(step) / 100
                let frame = RecordAppearanceMotion.RecordFrame(choice: choice, from: .extracted, to: .platter, progress: t)
                let centre = g.pose(for: frame, peek: false).centre
                for armFamily in RecordAppearanceFamily.allCases {
                    // Radius includes the gimbal, counterweight, cartridge and full stylus extent.
                    for part in g.parkedArmSilhouette(in: armFamily) {
                        #expect(hypot(part.centre.x - centre.x, part.centre.y - centre.y) - part.radius - g.recordDiameter / 2 >= 8)
                    }
                }
            }
        }
    }
}
