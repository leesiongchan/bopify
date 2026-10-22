import AppKit
import SwiftUI

struct CatalogSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRevision: Int
    let onNavigate: (Int) -> Void
    let onPlay: () -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = FocusedSearchField()
        field.identifier = NSUserInterfaceItemIdentifier("catalog-search-input")
        field.placeholderString = String(localized: "search.placeholder")
        field.setAccessibilityLabel(String(localized: "search.placeholder"))
        field.setAccessibilitySubrole(.searchField)
        field.delegate = context.coordinator
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.font = .systemFont(ofSize: 13)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRevision != focusRevision {
            context.coordinator.focusRevision = focusRevision
            if field.window != nil { field.selectText(nil) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CatalogSearchField
        var focusRevision = -1
        init(_ parent: CatalogSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Let the input method finish composition before treating Return/arrows as result commands.
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)): parent.onNavigate(1)
            case #selector(NSResponder.moveUp(_:)): parent.onNavigate(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.onPlay()
            case #selector(NSResponder.cancelOperation(_:)): parent.onDismiss()
            default: return false
            }
            return true
        }
    }
}

private final class FocusedSearchField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers == "f",
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command {
            selectText(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, window != nil, currentEditor() == nil else { return }
            selectText(nil)
        }
    }
}
