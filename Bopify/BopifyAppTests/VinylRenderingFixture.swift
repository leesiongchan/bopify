import AppKit
import SwiftUI
import CoreGraphics
import BopifyPlayback
import Testing

@MainActor enum VinylRenderingFixture {
    static let directory = URL(fileURLWithPath: "/tmp/bopify-vinyl-validation", isDirectory: true)
    static let captureRequests = directory.appendingPathComponent("capture-requests", isDirectory: true)
    static var canCapture: Bool {
        CGPreflightScreenCaptureAccess() || FileManager.default.fileExists(atPath: captureRequests.appendingPathComponent("ready").path)
    }
    static let warm = ArtworkPalette.marble(
        ArtworkColor(red: 0.9333, green: 0.5098, blue: 0.4510),
        ArtworkColor(red: 0.7255, green: 0.8392, blue: 0.7608),
        ArtworkColor(red: 0.9569, green: 0.8745, blue: 0.6078))
    static let cool = ArtworkPalette.marble(
        ArtworkColor(red: 0.88, green: 0.51, blue: 0.70),
        ArtworkColor(red: 0.45, green: 0.77, blue: 0.90),
        ArtworkColor(red: 0.85, green: 0.90, blue: 0.88))

    static func capture<Content: View>(_ content: Content, size: CGSize, to url: URL, background: Color = .black) async throws -> NSBitmapImageRep {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 300, y: 300), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.contentView = NSHostingView(rootView: content.frame(width: size.width, height: size.height).background(background))
        defer { window.close() }
        window.orderFrontRegardless()
        return try await capture(window, to: url)
    }

    static func capture(_ window: NSWindow, to url: URL) async throws -> NSBitmapImageRep {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        if FileManager.default.fileExists(atPath: captureRequests.appendingPathComponent("ready").path) {
            let id = UUID().uuidString
            let request = captureRequests.appendingPathComponent("\(id).request")
            let response = captureRequests.appendingPathComponent("\(id).response")
            defer { try? FileManager.default.removeItem(at: response) }
            let payload: [String: Any] = ["window": window.windowNumber, "pid": ProcessInfo.processInfo.processIdentifier, "file": url.lastPathComponent]
            try JSONSerialization.data(withJSONObject: payload).write(to: request, options: .atomic)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !FileManager.default.fileExists(atPath: response.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let status = try String(contentsOf: response, encoding: .utf8)
            try #require(status == "ok", "Host window capture failed: \(status)")
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0, "Window-server capture must succeed")
        }
        return try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
    }

    static func differingAnnulusFraction(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Double {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else { return 1 }
        var count = 0, changed = 0
        for y in stride(from: 0, to: lhs.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: lhs.pixelsWide, by: 2) {
                let r = hypot(Double(x) / Double(lhs.pixelsWide) * 2 - 1, Double(y) / Double(lhs.pixelsHigh) * 2 - 1)
                guard (0.5...0.95).contains(r),
                      let a = lhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = rhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                count += 1
                if max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                       abs(a.blueComponent - b.blueComponent)) > 8.0 / 255 { changed += 1 }
            }
        }
        return count == 0 ? 0 : Double(changed) / Double(count)
    }

    static func coloredAnnulusFraction(_ image: NSBitmapImageRep) -> Double {
        var count = 0, colored = 0
        for y in stride(from: 0, to: image.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: image.pixelsWide, by: 2) {
                let r = hypot(Double(x) / Double(image.pixelsWide) * 2 - 1, Double(y) / Double(image.pixelsHigh) * 2 - 1)
                guard (0.5...0.95).contains(r), let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                count += 1
                if max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent) > 0.15 {
                    colored += 1
                }
            }
        }
        return count == 0 ? 0 : Double(colored) / Double(count)
    }
}
