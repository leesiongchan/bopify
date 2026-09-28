import SwiftUI

@main struct MonolithInputRoutingProbe {
    @MainActor static func main() {
        _ = NSApplication.shared
        var failures = 0
        func check(_ valid: Bool, _ message: String) {
            print("\(valid ? "PASS" : "FAIL"): \(message)")
            if !valid { failures += 1 }
        }
        check(coverFlowRelativeIndex(x: 30, radius: 2) == 0, "centered cover owns its visible right edge")
        check(coverFlowRelativeIndex(x: -30, radius: 2) == 0, "centered cover owns its visible left edge")
        check(coverFlowRelativeIndex(x: 55, radius: 2) == 1, "visible side cover centers its own song")
        let panel = StatusPanel(content: Color.clear)
        panel.setFrame(CGRect(x: 100, y: 100, width: 300, height: 200), display: false)
        let input = CoverFlowInput.InputView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        var browsing: [Int] = [], playCount = 0, toggleCount = 0, previousCount = 0, nextCount = 0, seekCount = 0
        input.actions = CoverFlowInput(click: { _, _ in }, drag: { _ in }, end: {}, wheel: { _ in },
                                       navigate: { browsing.append($0) }, play: { playCount += 1 })
        panel.contentView!.addSubview(input)
        panel.makeFirstResponder(input)
        panel.onTogglePlayback = { toggleCount += 1 }
        panel.onPrevious = { previousCount += 1 }
        panel.onNext = { nextCount += 1 }
        panel.onSeek = { _ in seekCount += 1 }
        func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                            windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                            isARepeat: false, keyCode: code)!
        }
        input.keyDown(with: key(123)); input.keyDown(with: key(124)); input.keyDown(with: key(36))
        input.keyDown(with: key(49)); input.keyDown(with: key(123, .command)); input.keyDown(with: key(124, .command))
        check(browsing == [-1, 1] && playCount == 1 && seekCount == 0, "carousel owns arrows and Return")
        check(toggleCount == 1 && previousCount == 1 && nextCount == 1, "unhandled keys reach panel transport shortcuts")
        let record = RecordPointerRegion.PointerView(frame: CGRect(x: 0, y: 0, width: 118, height: 118))
        panel.contentView!.addSubview(record)
        var pressGeometry: UInt64?, dragGeometry: UInt64?
        record.press = { _, geometry in pressGeometry = geometry }
        record.drag = { _, geometry in dragGeometry = geometry }
        func mouse(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 60), modifierFlags: [], timestamp: 0,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        record.mouseDown(with: mouse(.leftMouseDown, x: 100))
        panel.setFrameOrigin(CGPoint(x: 115, y: 100))
        record.mouseDragged(with: mouse(.leftMouseDragged, x: 90))
        check(pressGeometry != nil && dragGeometry != nil && pressGeometry != dragGeometry,
              "same-size record relocation changes scrub geometry identity")
        // Direct responder calls test routing logic only, not WindowServer/native input acceptance.
        print("INPUT ROUTING LOGIC \(failures == 0 ? "PASS" : "FAIL")")
        exit(failures == 0 ? 0 : 1)
    }
}
