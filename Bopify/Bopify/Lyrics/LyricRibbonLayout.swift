import AppKit

struct LyricRibbonLayout {
    static let horizontalInset: CGFloat = 22
    static let sleeveInset: CGFloat = 20
    static let verticalInset: CGFloat = 12
    static let sectionSpacing: CGFloat = 8
    static let headerHeight: CGFloat = 26
    static let footerHeight: CGFloat = 28
    static let currentCueAttribute = NSAttributedString.Key("BopifyCurrentLyric")

    let panelSize: CGSize
    let textViewportHeight: CGFloat
    let textScale: CGFloat

    static func passage(previous: String?, current: String, scale: CGFloat, isRightToLeft: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let previous, !previous.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 8
            paragraph.alignment = .natural
            paragraph.baseWritingDirection = isRightToLeft ? .rightToLeft : .natural
            result.append(NSAttributedString(string: previous + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 15 * scale), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]))
        }
        let currentParagraph = NSMutableParagraphStyle()
        currentParagraph.alignment = .natural
        currentParagraph.baseWritingDirection = isRightToLeft ? .rightToLeft : .natural
        result.append(NSAttributedString(string: current, attributes: [
            .font: NSFont.systemFont(ofSize: 25 * scale, weight: .medium), .foregroundColor: NSColor.labelColor,
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
        for (index, group) in document.groups.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 6 * scale
            paragraph.alignment = .natural
            paragraph.baseWritingDirection = isRightToLeft ? .rightToLeft : .natural
            let current = !isReading && group.startMs == projection?.current?.startMs
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: (current ? 25 : isReading ? 17 : 15) * scale,
                                         weight: current ? .medium : .regular),
                .foregroundColor: !isReading && !visible.contains(group.startMs) ? NSColor.clear
                    : current || isReading ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
            if group.startMs == anchor?.startMs { attributes[currentCueAttribute] = true }
            result.append(NSAttributedString(string: group.text + (index + 1 < document.groups.count ? "\n" : ""), attributes: attributes))
        }
        return result
    }

    static func measure(content: LyricContent, width: CGFloat, textScale: CGFloat, availableHeight: CGFloat,
                        source: LyricSourceMetadata? = nil) -> Self {
        let scale = max(1, textScale)
        let footer = footerHeight * scale
        let chromeHeight = 2 * verticalInset + headerHeight + footer + 2 * sectionSpacing
        // The document scrolls; its length never controls the companion's footprint.
        let viewport = min(132 * scale, max(1, availableHeight - chromeHeight))
        return Self(panelSize: CGSize(width: max(1, width), height: viewport + chromeHeight),
                    textViewportHeight: viewport, textScale: scale)
    }
}
