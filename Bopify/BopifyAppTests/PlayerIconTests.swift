import AppKit
import Testing

@MainActor @Suite("Player icon assets")
struct PlayerIconTests {
    @Test(arguments: ["BopRecord", "BopStatus", "BopLyrics", "BopQueue", "BopRadio", "BopHeart", "BopHeartFill", "BopHeartSlash"])
    func customIconsLoadAsNativeSymbols(name: String) throws {
        let bundle = Bundle(for: IconBundle.self)
        let image = try #require(bundle.image(forResource: NSImage.Name(name)))
        #expect(image.withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) != nil)
        #expect(image.size.width > 0 && image.size.height > 0)
    }
}

private final class IconBundle {}
