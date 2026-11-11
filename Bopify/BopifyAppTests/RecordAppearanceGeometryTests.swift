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
