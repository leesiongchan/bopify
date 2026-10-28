# Bopify

A native Spotify player for the macOS menu bar. Plays audio directly through
[librespot](https://github.com/librespot-org/librespot), without the Spotify app.

Requires an Apple Silicon Mac, macOS 26 or later, and Spotify Premium.
Playback prefers 320 kbps when available, falling back to formats offered for each track.

## Install

Download `Bopify-<version>.dmg` from [GitHub Releases](https://github.com/leesiongchan/bopify/releases),
drag Bopify to Applications, then open it and complete Spotify setup. Right-click the menu bar
icon for settings or to quit.

Use the magnifying glass or **Command-F** to search Spotify songs, albums, artists, and playlists
in one list, ranked by closest title or name match using [FuzzyMatch](https://github.com/ordo-one/FuzzyMatch).
Ranking tolerates typos and differences in case, accents, and character width. Subtle icons identify each result type.
Choose a result or use the arrow keys and Return to play it immediately; Escape closes search.
Scroll through search results to load further matches automatically.
Your query and results remain when search closes. Use the clear button to reset them.
Paste a Spotify song, album, artist, or playlist URL into search to find that exact item.
Spotify URIs (`spotify:track:…`), localized web URLs, and sharing parameters are supported.
Pasting selects the item without interrupting playback; press Return or click it to play.
Short links such as `spotify.link` and `spoti.fi` are not supported yet; use the item's
`open.spotify.com` URL from Spotify's web player instead.
The **Library** tab shows your saved playlists, albums, and followed artists together.
Click a cover to play that collection.

Right-click the menu bar icon and choose **Keyboard Shortcuts**, or press **Command-/**
while the player is focused, to see the keyboard reference and configure shortcuts that
work from any app. The player and search shortcuts start unassigned; lyrics defaults
to **Control–Option–L**. The player shortcut shows or hides Bopify; the search shortcut
reveals the player and focuses search, keeping your previous query and results.

The record shows **Drag to seek** until your first drag, then keeps that hint hidden.
While dragging around the record, a timestamp shows the destination; release to seek,
or press Escape to cancel.

Builds are ad-hoc signed and not notarized. If macOS blocks the app and you trust
the download, use **System Settings → Privacy & Security → Open Anyway** after
trying to open it. See [Apple’s instructions](https://support.apple.com/en-us/102445).

## Library setup

Setup requires Spotify playback sign-in and your own Spotify Web API app.
Approve access for Favorites, Liked Songs, listening history and Library together
before entering the player. Search uses the same library connection.

1. Create an app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
2. Select **Web API** and add the redirect URI `http://127.0.0.1:8898/callback`.
3. Save, then add your Spotify account under **User Management** ([Spotify’s allowlist instructions](https://developer.spotify.com/documentation/web-api/concepts/quota-modes#adding-a-user-to-your-apps-allowlist)).
4. In Bopify, choose **Continue setup**, paste the **Client ID**, then choose
   **Save and authorize**. Approve all requested Spotify access to finish setup.

Existing installations with partial library access return to setup once to approve
the complete set. Complete grants restore without repeated feature authorization.
If Spotify access expires or is revoked, Bopify returns to setup to reconnect.
Use **Library Access…** in the menu bar menu to change your Client ID.

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
and choose **Focus Lyrics** for keyboard reading; Escape hides the player.

Lyrics appear below CoverFlow inside the player, separated by a subtle divider.
When the player loses attention, it folds down to the lyric section with a small
vinyl in its header. Click that vinyl to reveal the full player, or drag it to move
the player. The title and artist move into the lyric header on collapse. Hovering,
scrolling, or selecting lyrics keeps it compact. The provider credit sits quietly
at the bottom-left; the glass **Sync** icon floats at the bottom-right while reading.
The compact lyrics stay above other windows.
In lyrics-only mode, swipe left to skip to the next track or right for the previous
track. Vertical scrolling continues to browse the lyrics.

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
