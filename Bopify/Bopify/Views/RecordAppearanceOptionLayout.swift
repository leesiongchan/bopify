import SwiftUI

struct RecordAppearanceOptionLayout: Layout {
    static func frames(sizes: [CGSize], width: CGFloat) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        return sizes.map { size in
            let fitted = CGSize(width: min(size.width, width), height: size.height)
            if x > 0 && x + fitted.width > width {
                x = 0; y += rowHeight + 8; rowHeight = 0
            }
            let rect = CGRect(origin: CGPoint(x: x, y: y), size: fitted)
            x += fitted.width + 8
            rowHeight = max(rowHeight, fitted.height)
            return rect
        }
    }
    private func frames(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        Self.frames(sizes: subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }, width: width)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500
        let rects = frames(subviews, width: width)
        return CGSize(width: width, height: rects.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(subviews, width: bounds.width)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
