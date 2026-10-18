# Bopify

A native Spotify player for the macOS menu bar. Plays audio directly through
[librespot](https://github.com/librespot-org/librespot), without the Spotify app.

Requires an Apple Silicon Mac, macOS 26 or later, and Spotify Premium.

## Install

Download `Bopify-<version>.dmg` from [GitHub Releases](https://github.com/leesiongchan/bopify/releases),
drag Bopify to Applications, then open it and sign in. Right-click the menu bar
icon for settings or to quit.

Use the magnifying glass or **Command-F** to search Spotify songs. Choose a
result or use the arrow keys and Return to play it; Escape closes search.
The **Library** tab shows your saved playlist and album covers. Choose
**Playlists** or **Albums**, then click a cover to play that collection.

Builds are ad-hoc signed and not notarized. If macOS blocks the app and you trust
the download, use **System Settings → Privacy & Security → Open Anyway** after
trying to open it. See [Apple’s instructions](https://support.apple.com/en-us/102445).

## Library setup

Playback needs no developer setup. Favorites, Liked Songs, listening history,
Library and search require your own Spotify Web API app:

1. Create an app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
2. Select **Web API** and add the redirect URI `http://127.0.0.1:8898/callback`.
3. Save, then add your Spotify account under **User Management** ([Spotify’s allowlist instructions](https://developer.spotify.com/documentation/web-api/concepts/quota-modes#adding-a-user-to-your-apps-allowlist)).
4. In Bopify, right-click the menu bar icon → **Library Access…**. Paste the
   **Client ID**, save, then click **Enable** on a library feature or search to authorize it.

If Spotify reports `INVALID_CLIENT`, check the Client ID and redirect URI. Bopify
does not need your Client secret. Sign-in credentials are stored in macOS Keychain.

## Build

Install Xcode 27 and Rust through [rustup](https://rustup.rs/). The repository pins
Rust 1.99.0. Run these commands from the repository root:

```sh
xcodebuild -downloadComponent MetalToolchain
./scripts/build-rust.sh
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
```

## Test

Show or hide lyrics with the **Lyrics** control before Playlist or
**Control–Option–L**. Scroll to read manually; **Sync** returns to the current
cue. Click timed words to seek to that line. Right-click the Lyrics control
and choose **Focus Lyrics** for keyboard reading; Escape hides the focused ribbon.

### Lyric ribbon development preview

The native lyric ribbon study is available only in Debug builds. It uses
original sample words and a simulated clock, with no sign-in or Spotify connection.

```sh
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/lyric-ribbon-study CODE_SIGNING_ALLOWED=NO build
open -n build/lyric-ribbon-study/Build/Products/Debug/Bopify.app \
  --args --lyric-ribbon-preview
```

Use the study window to change samples, advance or pause the clock and enter
explicit keyboard interaction with **Focus Ribbon**. Scroll to browse the full
sample, then use **Sync** to follow again. Previous/next sample controls
exercise the record and song transitions.

### Test suites

Build the Rust library first, then run from the repository root:

```sh
./scripts/test-native.sh
swift test --package-path Packages/BopifyCore
xcodebuild -project Bopify/Bopify.xcodeproj -scheme BopifyAppTests \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```

The Debug app test scheme runs without an app host. Authentication and artwork
tests use injected services and local network fixtures.
Every push to `main` runs these checks and verifies the mounted DMG and a copied
installation before uploading it for publication. These checks do not exercise
live Spotify sign-in, audio hardware, or Gatekeeper acceptance.

## Release

This is a solo project: commit and push directly to `main`. Every push builds a
DMG and publishes a GitHub Release. Use Conventional Commit messages: `feat:`
bumps minor, `feat!:` or a `BREAKING CHANGE:` footer bumps major, and other commits
bump patch. Tags and release notes are automatic.

To package locally from a clean, committed checkout:

```sh
./scripts/release.sh 0.1.0
```

Output: `build/release/Bopify-0.1.0.dmg`. No Apple signing credentials are required.
If publication fails, rerun the failed job in GitHub Actions; rerun the entire
workflow if its retained build artifact has expired.

## License

[MIT](LICENSE). Dependency licenses are included in the app and DMG.
Bopify is unofficial and is not affiliated with Spotify. Playback depends on
librespot and may break if Spotify changes its service.
