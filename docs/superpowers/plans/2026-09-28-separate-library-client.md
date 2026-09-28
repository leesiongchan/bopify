# Separate Spotify Library Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Use a Dashboard app's PKCE grant for Web API library traffic while playback continues under librespot's client ID.

**Architecture:** Retain the existing playback auth service and Keychain item. Compose a second `SpotifyAuthService` with a distinct Keychain service and the supplied public Dashboard ID; route the existing shared `SpotifyLibraryClient` through it. Keep the current library cooldown and explicit enable actions.

**Tech Stack:** Swift 6, Swift Testing, AppKit, Keychain, existing Spotify PKCE/loopback flow; macOS 14 minimum.

**Spec:** [2026-09-28-separate-library-client-design.md](../specs/2026-09-28-separate-library-client-design.md), approved by user 2026-09-28.

## Global Constraints

- Do not change the librespot playback client ID, Rust bridge, playback token Keychain service (`my.snsoft.bopify`), or transport behavior.
- Library token service is `my.snsoft.bopify.library`; library OAuth scopes are `user-library-read` and, for favorites, `user-library-modify`. Never request `streaming` for that grant.
- The Dashboard app must register `http://127.0.0.1/login` without a port. The existing listener selects a dynamic port.
- Do not open OAuth without the user invoking an existing Enable action. Quit keeps both grants; sign-out clears both and rejects late results.
- The public Dashboard ID is still awaited. Its absence blocks production wiring and live acceptance; do not substitute the librespot ID or a guessed value.
- Keep the user's staged/unstaged `Localizable.xcstrings` edits on `main` untouched. Work in `.worktrees/separate-library-oauth`.
- Log only authentication state and sanitized HTTP status/retry classification; never credentials, response bodies, or library contents.

## Review Focus

1. Library grant missing while playback grant exists: playback stays connected and an Enable action starts exactly one library PKCE flow (Tasks 1–2).
2. Library consent returns fewer scopes than requested: no token is stored or used for a request (Task 1).
3. Sign-out occurs while a second OAuth browser flow is pending: late callback cannot restore either Keychain item or browsing state (Tasks 1–2).
4. Quit and relaunch: both tokens persist, and the library grant is restored lazily without reopening the browser (Task 2).
5. Simultaneous favorite and liked-song requests after one 429: both still obey the existing shared library cooldown (Task 3).

---

## File map and commands

| Area | Files |
| --- | --- |
| Auth boundary | `Packages/BopifyCore/Sources/BopifyAuth/SpotifyAuthService.swift`; `Packages/BopifyCore/Tests/AuthTests/SpotifyAuthServiceTests.swift`, `TokenStoreTests.swift` |
| Composition | `Bopify/Bopify/AppEnvironment.swift`; `docs/superpowers/verification/MonolithLibraryProbe.swift`; app build |
| Production identity | A named public client ID constant in `Bopify/Bopify/AppEnvironment.swift` after the user supplies it; no secret in the repository |
| Acceptance | `docs/superpowers/verification/MonolithLiveLibraryProbe.swift`, this plan's verification report, existing native refinement/mirror probes |

Run from this worktree:

```sh
swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-library-identity-tests
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-library-identity-build build
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-library-identity-build --output /private/tmp/bopify-library-identity-composition --probe library
```

Native probes run sequentially. A live probe must make only one read-only request and print only an outcome category.

### Task 1: Authorize a second grant without streaming

**Interfaces:** Keep `SpotifyAuthService.signIn()`, `authorizeAdditionalScopes(_:)`, `validAccessToken(requiredScopes:)`, and `signOut()` unchanged for playback callers. Add `public func authorizeLibraryScopes(_ scopes: Set<String>) async throws -> TokenSet`; it unions the requested library scopes with any stored library grant, then uses existing private PKCE authorization with scope validation. The caller constructs `SpotifyAuthService(clientID: dashboardID, store: KeychainTokenStore(service: "my.snsoft.bopify.library"))`.

- [ ] **1. Write failing auth tests.** `libraryConsentStartsWithoutPlaybackGrant` records the browser URL and asserts Dashboard `client_id`, scopes exactly `user-library-read`, `/login`, and no `streaming`. `libraryConsentWidensExistingGrant` asserts read+modify union. `libraryConsentRejectsMissingScopes` confirms no token replacement. `libraryConsentCancelledBySignOut` confirms late OAuth result is discarded. `separateKeychainServicesDoNotOverwriteEachOther` saves and loads two token sets, then clears one and checks the other.
- [ ] **2. Run RED:** `swift test ... --filter SpotifyAuthServiceTests` and `--filter TokenStoreTests`; require the missing entry point / behavior to fail.
- [ ] **3. Implement the auth entry point** in `SpotifyAuthService.swift` with the exact signature above, no new OAuth client. Reuse the existing PKCE state, listener and token exchange; do not call `signIn()` because it requests `streaming`.
- [ ] **4. Run GREEN:** both filtered test suites pass. Commit `Authorize library scopes under a separate Spotify grant`.

### Task 2: Route library requests through the Dashboard session

**Interfaces:** `AppEnvironment` owns `auth` for playback and `libraryAuth` for library. Its one `SpotifyLibraryClient` uses `libraryAuth.validAccessToken(requiredScopes:)`; `authorizeLibraryScopes` closure invokes `libraryAuth.authorizeLibraryScopes(_:)`. `signOut()` clears both services; `prepareForQuit()` clears neither. Add the supplied Dashboard ID as a named public constant, then instantiate the second service with a distinct Keychain service.

- [ ] **1. Write failing composition assertions** in `MonolithLibraryProbe`: playback remains active when library scope is missing or consent fails; one Enable invocation uses the library auth boundary; read-only consent does not grant write; sign-out clears library state and both stores; quit preserves restored grants; a late result after sign-out cannot restore browsing. Keep current fixture's shared cooldown and favorite revision behavior.
- [ ] **2. Run RED:** build and `--probe library` with existing isolated services; assert the new boundary before changing production wiring.
- [ ] **3. Wire the second service** in `AppEnvironment.swift`. Await the user's public Dashboard ID before adding the production constant. Restore its Keychain item only on library token request; never automatically open the consent browser. Keep the existing enable actions and generation guards.
- [ ] **4. Run GREEN:** full package suite, build, `--probe library`; confirm the playback auth path still uses librespot's ID. Commit `Use the Dashboard identity for Spotify library access`.

### Task 3: Verify native and live boundaries

**Interfaces:** Production library requests remain on the existing `SpotifyLibraryClient`, preserving fixed-origin requests, redirect rejection, scope checks and shared 429 cooldown. Native fixtures use stub services; live checks use the configured library auth service and one read-only saved-track page.

- [ ] **1. Add a focused request test** showing the library token provider receives `user-library-read` or `user-library-modify` as appropriate while the playback token provider is untouched. Run RED and GREEN around any needed wiring correction.
- [ ] **2. Run** full Swift suite, app build, `--probe library`, native `--probe refinement`, and `--probe mirror` sequentially; inspect results. Run `git diff --check`.
- [ ] **3. After Dashboard callback registration and user-initiated consent**, run one `--probe live-library` request. Record status and sanitized 429 reason/Retry-After if present; do not claim live success if consent or account configuration is absent.
- [ ] **4. Update the verification report** with tested behavior, callback/ID setup, and any live limits. Review the full diff for token mixing, unintended browser opens, and changes to the user's localization edit. Commit `Verify separate library OAuth and playback isolation`.

## Execution handoff

Use Native execution for this plan: the three tasks share the same auth and AppEnvironment interfaces, and the existing native fixtures can verify integration. Request one independent whole-branch review after implementation. The Dashboard client ID and plan approval are the remaining handoff inputs; retain this worktree and the user's main-worktree edits until the feature is verified.
