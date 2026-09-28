import Foundation
import CoreGraphics

public struct MonolithLayout: Equatable, Sendable {
    public let contentSize: CGSize
    public let recordCenter: CGPoint
    public let recordDiameter: CGFloat
    public let sleeveFrame: CGRect
    public let controlsFrame: CGRect
    public let lowerFrame: CGRect
}

public func monolithLayout(mode: PlayerMode, availableSize: CGSize) -> MonolithLayout {
    let width = min(484, availableSize.width.isFinite ? max(1, availableSize.width) : 484)
    let height = availableSize.height.isFinite ? max(1, availableSize.height) : 360
    if mode == .compact {
        let size = CGSize(width: min(142, width), height: min(142, height))
        return MonolithLayout(contentSize: size, recordCenter: CGPoint(x: size.width / 2, y: size.height / 2),
                              recordDiameter: 118, sleeveFrame: .zero, controlsFrame: .zero, lowerFrame: .zero)
    }
    let narrow = width < 484
    let center = CGPoint(x: narrow ? 77 : 116, y: min(132, height / 2))
    let totalHeight = min(360, height)
    let controlsX: CGFloat = narrow ? min(150, width / 2) : 228
    let controls = CGRect(x: controlsX, y: 24, width: max(1, width - controlsX - 24), height: min(176, max(1, height - 124)))
    let sleeve = CGRect(x: center.x, y: 12, width: max(1, width - center.x - 12), height: max(1, totalHeight - 24))
    let lower = CGRect(x: center.x + 12, y: controls.maxY + 8, width: max(1, width - center.x - 36), height: max(0, totalHeight - controls.maxY - 20))
    return MonolithLayout(contentSize: CGSize(width: width, height: totalHeight), recordCenter: center,
                          recordDiameter: narrow ? 118 : 182, sleeveFrame: sleeve,
                          controlsFrame: controls, lowerFrame: lower)
}

public func monolithFrame(recordCenter: CGPoint, layout: MonolithLayout, visibleFrame: CGRect) -> CGRect {
    let x = recordCenter.x.isFinite ? recordCenter.x : visibleFrame.midX
    let y = recordCenter.y.isFinite ? recordCenter.y : visibleFrame.midY
    return clampedPlayerFrame(origin: CGPoint(x: x - layout.recordCenter.x,
                                              y: y + layout.recordCenter.y - layout.contentSize.height),
                              size: layout.contentSize, visibleFrame: visibleFrame)
}
