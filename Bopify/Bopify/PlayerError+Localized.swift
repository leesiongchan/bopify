import SwiftUI
import BopifyDomain

/// Raw Swift case names (`networkUnavailable`) are developer diagnostics,
/// not user-facing text. Every case gets its own key in Localizable.xcstrings.
extension PlayerError {
    var localizedText: Text {
        switch self {
        case .authDenied: Text("error.authDenied")
        case .invalidCallback: Text("error.invalidCallback")
        case .authExpired: Text("error.authExpired")
        case .premiumRequired: Text("error.premiumRequired")
        case .networkUnavailable: Text("error.networkUnavailable")
        case .playbackSessionLost: Text("error.playbackSessionLost")
        case .credentialCleanupNotRecorded: Text("error.credentialCleanupNotRecorded")
        case .credentialCleanupRequired: Text("error.credentialCleanupRequired")
        case .credentialUnavailable: Text("error.credentialUnavailable")
        case .credentialAccessDenied: Text("error.credentialAccessDenied")
        case .credentialCorrupt: Text("error.credentialCorrupt")
        case .credentialSaveFailed: Text("error.credentialSaveFailed")
        case .unknown: Text("error.unknown")
        }
    }
}
