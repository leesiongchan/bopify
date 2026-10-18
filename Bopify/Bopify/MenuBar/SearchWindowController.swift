import AppKit
import SwiftUI
import Observation
import os
import BopifyDomain
import BopifyLibrary

@MainActor @Observable
final class SearchWindowController: NSObject, NSWindowDelegate {
    private(set) var focusRevision = 0
    var isVisible: Bool { window?.isVisible == true }
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var onClose: (() -> Void)?

    func show(environment: AppEnvironment) {
        if window == nil {
            let window = SearchWindow(contentViewController: NSHostingController(rootView: SearchView(environment: environment)))
            window.title = String(localized: "search.title")
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 420, height: 480))
            window.minSize = NSSize(width: 360, height: 300)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
            onClose = { [weak environment] in environment?.search.clear() }
        }
        focusRevision += 1
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
        window = nil
        BopifyLog.library.debug("catalog search closed")
    }
}

private final class SearchWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers == "f",
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           let field = contentView?.catalogSearchField {
            field.selectText(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private extension NSView {
    var catalogSearchField: NSSearchField? {
        if let field = self as? NSSearchField { return field }
        return subviews.lazy.compactMap(\.catalogSearchField).first
    }
}
