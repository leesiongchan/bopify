import AppKit

struct LyricRibbonLayout {
    static let horizontalInset: CGFloat = 22
    static let sleeveInset: CGFloat = 48
    static let readerInset: CGFloat = 64
    static let surfaceInset: CGFloat = 6
    static let verticalInset: CGFloat = 8
    static let sectionSpacing: CGFloat = 8
    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 28
    static let cueTimeAttribute = NSAttributedString.Key("BopifyLyricTime")
    static let currentCueAttribute = NSAttributedString.Key("BopifyCurrentLyric")

    let panelSize: CGSize
    let textViewportHeight: CGFloat
    let textScale: CGFloat

    static func passage(previous: String?, current: String, scale: CGFloat, isRightToLeft: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let previous, !previous.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = rowHeight * scale
            paragraph.maximumLineHeight = rowHeight * scale
            paragraph.alignment = .natural
            paragraph.baseWritingDirection = isRightToLeft ? .rightToLeft : .natural
            result.append(NSAttributedString(string: previous + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 14 * scale), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]))
        }
        let currentParagraph = NSMutableParagraphStyle()
        currentParagraph.minimumLineHeight = rowHeight * scale
        currentParagraph.maximumLineHeight = rowHeight * scale
        currentParagraph.alignment = .natural
        currentParagraph.baseWritingDirection = isRightToLeft ? .rightToLeft : .natural
        result.append(NSAttributedString(string: current, attributes: [
            .font: NSFont.systemFont(ofSize: 19 * scale, weight: .medium), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: currentParagraph, currentCueAttribute: true,
        ]))
        return result
    }

    static func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    static func reader(content: LyricContent, projection: LyricProjection?, isReading: Bool,
                       scale: CGFloat, isRightToLeft: Bool = false) -> NSAttributedString {
        guard case let .timed(document) = content else {
            if case let .plain(text) = content { return passage(previous: nil, current: text, scale: scale, isRightToLeft: isRightToLeft) }
            return NSAttributedString()
        }
        let result = NSMutableAttributedString()
        let anchor = projection?.current ?? projection?.next ?? projection?.previous
        let visible = [projection?.previous?.startMs, projection?.current?.startMs, projection?.next?.startMs].compactMap { $0 }
        let metrics = NSLayoutManager()
        for (index, group) in document.groups.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = rowHeight * scale
            paragraph.maximumLineHeight = rowHeight * scale
            paragraph.alignment = .natural
            paragraph.baseWritingDirection = isRightToLeft ? .rightToLeft : .natural
            let current = group.startMs == projection?.current?.startMs
            let font = NSFont.systemFont(ofSize: (isReading ? 15 : current ? 19 : 14) * scale,
                                         weight: current && !isReading ? .medium : .regular)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                // Fixed TextKit rows otherwise align their unequal fonts near the bottom.
                .baselineOffset: metrics.defaultBaselineOffset(for: font) - metrics.defaultLineHeight(for: font)
                    + paragraph.minimumLineHeight / 2 - font.capHeight / 2,
                .foregroundColor: !isReading && !visible.contains(group.startMs) ? NSColor.clear
                    : current ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph, cueTimeAttribute: group.startMs,
            ]
            if !group.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { attributes[.link] = String(group.startMs) }
            if group.startMs == anchor?.startMs { attributes[currentCueAttribute] = true }
            result.append(NSAttributedString(string: group.text + (index + 1 < document.groups.count ? "\n" : ""), attributes: attributes))
        }
        return result
    }

    static func measure(content: LyricContent, width: CGFloat, textScale: CGFloat, availableHeight: CGFloat,
                        source: LyricSourceMetadata? = nil) -> Self {
        let scale = max(1, textScale)
        let chromeHeight = 2 * (verticalInset + surfaceInset) + headerHeight + sectionSpacing
        // The document scrolls; its length never controls the companion's footprint.
        let viewport = min(3 * rowHeight * scale, max(1, availableHeight - chromeHeight))
        return Self(panelSize: CGSize(width: max(1, width), height: viewport + chromeHeight),
                    textViewportHeight: viewport, textScale: scale)
    }
}
