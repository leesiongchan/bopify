#if DEBUG
import AppKit

struct LyricRibbonLayout {
    let panelSize: CGSize
    let textViewportHeight: CGFloat
    let textScale: CGFloat

    static func passage(previous: String?, current: String, scale: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let previous, !previous.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 6
            paragraph.alignment = .natural
            paragraph.baseWritingDirection = .natural
            result.append(NSAttributedString(string: previous + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 14 * scale), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]))
        }
        let currentParagraph = NSMutableParagraphStyle()
        currentParagraph.alignment = .natural
        currentParagraph.baseWritingDirection = .natural
        result.append(NSAttributedString(string: current, attributes: [
            .font: NSFont.systemFont(ofSize: 23 * scale, weight: .medium), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: currentParagraph,
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

    static func measure(content: LyricContent, width: CGFloat, textScale: CGFloat, availableHeight: CGFloat) -> Self {
        let width = max(1, width)
        let scale = max(1, textScale)
        var height: CGFloat = 59
        switch content {
        case let .timed(document):
            for (index, group) in document.groups.enumerated() {
                let previous = index > 0 ? document.groups[index - 1].text : nil
                height = max(height, textHeight(passage(previous: previous, current: group.text, scale: scale), width: width - 40))
            }
        case let .plain(text):
            height = max(height, textHeight(passage(previous: nil, current: text, scale: scale), width: width - 40))
        default: break
        }
        let viewport = min(height, max(1, availableHeight - 98))
        return Self(panelSize: CGSize(width: width, height: viewport + 98), textViewportHeight: viewport, textScale: scale)
    }
}
#endif
