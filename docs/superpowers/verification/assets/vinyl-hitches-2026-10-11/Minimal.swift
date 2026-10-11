import AppKit
import SwiftUI
import Darwin

@MainActor enum MiniClock {
    static var start: Double?
    static var ticks: [Double] = []
    static func tick() {
        if let start { ticks.append(ProcessInfo.processInfo.systemUptime - start) }
    }
    static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}

struct MiniScene: View {
    let interval: Double
    var body: some View {
        TimelineView(.animation(minimumInterval: interval)) { context in
            let _ = MiniClock.tick()
            Rectangle().fill(.orange).frame(width: 120, height: 20)
                .rotationEffect(.radians(context.date.timeIntervalSinceReferenceDate * 2))
                .frame(width: 484, height: 360)
        }
    }
}

final class MiniAppKitView: NSView {
    private var timer: Timer?
    private var angle = 0.0
    override var isFlipped: Bool { true }
    func start() {
        timer = Timer.scheduledTimer(timeInterval: 1.0 / 30, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }
    @objc private func tick() {
        MiniClock.tick()
        angle = ProcessInfo.processInfo.systemUptime * 2
        needsDisplay = true
    }
    override func draw(_ rect: NSRect) {
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX, yBy: bounds.midY)
        transform.rotate(byRadians: angle)
        transform.concat()
        NSColor.orange.setFill()
        NSRect(x: -60, y: -10, width: 120, height: 20).fill()
    }
}

@main struct MinimalProbe {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(ProcessInfo.processInfo.environment["HITCH_MINIMAL_ACCESSORY"] == "1" ? .accessory : .regular)
        Task { @MainActor in
            do {
                let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
                let mode = ProcessInfo.processInfo.environment["HITCH_MINIMAL_MODE"] ?? "swiftui30"
                let panel = StatusPanel(content: MiniScene(interval: mode == "swiftui60" ? 1.0 / 60 : 1.0 / 30))
                if mode == "appkit30" {
                    let view = MiniAppKitView(frame: NSRect(x: 0, y: 0, width: 484, height: 360))
                    panel.contentView = view
                    view.start()
                }
                panel.setFrame(NSRect(x: NSScreen.screens[0].visibleFrame.minX + 80, y: NSScreen.screens[0].visibleFrame.minY + 80, width: 484, height: 360), display: true)
                panel.appearance = NSAppearance(named: .darkAqua)
                panel.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .seconds(1))
                print("GPU CONTROL: pid=\(ProcessInfo.processInfo.processIdentifier) window=\(panel.windowNumber) display=\(String(describing: panel.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")])) frame=\(panel.frame) scale=\(panel.backingScaleFactor) minimal=\(mode) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
                fflush(stdout)
                let readyVisible = panel.occlusionState.contains(.visible)
                let readyActive = app.isActive
                let readyKey = panel.isKeyWindow
                try await Task.sleep(for: .seconds(5))
                MiniClock.ticks = []
                let cpuStart = MiniClock.cpu()
                let start = ProcessInfo.processInfo.systemUptime
                MiniClock.start = start
                try await Task.sleep(for: .seconds(10))
                let end = ProcessInfo.processInfo.systemUptime
                MiniClock.start = nil
                let data = try JSONSerialization.data(withJSONObject: [
                    "duration_seconds": end - start, "cpu_seconds": MiniClock.cpu() - cpuStart,
                    "motor_ticks_seconds": MiniClock.ticks, "progress_ticks_seconds": [Double](),
                    "visible_at_ready": readyVisible, "visible_at_end": panel.occlusionState.contains(.visible),
                    "key_at_ready": readyKey, "key_at_end": panel.isKeyWindow,
                    "app_active_at_ready": readyActive, "app_active_at_end": app.isActive
                ], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output.appendingPathComponent("cadence.json"), options: .atomic)
                try await Task.sleep(for: .seconds(29))
                app.terminate(nil)
            } catch {
                print(error)
                fflush(stdout)
                exit(1)
            }
        }
        app.run()
    }
}
