import AppKit
import SwiftUI

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private var panel: StatusPanel?
    private var outsideClickMonitor: Any?

    init<Content: View>(content: Content) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Bopify")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        panel = StatusPanel(content: content)
    }

    @objc private func toggle() {
        guard let panel, let button = statusItem.button else { return }
        if panel.isVisible { dismiss(); return }

        if let frame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) {
            let origin = NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY - panel.frame.height - 6)
            panel.setFrameOrigin(origin)
        }
        panel.makeKeyAndOrderFront(nil)

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    private func dismiss() {
        panel?.orderOut(nil)
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }
}
