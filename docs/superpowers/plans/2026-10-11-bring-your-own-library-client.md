# Bring-Your-Own Library Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hard-coded Dashboard client ID with one each user supplies, so library features work for any number of public users.

**Architecture:** A new `LibraryAuthorization` actor in `BopifyAuth` owns the user's client ID (in `UserDefaults`) and the `SpotifyAuthService` built from it; with no ID every library token request throws `LibraryError.authorizationRequired`, which the UI already turns into an Enable action. `AppEnvironment` composes it in place of the fixed library auth service, and a small AppKit-hosted Library Access window collects the ID.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI hosted in AppKit, Keychain, existing Spotify PKCE/loopback flow; macOS 14 minimum.

**Spec:** [2026-10-11-public-distribution-design.md](../specs/2026-10-11-public-distribution-design.md), section "Library access: bring your own client ID".

## Global Constraints

- Do not change playback auth, `librespotClientID`, the Rust bridge, or transport behavior.
- Library Keychain service stays `com.leesiongchan.bopify.library`; callback stays port `8898`, path `/callback`. The redirect URI users register is exactly `http://127.0.0.1:8898/callback`.
- `UserDefaults` key: `library.clientID`. A valid ID is exactly 32 characters of `0-9a-f` after trimming whitespace and lowercasing.
- Changing the ID clears the library Keychain item and library browsing state. Sign-out clears the library token but keeps the ID. Quit keeps both.
- No browser opens without a user action; with no ID, Enable opens Library Access instead.
- Log state changes only; never log client IDs, tokens, or library contents.
- Work in `.worktrees/byo-library-client`, branched from `main` after the user's in-flight changes are committed. The package build needs `artifacts/BopifyCoreFFI.xcframework`: run `./scripts/build-rust.sh` once in the worktree.

## Review Focus

1. Fresh install, no ID: playback works; every library surface shows its Enable action; Enable opens Library Access, not a browser (Task 2).
2. Replacing an ID while a library grant exists: the old service is signed out (memory and Keychain) and detached before any await, so no request mid-swap reaches either client (Task 1).
3. Saving the same ID again (different case/whitespace) keeps the existing grant (Task 1).
4. Sign-out then sign-in: the ID survives, the library grant does not (Task 2).

---

### Task 1: `LibraryAuthorization` actor

**Files:**
- Create: `Packages/BopifyCore/Sources/BopifyAuth/LibraryAuthorization.swift`
- Test: `Packages/BopifyCore/Tests/AuthTests/LibraryAuthorizationTests.swift`

**Interfaces:**
- Consumes: `SpotifyAuthService.authorizeLibraryScopes(_:)`, `validAccessToken(requiredScopes:)`, `signOut()`, `cancelPendingWork()`; `InMemoryTokenStore` (already in `SpotifyAuthServiceTests.swift`, same test target).
- Produces:
  - `public actor LibraryAuthorization`
  - `public static let defaultsKey = "library.clientID"`
  - `public static func normalized(_ raw: String) -> String?`
  - `public static func storedClientID(in defaults: UserDefaults) -> String?`
  - `public init(defaults: UserDefaults = .standard, makeAuth: @escaping @Sendable (String) -> SpotifyAuthService)`
  - `public func setClientID(_ raw: String) async throws -> String` (returns the normalized ID; throws `LibraryClientIDError.invalid`)
  - `public func authorize(_ scopes: Set<String>) async throws`
  - `public func validAccessToken(requiredScopes: Set<String>) async throws -> String`
  - `public func signOut() async`, `public func cancelPendingWork() async`
  - `public enum LibraryClientIDError: Error, Equatable { case invalid }`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import BopifyAuth
import BopifyDomain

@Suite("LibraryAuthorization", .serialized)
struct LibraryAuthorizationTests {
    private let id = "25bbd3bacca4412b80f17b892072af71"
    private let other = "0123456789abcdef0123456789abcdef"

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "LibraryAuthorizationTests.\(UUID().uuidString)")!
    }

    private func grant() -> TokenSet {
        TokenSet(accessToken: "LIBRARY", refreshToken: "LIBRARY_RT",
                 expiresAt: Date().addingTimeInterval(3600), grantedScopes: ["user-library-read"])
    }

    private func authorization(_ defaults: UserDefaults, store: InMemoryTokenStore) -> LibraryAuthorization {
        LibraryAuthorization(defaults: defaults) { clientID in
            SpotifyAuthService(clientID: clientID, store: store, openURL: { _ in })
        }
    }

    @Test func normalizesPastedInput() {
        #expect(LibraryAuthorization.normalized("  25BBD3BACCA4412B80F17B892072AF71\n") == id)
    }

    @Test(arguments: ["", "25bbd3bacca4412b80f17b892072af7", "25bbd3bacca4412b80f17b892072af711",
                      "g5bbd3bacca4412b80f17b892072af71", "２5bbd3bacca4412b80f17b892072af71"])
    func rejectsMalformedIDs(_ raw: String) {
        #expect(LibraryAuthorization.normalized(raw) == nil)
    }

    @Test func ignoresAnInvalidStoredID() {
        let defaults = freshDefaults()
        defaults.set("not-an-id", forKey: LibraryAuthorization.defaultsKey)
        #expect(LibraryAuthorization.storedClientID(in: defaults) == nil)
    }

    @Test func missingIDRequiresAuthorization() async {
        let library = authorization(freshDefaults(), store: InMemoryTokenStore())
        await #expect(throws: LibraryError.authorizationRequired) {
            try await library.validAccessToken(requiredScopes: ["user-library-read"])
        }
        await #expect(throws: LibraryError.authorizationRequired) {
            try await library.authorize(["user-library-read"])
        }
    }

    @Test func storedIDServesItsGrant() async throws {
        let defaults = freshDefaults()
        defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
        let store = InMemoryTokenStore()
        try store.save(grant())
        let library = authorization(defaults, store: store)
        #expect(try await library.validAccessToken(requiredScopes: ["user-library-read"]) == "LIBRARY")
    }

    @Test func settingAnIDPersistsItAndClearsAnyEarlierGrant() async throws {
        let defaults = freshDefaults()
        let store = InMemoryTokenStore()
        try store.save(grant())  // left behind by a client the app no longer knows
        let library = authorization(defaults, store: store)
        #expect(try await library.setClientID(id.uppercased()) == id)
        #expect(defaults.string(forKey: LibraryAuthorization.defaultsKey) == id)
        #expect(store.load() == nil)
    }

    @Test func replacingTheIDClearsTheGrant() async throws {
        let defaults = freshDefaults()
        defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
        let store = InMemoryTokenStore()
        try store.save(grant())
        let library = authorization(defaults, store: store)
        _ = try await library.setClientID(other)
        #expect(store.load() == nil)
        await #expect(throws: LibraryError.authorizationRequired) {
            try await library.validAccessToken(requiredScopes: ["user-library-read"])
        }
    }

    /// `cancelPendingWork()` alone would leave the old service holding its in-memory grant.
    @Test func replacingTheIDSignsOutTheOldClient() async throws {
        let defaults = freshDefaults()
        defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
        let store = InMemoryTokenStore()
        try store.save(grant())
        let created = CreatedServices()
        let library = LibraryAuthorization(defaults: defaults) { clientID in
            created.record(SpotifyAuthService(clientID: clientID, store: store, openURL: { _ in }))
        }
        let old = try #require(created.first)
        #expect(try await old.validAccessToken(requiredScopes: ["user-library-read"]) == "LIBRARY")
        _ = try await library.setClientID(other)
        await #expect(throws: LibraryError.authorizationRequired) {
            try await old.validAccessToken(requiredScopes: ["user-library-read"])
        }
    }

    @Test func savingTheSameIDKeepsTheGrant() async throws {
        let defaults = freshDefaults()
        defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
        let store = InMemoryTokenStore()
        try store.save(grant())
        let library = authorization(defaults, store: store)
        _ = try await library.setClientID(" \(id.uppercased()) ")
        #expect(store.load() != nil)
    }

    @Test func invalidIDLeavesStateUntouched() async throws {
        let defaults = freshDefaults()
        defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
        let store = InMemoryTokenStore()
        try store.save(grant())
        let library = authorization(defaults, store: store)
        await #expect(throws: LibraryClientIDError.invalid) { try await library.setClientID("nope") }
        #expect(defaults.string(forKey: LibraryAuthorization.defaultsKey) == id)
        #expect(store.load() != nil)
    }
}

/// Records each auth service `makeAuth` builds, so a test can probe one after it is replaced.
private final class CreatedServices: @unchecked Sendable {
    private let lock = NSLock()
    private var services: [SpotifyAuthService] = []

    var first: SpotifyAuthService? { lock.withLock { services.first } }

    func record(_ service: SpotifyAuthService) -> SpotifyAuthService {
        lock.withLock { services.append(service) }
        return service
    }
}
```

`SpotifyAuthService.signOut()` clears its in-memory tokens and the store, so the old service then finds no grant and throws `LibraryError.authorizationRequired` for a scoped request (`SpotifyAuthService.swift:147-148`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Packages/BopifyCore --filter LibraryAuthorizationTests`
Expected: compile failure, `cannot find 'LibraryAuthorization' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import os
import BopifyDomain

public enum LibraryClientIDError: Error, Equatable { case invalid }

/// The user's own Spotify Dashboard client for Web API library access. Spotify caps a
/// Development Mode app at five users, so every user registers one; the ID is public, not a secret.
public actor LibraryAuthorization {
    public static let defaultsKey = "library.clientID"

    private let defaults: UserDefaults
    private let makeAuth: @Sendable (String) -> SpotifyAuthService
    private var clientID: String?
    private var auth: SpotifyAuthService?

    public init(defaults: UserDefaults = .standard, makeAuth: @escaping @Sendable (String) -> SpotifyAuthService) {
        self.defaults = defaults
        self.makeAuth = makeAuth
        clientID = Self.storedClientID(in: defaults)
        auth = clientID.map(makeAuth)
    }

    /// Spotify client IDs are 32 lowercase hex characters; pasted input often carries case or whitespace.
    public static func normalized(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hex = Set("0123456789abcdef")
        return id.count == 32 && id.allSatisfy(hex.contains) ? id : nil
    }

    public static func storedClientID(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: defaultsKey).flatMap(normalized)
    }

    public func setClientID(_ raw: String) async throws -> String {
        guard let id = Self.normalized(raw) else { throw LibraryClientIDError.invalid }
        if id == clientID { return id }
        // Detach before awaiting: requests arriving mid-swap fail instead of reaching either client.
        let previous = auth
        auth = nil
        clientID = nil
        // Tokens belong to the client that issued them, and every client shares one Keychain item.
        await previous?.signOut()
        let next = makeAuth(id)
        await next.signOut()
        defaults.set(id, forKey: Self.defaultsKey)
        clientID = id
        auth = next
        BopifyLog.auth.info("library client ID changed")
        return id
    }

    public func authorize(_ scopes: Set<String>) async throws {
        guard let auth else { throw LibraryError.authorizationRequired }
        _ = try await auth.authorizeLibraryScopes(scopes)
    }

    public func validAccessToken(requiredScopes: Set<String>) async throws -> String {
        guard let auth else { throw LibraryError.authorizationRequired }
        return try await auth.validAccessToken(requiredScopes: requiredScopes)
    }

    public func signOut() async { await auth?.signOut() }

    public func cancelPendingWork() async { await auth?.cancelPendingWork() }
}
```

If Swift 6 rejects storing `UserDefaults` in the actor (non-`Sendable`), keep the type and annotate the stored property `nonisolated(unsafe) private let defaults` — `UserDefaults` is documented thread-safe.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path Packages/BopifyCore --filter LibraryAuthorizationTests`
Expected: all pass. Then run the whole `AuthTests` target: `swift test --package-path Packages/BopifyCore --filter AuthTests` — expected: no regressions.

- [ ] **Step 5: Commit**

```bash
git add Packages/BopifyCore/Sources/BopifyAuth/LibraryAuthorization.swift Packages/BopifyCore/Tests/AuthTests/LibraryAuthorizationTests.swift
git commit -m "Add user-supplied client ID for library authorization"
```

### Task 2: Compose it in the app, with a Library Access window

**Files:**
- Modify: `Bopify/Bopify/AppEnvironment.swift` (remove `dashboardLibraryClientID` at :9; library auth at :41, :64-80, :89, :95-96; `enableLibrary` at :131)
- Create: `Bopify/Bopify/MenuBar/LibrarySetupWindowController.swift`
- Create: `Bopify/Bopify/Views/LibrarySetupView.swift`
- Modify: `Bopify/Bopify/MenuBar/StatusItemController.swift:204-208` (menu item)
- Modify: `Bopify/Bopify/Localizable.xcstrings` (new keys)
- Modify: `docs/superpowers/verification/MonolithLiveLibraryProbe.swift:8-9`
- Modify: `docs/spotify-app-setup.md` (rewrite as the user-facing setup guide)

**Interfaces:**
- Consumes: everything Task 1 produces.
- Produces (on `AppEnvironment`): `private(set) var libraryClientID: String?`, `let librarySetupWindow: LibrarySetupWindowController`, `func setLibraryClientID(_ raw: String) async`.

- [ ] **Step 1: Swap the library auth in `AppEnvironment`**

Delete the `dashboardLibraryClientID` constant. Change the stored property to `@ObservationIgnored private let libraryAuth: LibraryAuthorization` and add:

```swift
    private(set) var libraryClientID: String?
    let librarySetupWindow = LibrarySetupWindowController()
    // The scopes an Enable action asked for before any client ID existed; consent resumes after setup.
    @ObservationIgnored private var pendingLibraryScopes: Set<String> = []
```

In `init()` replace the `libraryAuth` construction and the two closures that use it:

```swift
        let libraryAuth = LibraryAuthorization { clientID in
            SpotifyAuthService(clientID: clientID,
                               store: KeychainTokenStore(service: "com.leesiongchan.bopify.library"),
                               callbackPort: 8898, callbackPath: "/callback")
        }
        self.libraryAuth = libraryAuth
        libraryClientID = LibraryAuthorization.storedClientID(in: .standard)
```

`SpotifyLibraryClient { scopes in try await libraryAuth.validAccessToken(requiredScopes: scopes) }` and `authorizeLibraryScopes = { scopes in try await libraryAuth.authorize(scopes) }` keep their shape. `signOut()` and `prepareForQuit()` already call `libraryAuth.signOut()` / `cancelPendingWork()`; those names are unchanged.

In the `#if DEBUG` init keep the `libraryAuth: SpotifyAuthService? = nil` parameter (probes pass it) and wrap it:

```swift
        let previewDefaults = UserDefaults(suiteName: "com.leesiongchan.bopify.preview.\(UUID().uuidString)")!
        previewDefaults.set(String(repeating: "0", count: 32), forKey: LibraryAuthorization.defaultsKey)
        let previewLibraryAuth = libraryAuth ?? SpotifyAuthService(clientID: String(repeating: "0", count: 32),
            store: KeychainTokenStore(service: "com.leesiongchan.bopify.preview.library.\(UUID().uuidString)"))
        self.libraryAuth = LibraryAuthorization(defaults: previewDefaults) { _ in previewLibraryAuth }
        libraryClientID = String(repeating: "0", count: 32)
```

At the top of `enableLibrary(scopes:)`, after the existing `guard`:

```swift
        guard libraryClientID != nil else {
            pendingLibraryScopes.formUnion(scopes)
            librarySetupWindow.show(environment: self)
            BopifyLog.library.info("library setup requested")
            return
        }
```

Add:

```swift
    func setLibraryClientID(_ raw: String) async {
        let previous = libraryClientID
        guard let id = try? await libraryAuth.setClientID(raw) else { return }
        libraryClientID = id
        librarySetupWindow.close()
        if id != previous { clearLibrary() }
        let scopes = pendingLibraryScopes
        pendingLibraryScopes = []
        if !scopes.isEmpty { await enableLibrary(scopes: scopes) }
    }
```

- [ ] **Step 2: Add the window controller**

```swift
import AppKit
import SwiftUI

/// An agent app has no Settings menu, so Library Access gets its own window, opened from the status menu or any Enable action.
@MainActor
final class LibrarySetupWindowController {
    private var window: NSWindow?

    func show(environment: AppEnvironment) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: LibrarySetupView(environment: environment)))
            window.title = String(localized: "librarySetup.title")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}
```

- [ ] **Step 3: Add the view**

```swift
import AppKit
import SwiftUI
import BopifyAuth

/// Spotify allows a Development Mode app only five users, so each user registers their own app for library access.
struct LibrarySetupView: View {
    let environment: AppEnvironment
    @State private var clientID = ""
    @State private var isSaving = false
    private static let redirectURI = "http://127.0.0.1:8898/callback"

    var body: some View {
        let isValid = LibraryAuthorization.normalized(clientID) != nil
        VStack(alignment: .leading, spacing: 14) {
            Text("librarySetup.intro").fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("librarySetup.step1")
                Link("librarySetup.openDashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                Text("librarySetup.step2")
                HStack {
                    Text(verbatim: Self.redirectURI).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button("librarySetup.copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.redirectURI, forType: .string)
                    }
                }
                Text("librarySetup.step3").fixedSize(horizontal: false, vertical: true)
                Text("librarySetup.step4")
            }
            TextField("librarySetup.clientID", text: $clientID)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if !clientID.isEmpty && !isValid {
                Text("librarySetup.invalid").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("librarySetup.save") {
                    isSaving = true
                    Task { await environment.setLibraryClientID(clientID); isSaving = false }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || !isValid)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { clientID = environment.libraryClientID ?? "" }
    }
}
```

- [ ] **Step 4: Add the status menu item**

In `StatusItemController.showMenu()`, after the `keepOnTop` item and before the separator:

```swift
        let libraryItem = NSMenuItem(title: String(localized: "menu.libraryAccess"),
                                     action: #selector(showLibraryAccess(_:)), keyEquivalent: "")
        libraryItem.target = self
        menu.addItem(libraryItem)
```

and next to `signOut(_:)`:

```swift
    @objc private func showLibraryAccess(_ sender: Any?) { environment.librarySetupWindow.show(environment: environment) }
```

- [ ] **Step 5: Add strings**

Add these keys to `Localizable.xcstrings` in the existing shape (`"en" → stringUnit → state "translated"`):

| Key | English value |
| --- | --- |
| `menu.libraryAccess` | `Library Access…` |
| `librarySetup.title` | `Library Access` |
| `librarySetup.intro` | `Favorites, Liked Songs and listening history need your own free Spotify app. Spotify lets each app serve only five people, so Bopify can't share one. Playback works without it.` |
| `librarySetup.step1` | `1. Open the Spotify Developer Dashboard and click Create app. Your account needs Premium.` |
| `librarySetup.openDashboard` | `Open Spotify Developer Dashboard` |
| `librarySetup.step2` | `2. Add this Redirect URI and tick Web API:` |
| `librarySetup.copy` | `Copy` |
| `librarySetup.step3` | `3. Save the app. Under User Management, add your own Spotify account's name and email — Spotify blocks anyone not on that list, owner included.` |
| `librarySetup.step4` | `4. Paste the app's Client ID below.` |
| `librarySetup.clientID` | `Client ID` |
| `librarySetup.invalid` | `A Client ID is 32 letters and numbers.` |
| `librarySetup.save` | `Save` |

- [ ] **Step 6: Update the live library probe**

Replace the `SpotifyAuthService(clientID: dashboardLibraryClientID, …)` lines with:

```swift
        guard let clientID = ProcessInfo.processInfo.environment["BOPIFY_LIBRARY_CLIENT_ID"]
            .flatMap(LibraryAuthorization.normalized) else {
            print("BLOCKED: set BOPIFY_LIBRARY_CLIENT_ID to your Dashboard app's client ID")
            exit(77)
        }
        let auth = SpotifyAuthService(clientID: clientID,
                                      store: KeychainTokenStore(service: "com.leesiongchan.bopify.library"))
```

- [ ] **Step 7: Rewrite `docs/spotify-app-setup.md`**

Replace its contents with a user guide: why library features need the user's own app (five-user cap, link to [Quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)); the four steps from Library Access with the exact redirect URI `http://127.0.0.1:8898/callback`, including adding your own account under User Management (Quota modes: "Each Spotify user who installs your app will need to be added to your app's allowlist"; unlisted users get 403, which Bopify shows as the favorites "forbidden" notice); that playback uses librespot's client ID and needs no setup; that library consent must be renewed every six months ([Refresh token expiration](https://developer.spotify.com/blog/2026-06-18-refresh-token-expiration)). Remove the owner's client ID.

- [ ] **Step 8: Verify**

```sh
rg -n dashboardLibraryClientID .            # expected: no matches outside docs/superpowers/{plans,specs}
swift test --package-path Packages/BopifyCore
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-byo-build build
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-byo-build --output /private/tmp/bopify-byo-library --probe library
```

Expected: tests pass, build succeeds, library probe passes.

Manual check (the user runs the app): with `defaults delete com.leesiongchan.bopify library.clientID` (sandbox container domain; or a fresh user account), Liked Songs shows "Enable Liked Songs"; clicking it opens Library Access, not a browser; status menu shows "Library Access…"; pasting a valid ID and Save closes the window and opens Spotify consent naming the user's own app; Liked Songs loads. Sign out and back in: Library Access still shows the ID; Liked Songs asks to enable again.

- [ ] **Step 9: Commit**

```bash
git add Bopify/Bopify/AppEnvironment.swift Bopify/Bopify/MenuBar/LibrarySetupWindowController.swift Bopify/Bopify/Views/LibrarySetupView.swift Bopify/Bopify/MenuBar/StatusItemController.swift Bopify/Bopify/Localizable.xcstrings docs/superpowers/verification/MonolithLiveLibraryProbe.swift docs/spotify-app-setup.md
git commit -m "Let each user supply their own Spotify client for library access"
```

New files under `Bopify/Bopify/` are picked up by the project's file-system synchronized group; if the build reports them missing, check the target membership in Xcode.
