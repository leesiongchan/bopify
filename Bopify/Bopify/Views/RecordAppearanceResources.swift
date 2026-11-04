import AppKit
import SwiftUI
import CoreText
import BopifyDomain
import os

@MainActor enum RecordAppearanceResources {
    static let bundle = Bundle(for: AppearanceResourceBundle.self)
    private static var prepared = false
    private static var missing = Set<String>()
    private static var images: [String: NSImage] = [:]
    static func prepare() {
        guard !prepared else { return }
        prepared = true
        for name in ["Allura-Regular", "IBMPlexSansCondensed-Medium"] {
            guard let url = bundle.url(forResource: name, withExtension: "ttf") else { report(name); continue }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
                if code != CTFontManagerError.alreadyRegistered.rawValue { report(name) }
            }
        }
    }
    static func image(named name: String) -> NSImage? {
        if let image = images[name] { return image }
        guard let url = bundle.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) else {
            report(name); return nil
        }
        images[name] = image
        return image
    }
    static var deck: NSImage? { image(named: "sunburst-deck") }
    static var corduroy: NSImage? { image(named: "corduroy-crisp") }
    static func plateFont(compact: Bool) -> Font {
        prepare()
        return .custom("IBMPlexSansCond-Medium", fixedSize: compact ? 6.2 : 7)
    }
    static func recordFont(compact: Bool) -> Font {
        prepare()
        return .custom("Allura-Regular", fixedSize: compact ? 22 : 24)
    }
    private static func report(_ name: String) {
        guard missing.insert(name).inserted else { return }
        BopifyLog.playback.error("appearance resource unavailable name=\(name, privacy: .public)")
    }
}
private final class AppearanceResourceBundle: NSObject {}
