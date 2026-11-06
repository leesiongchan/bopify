import Foundation

private final class SoloistResourceToken: NSObject {}

enum SoloistResources {
    static let bundle = Bundle(for: SoloistResourceToken.self)
    static func string(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: nil) }
}
