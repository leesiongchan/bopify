// Run using Xcode RunCodeSnippet in Views/PlayerPreviews.swift context.
let fixture = PlayerMotionFixture()
let panel = StatusPanel(content: PlayerMotionScene(fixture: fixture))
panel.setFrame(NSRect(x: 100, y: 100, width: 410, height: 560), display: true)
panel.makeKeyAndOrderFront(nil)
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bopify-motion-frames", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
@MainActor func capture(_ name: String) throws {
    guard let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
}
try await Task.sleep(for: .milliseconds(200))
try capture("00-initial")
fixture.index = 2
try await Task.sleep(for: .milliseconds(200))
try capture("01-next-200ms")
fixture.index = 3
try await Task.sleep(for: .milliseconds(200))
try capture("02-next-next-200ms")
fixture.index = 2
try await Task.sleep(for: .milliseconds(800))
try capture("03-previous-settled")
fixture.presentation.setMode(.queue)
try await Task.sleep(for: .milliseconds(250))
try capture("04-queue-midpoint")
try await Task.sleep(for: .milliseconds(500))
try capture("05-queue-settled")
fixture.presentation.setMode(.expanded)
try await Task.sleep(for: .milliseconds(250))
try capture("06-expand-midpoint")
try await Task.sleep(for: .milliseconds(500))
try capture("07-expand-settled")
panel.orderOut(nil)
print("Captured native transition frames in \(directory.path)")