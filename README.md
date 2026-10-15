# Bopify

A native Spotify player that lives in the macOS menu bar.

Bopify plays audio on your Mac itself, using [librespot](https://github.com/librespot-org/librespot). It does not remote-control the official Spotify app, so you don't need that app running.

## Download

Release packages use `Bopify-<version>.dmg` on [GitHub Releases](https://github.com/leesiongchan/bopify/releases/latest). Drag Bopify to Applications. Current packages are ad-hoc signed and are not notarized by Apple. If macOS blocks opening the app and you trust this download, try opening it once, then choose **System Settings → Privacy & Security → Open Anyway**. See [Apple’s instructions](https://support.apple.com/en-us/102445).

Bopify combines public library setup with the audio/authentication fixes and reviewed release pipeline. Clean-Mac installation and live acceptance are still pending; see [the integration verification record](docs/superpowers/verification/2026-10-13-public-distribution-integration.md). No release has been published from this work yet.

You need an Apple Silicon Mac on macOS 26 or later, and a Spotify **Premium** account (librespot only works with Premium). Bopify has no Dock icon or app menu: look for it in the menu bar, and right-click it to quit.

## Library features

Playback works as soon as you sign in. Favorites, Liked Songs and listening history are different: they use the Spotify Web API, which needs a free Spotify app that you register yourself. Choose **Library Access…** from the status menu (right-click the menu bar icon) and paste in your Client ID. [The setup guide](docs/spotify-app-setup.md) walks through it in a few minutes.

## Build from source

You only need this to work on Bopify. Besides macOS 26 or later and Premium, you need:

- Rust 1.99+ (rustup uses the pinned 1.99.0 toolchain)
- Xcode 27 with the Metal Toolchain:
  `xcodebuild -downloadComponent MetalToolchain`

Build the Rust library first. Everything else links against it, and its output (`artifacts/`) isn't checked in.

```sh
./scripts/build-rust.sh
```

Then build the app:

```sh
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify \
  -destination 'platform=macOS,arch=arm64' build
```

## Test

The Swift packages (`Packages/BopifyCore`):

```sh
cd Packages/BopifyCore
swift test
```

The wrapper and patched librespot unit tests and doctests (run from the repository root):

```sh
./scripts/test-native.sh
```

Headless app boundary checks also compile the Debug app without signing or launching it, then exercise logout and artwork with synthetic stores and HTTP responses:

```sh
python3 scripts/test-app-boundaries.py
```

Both commands are release CI gates before packaging. It prepares the pinned librespot sources, sets the macOS 26 deployment target, and uses locked dependencies. Connect and playback use the shipping lock; core tests require the separate upstream workspace and its lock. Network integration tests and explicitly ignored audio-device tests are excluded. A fresh run may download dependencies; cached local runs can additionally use `CARGO_NET_OFFLINE=true`. If your shell sets `RUSTUP_TOOLCHAIN`, unset it to use the checked-in pin.

## Spotify sign-in and privacy

**Playback uses Spotify's own client ID.** Spotify offers no supported way for third-party apps to stream audio natively: the [Web Playback SDK](https://developer.spotify.com/documentation/web-playback-sdk) only runs in a browser, and the Web API only controls an official client that's already running. So, like librespot, Bopify signs in with librespot's first-party client ID.

What that means for you:

- **The consent screen says "Spotify", not "Bopify".** That's expected, because you're authorizing Spotify's own client ID. It isn't a phishing page.
- **It's outside Spotify's developer terms.** librespot-based apps have worked this way for years without action from Spotify, but tolerated isn't the same as allowed, and it's your account on the line.
- **The likely risk is breakage, not a ban.** Spotify can revoke or change that client ID at any time, and playback stops until Bopify is updated.

Playback sign-in asks for one scope: `streaming`. (librespot's own CLI asks for 26.)

**Library features are opt-in and use your own app.** Bopify ships no client ID for them. Favorites, Liked Songs and listening history use the client ID of a Spotify app you register on the Developer Dashboard (see [the setup guide](docs/spotify-app-setup.md)), and you paste it in only when you turn a feature on. Bopify asks for those scopes (`user-library-read`, `user-library-modify`, `user-read-recently-played`, `user-top-read`) at the same point, and the consent page names your app.

**Nothing leaves your Mac except to Spotify.** Sign-in goes from your browser to a listener on `127.0.0.1`, and tokens are stored in the Keychain. There's no telemetry, and logs stay local in `os_log`.

## Disclaimer

Bopify is an unofficial, free, non-commercial project. It isn't affiliated with or endorsed by Spotify.

It plays audio through librespot, and librespot's own README warns that using it to connect to Spotify is probably forbidden by Spotify. Use Bopify at your own risk. Some newer accounts also can't currently play through librespot at all ([librespot #1649](https://github.com/librespot-org/librespot/issues/1649)).

## Releasing

Current GitHub releases use the free ad-hoc signing route. No Apple Developer Program membership, signing certificate or notarization credentials are needed. From a clean, committed checkout:

```sh
./scripts/release.sh 0.1.0-rc.1 --ad-hoc
```

The final DMG is `build/release/Bopify-<version>.dmg`. The script verifies its signature and the app's arm64 architecture, hardened runtime, sandbox capabilities, version and embedded licenses. It does not notarize the app or establish Gatekeeper approval.

Pushing an approved `v*` tag (for example `v0.1.0-rc.1`) builds the ad-hoc DMG in CI and publishes it to GitHub Releases, with the installation limitation in its release notes. A prerelease suffix marks it as a prerelease. Complete the acceptance checks before publishing; see [the release guide](docs/releasing.md).

The Developer ID/notarized route remains available for later via `./scripts/release.sh <version>` and requires the optional signing setup in that guide.

## License

MIT, see [`LICENSE`](LICENSE). The DMG also includes `LICENSE.txt` and `Third-Party Licenses.html` for the bundled dependencies.
