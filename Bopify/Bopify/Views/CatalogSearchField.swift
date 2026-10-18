import AppKit
import SwiftUI

struct CatalogSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRevision: Int
    let onNavigate: (Int) -> Void
    let onPlay: () -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = FocusedSearchField()
        field.placeholderString = String(localized: "search.placeholder")
        field.setAccessibilityLabel(String(localized: "search.placeholder"))
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.controlSize = .large
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRevision != focusRevision, field.window != nil {
            context.coordinator.focusRevision = focusRevision
            field.selectText(nil)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: CatalogSearchField
        var focusRevision = -1
        init(_ parent: CatalogSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
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

private final class FocusedSearchField: NSSearchField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Task { @MainActor [weak self] in self?.selectText(nil) }
    }
}
