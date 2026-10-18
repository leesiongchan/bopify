import AppKit

struct LyricRibbonLayout {
    static let horizontalInset: CGFloat = 20
    static let verticalInset: CGFloat = 16
    static let sectionSpacing: CGFloat = 12
    static let headerHeight: CGFloat = 28
    static let footerHeight: CGFloat = 30
    static let currentCueAttribute = NSAttributedString.Key("BopifyCurrentLyric")

    let panelSize: CGSize
    let textViewportHeight: CGFloat
    let textScale: CGFloat
    let attributionHeight: CGFloat

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

    static func measure(content: LyricContent, width: CGFloat, textScale: CGFloat, availableHeight: CGFloat,
                        source: LyricSourceMetadata? = nil) -> Self {
        let width = max(1, width)
        let scale = max(1, textScale)
        let chromeHeight = 2 * verticalInset + headerHeight + footerHeight + 2 * sectionSpacing
        let textWidth = max(1, width - 2 * horizontalInset)
        var height: CGFloat = 72
        switch content {
        case let .timed(document):
            for (index, group) in document.groups.enumerated() {
                let previous = index > 0 ? document.groups[index - 1].text : nil
                height = max(height, textHeight(passage(previous: previous, current: group.text, scale: scale,
                    isRightToLeft: source?.isRightToLeft ?? false), width: textWidth))
            }
        case let .plain(text):
            height = max(height, textHeight(passage(previous: nil, current: text, scale: scale,
                isRightToLeft: source?.isRightToLeft ?? false), width: textWidth))
        default: break
        }
        let attributionHeight: CGFloat
        if let attribution = source?.attribution {
            let font = NSFont.systemFont(ofSize: 11 * scale)
            let measured = textHeight(NSAttributedString(string: attribution, attributes: [.font: font]), width: textWidth)
            attributionHeight = min(measured, ceil(font.ascender - font.descender + font.leading) * 2,
                                    max(0, availableHeight - chromeHeight - sectionSpacing - 40))
        } else { attributionHeight = 0 }
        let reserve = attributionHeight > 0 ? attributionHeight + sectionSpacing : 0
        // A malformed or unusually long cue should scroll inside the companion, not fill the desktop.
        let viewport = min(height, 180 * scale, max(1, availableHeight - chromeHeight - reserve))
        return Self(panelSize: CGSize(width: width, height: viewport + chromeHeight + reserve), textViewportHeight: viewport,
                    textScale: scale, attributionHeight: attributionHeight)
    }
}
