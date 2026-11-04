import AppKit
import SwiftUI

@MainActor final class RecordAppearanceWindowController: NSObject, NSWindowDelegate {
    let model: RecordAppearancePickerModel
    private var window: RecordAppearanceWindow?
    private let reduceMotion: @MainActor () -> Bool

    init(defaults: UserDefaults = .standard,
         reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        model = RecordAppearancePickerModel(defaults: defaults)
        self.reduceMotion = reduceMotion
    }
    func show() {
        model.refreshPreferences()
        if window == nil {
            RecordAppearanceResources.prepare()
            let window = RecordAppearanceWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 655),
                                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: RecordAppearancePicker(model: model, onClose: { [weak self] in self?.close() })
                .environment(\.accessibilityEnabled, true))
            let reduceMotion = self.reduceMotion
            window.onMove = { [weak model] in model?.move($0) }
            window.onTab = { [weak model] in model?.moveTab(backward: $0, reduceMotion: reduceMotion()) }
            window.onActivate = { [weak model] in model?.activateFocused(reduceMotion: reduceMotion()) }
            window.onHidden = { [weak model] in model?.isPreviewVisible = false }
            window.title = String(localized: "appearance.title", bundle: RecordAppearanceResources.bundle)
            window.identifier = NSUserInterfaceItemIdentifier("record-appearance")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(srgbRed: 0.18, green: 0.22, blue: 0.18, alpha: 1)
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            let available = (NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 760)).insetBy(dx: 20, dy: 20)
            let width: CGFloat = available.height < 655 ? min(760, available.width) : min(900, available.width)
            let height: CGFloat = min(width < 820 ? 631 : 655, available.height)
            window.minSize = CGSize(width: min(760, available.width), height: min(631, available.height))
            window.maxSize = CGSize(width: min(900, available.width), height: min(655, available.height))
            window.setFrame(CGRect(x: available.midX - width / 2, y: available.midY - height / 2, width: width, height: height), display: false)
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        updateVisibility()
    }
    func close() {
        model.isPreviewVisible = false
        window?.close()
    }
    func windowWillClose(_ notification: Notification) { model.isPreviewVisible = false }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { model.isPreviewVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) { updateVisibility() }
    private func updateVisibility() {
        model.isPreviewVisible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false
    }
}

private final class RecordAppearanceWindow: NSWindow {
    var onMove: ((RecordAppearancePickerModel.NavigationDirection) -> Void)?
    var onTab: ((Bool) -> Void)?
    var onActivate: (() -> Void)?
    var onHidden: (() -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 48,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            onTab?(event.modifierFlags.contains(.shift)); return
        }
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            switch event.keyCode {
            case 123: onMove?(.left); return
            case 124: onMove?(.right); return
            case 125: onMove?(.down); return
            case 126: onMove?(.up); return
            case 115: onMove?(.first); return
            case 119: onMove?(.last); return
            case 36, 49, 76: onActivate?(); return
            case 53: close(); return
            default: break
            }
        }
        super.sendEvent(event)
    }
    override func orderOut(_ sender: Any?) { super.orderOut(sender); onHidden?() }
    override func cancelOperation(_ sender: Any?) { close() }
}
