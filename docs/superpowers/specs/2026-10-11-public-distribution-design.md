# Public distribution

Status: design for review, 2026-10-11. User decisions (2026-10-11): library access uses a bring-your-own Spotify client ID; arm64-only; free and non-commercial; MIT license; release pipeline is a local release script plus GitHub Actions. Sparkle auto-updates and a Homebrew tap are out of scope.

## Problem and outcome

Bopify is built from source for one account. Anyone should be able to download a notarized `Bopify-<version>.dmg` from GitHub Releases, open it without Gatekeeper warnings, sign in, and play. Library features (Favorites, Liked Songs, Recents, Explore) work once the user supplies their own Spotify Developer Dashboard client ID; without one, playback works and the library shows a setup action.

## Library access: bring your own client ID

The hard-coded `dashboardLibraryClientID` is the owner's Development Mode app. Since February 2026 such an app serves at most 5 manually allowlisted users, and extended quota requires an organization with at least 250k monthly active users ([Quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes); [Update on Developer Access, 2026-02-06](https://developer.spotify.com/blog/2026-02-06-update-on-developer-access-and-platform-security)). Calling the Web API with the librespot playback token has returned 429 for every request since about 2025-12-22 ([ncspot commit 6769b7b](https://github.com/hrkfdn/ncspot/commit/6769b7b)), so a separate ID remains necessary. psst moved to the same bring-your-own model in 2026 ([psst README](https://github.com/jpochyla/psst)).

- The user registers a Dashboard app with redirect URI `http://127.0.0.1:8898/callback` (the fixed callback the library auth already uses), adds their own account under User Management (Development Mode blocks unlisted users with 403, owner included), and enters its client ID in a Library Access window, reachable from the status item menu and from every library Enable action when no ID is set.
- The ID is public, not a secret; it is stored in `UserDefaults` under `library.clientID`. Input is trimmed and lowercased, and must be 32 hex characters.
- Changing the ID clears the library Keychain item (`com.leesiongchan.bopify.library`), because tokens are bound to the client that issued them, and clears library browsing state. Playback is unaffected.
- With no ID, library token requests fail with `LibraryError.authorizationRequired`, which the UI already turns into an Enable action; that action opens Library Access instead of a browser.
- Sign-out clears the library token but keeps the ID. Quit keeps both.
- Refresh tokens now expire six months after the original consent ([Refresh token expiration, 2026-06-18](https://developer.spotify.com/blog/2026-06-18-refresh-token-expiration)). The existing mapping (`invalid_grant` → `PlayerError.authExpired` → `LibraryError.authorizationRequired`) already re-surfaces the Enable action; no change needed.

## Playback client ID

Playback keeps librespot's first-party client ID. There is no sanctioned alternative on macOS; every open-source librespot client ships it. The README states the risk plainly, the app stays free and non-commercial (Spotify Developer Policy IV.2: [policy](https://developer.spotify.com/policy)), and Bopify does not cache audio.

## Release pipeline

- Release configuration signs manually with **Developer ID Application**, hardened runtime on ([Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)). Debug keeps automatic Apple Development signing.
- `ARCHS = arm64`. With a 14.0 deployment target Xcode 27 otherwise builds `arm64 x86_64` in Release ([Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)), and the Rust library is arm64-only.
- `scripts/release.sh <version>`: build Rust, archive, export (`method = developer-id`), stage the app with an `/Applications` link and third-party notices, `hdiutil` UDZO DMG, sign the DMG, notarize with `notarytool` (keychain profile locally, App Store Connect API key in CI), staple, and verify with `spctl`. Only the outer DMG is submitted; Apple notarizes nested content ([Packaging Mac software](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)).
- `.github/workflows/release.yml`: on a `v*` tag, on the `xcode-27` runner image (preview, [runner-images #14404](https://github.com/actions/runner-images/issues/14404)), import the certificate into a temporary keychain ([GitHub Docs](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)), run the release script, and `gh release create`.

## Open-source groundwork

- `LICENSE`: MIT.
- Third-party notices for the Rust dependency tree are generated at release time with cargo-about 0.9.2 and shipped in the DMG as `Third-Party Licenses.html`. The Swift package has no external dependencies.
- README: download and first-run steps, Library Access setup, and a disclaimer modeled on librespot's.

## Known limits

- librespot issue [#1649](https://github.com/librespot-org/librespot/issues/1649) (audio key errors on some newer accounts) is open; affected users cannot play. A dedicated error message needs a reproducing account and is a follow-up, not part of this work.
- Existing installs signed with Apple Development will see one Keychain access prompt after switching to the Developer ID build ([TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)).

## Verification

1. Package tests: client ID validation and storage, setting/replacing an ID clears the library token, missing ID yields `authorizationRequired`.
2. App build plus the existing library composition probe stay green.
3. Manual: with no ID, Liked Songs shows the setup action; Library Access opens; after entering a valid ID, Enable opens Spotify consent naming the user's app; Liked Songs loads.
4. `scripts/release.sh` produces a DMG that `spctl` reports as `source=Notarized Developer ID`, whose app is arm64-only with the hardened-runtime flag, and which opens on a second Mac without warnings.
5. A pushed `v*` tag produces a GitHub Release with the DMG attached.
