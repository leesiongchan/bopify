# Bopify

A native Spotify player that lives in the macOS menu bar.

Bopify plays audio on your Mac itself, using [librespot](https://github.com/librespot-org/librespot). It does not remote-control the official Spotify app, so you don't need that app running.

It's a personal tool: built from source, for one account, and not distributed.

## What you need

- macOS 14 or later
- A Spotify **Premium** account (librespot only works with Premium)
- Rust 1.85+
- Xcode 27 with the Metal Toolchain:
  `xcodebuild -downloadComponent MetalToolchain`

## Build

Build the Rust library first. Everything else links against it, and its output (`artifacts/`) isn't checked in.

```sh
./scripts/build-rust.sh
```

Then build the app:

```sh
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify \
  -destination 'platform=macOS,arch=arm64' build
```

Bopify has no Dock icon or app menu. Look for it in the menu bar, and right-click it to quit.

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

**Library features are opt-in and separate.** Favorites, Liked Songs and listening history use a different client ID registered on the Spotify Developer Dashboard. Bopify only asks for those scopes (`user-library-read`, `user-library-modify`, `user-read-recently-played`, `user-top-read`) when you turn the feature on.

**Nothing leaves your Mac except to Spotify.** Sign-in goes from your browser to a listener on `127.0.0.1`, and tokens are stored in the Keychain. There's no telemetry, and logs stay local in `os_log`.
