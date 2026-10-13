# Bopify

A native Spotify player that lives in the macOS menu bar.

Bopify plays audio on your Mac itself, using [librespot](https://github.com/librespot-org/librespot). It does not remote-control the official Spotify app, so you don't need that app running.

## Download

Release packages use `Bopify-<version>.dmg` on [GitHub Releases](https://github.com/leesiongchan/bopify/releases/latest). Open a verified release and drag Bopify to Applications.

This integration branch combines public library setup with the audio/authentication fixes and reviewed release pipeline. Developer ID export, notarization and live acceptance are still pending; see [the integration verification record](docs/superpowers/verification/2026-10-13-public-distribution-integration.md). Build from source to evaluate this revision.

You need an Apple Silicon Mac on macOS 14 or later, and a Spotify **Premium** account (librespot only works with Premium). Bopify has no Dock icon or app menu: look for it in the menu bar, and right-click it to quit.

## Library features

Playback works as soon as you sign in. Favorites, Liked Songs and listening history are different: they use the Spotify Web API, which needs a free Spotify app that you register yourself. Choose **Library Access…** from the status menu (right-click the menu bar icon) and paste in your Client ID. [The setup guide](docs/spotify-app-setup.md) walks through it in a few minutes.

## Build from source

You only need this to work on Bopify. Besides macOS 14 or later and Premium, you need:

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

The Rust crate (`rust/crates/bopify-core`):

```sh
./scripts/prepare-librespot.sh   # once per fresh checkout
cd rust
cargo test
```

`prepare-librespot.sh` checks out the pinned librespot revision into `.build/` and applies our patches to it. It refuses to run over unexpected local changes. `build-rust.sh` already runs it, so you only need it when calling Cargo directly. In that case, also export `MACOSX_DEPLOYMENT_TARGET=14.0` so the Rust output matches the Xcode target.

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

For maintainers. You need, once:

- An active Apple Developer Program membership.
- A **Developer ID Application** certificate (Xcode, Settings, Accounts, Manage Certificates). Creating one requires the [Account Holder role](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).
- An App Store Connect API key with the Developer role (`.p8` file, Key ID, Issuer ID).
- A local notary profile:
  `xcrun notarytool store-credentials bopify-notary --key <path>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>`

Follow [the release setup and acceptance gates](docs/releasing.md), then build a signed, notarized DMG at `build/release/Bopify-<version>.dmg`:

```sh
./scripts/release.sh 0.1.0
```

Pushing a `v*` tag (for example `v0.1.0`) does the same in CI and publishes the DMG to GitHub Releases. A tag with a suffix, like `v0.1.0-rc.1`, is published as a prerelease. CI needs these repository secrets: `DEVELOPER_ID_P12_BASE64` (the certificate exported with its private key as `.p12`, then `base64 -i cert.p12`), `DEVELOPER_ID_P12_PASSWORD`, `KEYCHAIN_PASSWORD`, `NOTARY_KEY_P8`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`.

## License

MIT, see [`LICENSE`](LICENSE). The DMG also includes `LICENSE.txt` and `Third-Party Licenses.html` for the bundled dependencies.
