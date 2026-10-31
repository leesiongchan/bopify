import AppKit
import SwiftUI

@MainActor
final class RecordDesignWindowController {
    private let defaults: UserDefaults
    private let model: RecordDesignPickerModel
    private var window: NSWindow?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        model = RecordDesignPickerModel(defaults: defaults)
    }

    func show() {
        model.focused = .resolve(defaults.string(forKey: RecordDesign.preferenceKey))
        if window == nil {
            let model = self.model
            let content = RecordDesignPicker(model: model, onClose: { [weak self] in self?.close() }).defaultAppStorage(defaults)
            let window = RecordDesignWindow(contentViewController: NSHostingController(rootView: content))
            window.onMove = { [weak model] in model?.move($0) }
            window.onActivate = { [weak model] in model?.activate() }
            window.title = String(localized: "record.title", bundle: Bundle(for: RecordDesignWindowController.self))
            window.identifier = NSUserInterfaceItemIdentifier("record-design")
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = .clear
            window.isOpaque = false
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}

private final class RecordDesignWindow: NSWindow {
    var onMove: ((RecordDesignPickerModel.Direction) -> Void)?
    var onActivate: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            switch event.keyCode {
            case 123: onMove?(.left); return
            case 124: onMove?(.right); return
            case 125: onMove?(.down); return
            case 126: onMove?(.up); return
            case 36, 49, 76: onActivate?(); return
            case 53: close(); return
            default: break
            }
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { close() }
}
