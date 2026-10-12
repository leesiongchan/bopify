import Foundation
import BopifyAuth
import BopifyDomain

@main struct SignedKeychainProbe {
    enum Failure: Error { case check(String) }

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.check(message) }
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count == 3, ["write", "verify", "cleanup"].contains(args[1]),
              let identifier = UUID(uuidString: args[2]) else {
            FileHandle.standardError.write(Data("ERROR: use write|verify|cleanup UUID\n".utf8))
            exit(2)
        }
        let service = "com.leesiongchan.bopify.validation.keychain.\(identifier.uuidString)"
        let playback = KeychainTokenStore(service: service)
        let library = KeychainTokenStore(service: service + ".library")
        let expiry = Date(timeIntervalSince1970: 4_102_444_800)
        let original = TokenSet(accessToken: "SYNTHETIC_PLAYBACK", refreshToken: "SYNTHETIC_REFRESH",
                                expiresAt: expiry, grantedScopes: ["streaming"])
        let libraryToken = TokenSet(accessToken: "SYNTHETIC_LIBRARY", refreshToken: nil,
                                    expiresAt: expiry, grantedScopes: ["user-library-read"])
        let updated = TokenSet(accessToken: "SYNTHETIC_UPDATED", refreshToken: "SYNTHETIC_ROTATED",
                               expiresAt: expiry.addingTimeInterval(600), grantedScopes: ["streaming", "user-read-email"])
        do {
            switch args[1] {
            case "write":
                try require(try playback.load() == nil && library.load() == nil, "test services must start absent")
                try playback.save(original)
                try library.save(libraryToken)
                try require(try playback.load() == original && library.load() == libraryToken, "complete add/read round trip")
                print("PASS: two isolated services absent, added, and fully round-tripped")
            case "verify":
                try require(try playback.load() == original && library.load() == libraryToken, "persistence across signed-process relaunch")
                try playback.save(updated)
                try require(try playback.load() == updated, "update preserves every token field")
                try playback.clear()
                try require(try playback.load() == nil && library.load() == libraryToken, "deleting playback preserves library service")
                print("PASS: relaunch persistence, complete update, and isolated deletion")
            default:
                var failures = 0
                for store in [playback, library] {
                    do { try store.clear() }
                    catch {
                        failures += 1
                        FileHandle.standardError.write(Data("ERROR: isolated cleanup failed: \(error)\n".utf8))
                    }
                }
                try require(failures == 0, "both isolated cleanup operations must succeed")
                try require(try playback.load() == nil && library.load() == nil, "both isolated services removed")
                print("PASS: cleanup completed; both isolated services absent")
            }
        } catch {
            FileHandle.standardError.write(Data("ERROR: signed Keychain check failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
