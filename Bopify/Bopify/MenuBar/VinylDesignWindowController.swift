import AppKit
import SwiftUI

@MainActor
final class VinylDesignWindowController {
    private let defaults: UserDefaults
    private let model: VinylDesignPickerModel
    private var window: NSWindow?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        model = VinylDesignPickerModel(defaults: defaults)
    }

    func show() {
        model.focused = .resolve(defaults.string(forKey: VinylDesign.preferenceKey))
        if window == nil {
            let model = self.model
            let content = VinylDesignPicker(model: model, onClose: { [weak self] in self?.close() }).defaultAppStorage(defaults)
            let window = VinylDesignWindow(contentViewController: NSHostingController(rootView: content))
            window.onMove = { [weak model] in model?.move($0) }
            window.onActivate = { [weak model] in model?.activate() }
            window.title = String(localized: "vinyl.title", bundle: Bundle(for: VinylDesignWindowController.self))
            window.identifier = NSUserInterfaceItemIdentifier("vinyl-design")
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

private final class VinylDesignWindow: NSWindow {
    var onMove: ((VinylDesignPickerModel.Direction) -> Void)?
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
