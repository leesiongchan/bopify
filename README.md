# Bopify

A native macOS menu-bar Spotify player. Bopify plays audio locally on the
Mac via librespot — it is not a remote control for the official Spotify
app.

## Requirements

- Rust 1.85+
- Xcode 27
- `MACOSX_DEPLOYMENT_TARGET=14.0`
- A Spotify **Premium** account (librespot is Premium-only)

## Build and test

There is no Xcode app target yet; what exists today is the Swift package
and the Rust crate that will back it.

Swift package (`Packages/BopifyCore`: `BopifyDomain`, `BopifyAuth`,
`BopifyPlayback`):

```sh
cd Packages/BopifyCore
swift build
swift test
```

Rust crate (`rust/crates/bopify-core`, the librespot integration):

```sh
cd rust
cargo build
cargo test
```

## Spotify client ID

Bopify authenticates with librespot's first-party Spotify client ID, not
one registered on the Spotify Developer Dashboard. Spotify gives third
parties no way to stream audio natively: the [Web Playback
SDK](https://developer.spotify.com/documentation/web-playback-sdk) only
runs in a browser, and the Web API only remote-controls an already-running
official client. There is no supported path to local playback.

This sits outside Spotify's developer terms, which expect an app to use
its own registered client ID. librespot and the projects built on it have
operated this way for years without Spotify acting against them, but
tolerated is not authorised, and it is the user's own Spotify account at
stake, not this app's.

The realistic failure mode is breakage, not a ban: Spotify can revoke or
change this client ID at any time, and Bopify stops working until it is
updated.

The scope requested is minimal: `streaming`, and nothing else. Bopify
cannot read your library, playlists, or email. librespot's own CLI
requests 26 scopes (`OAUTH_SCOPES` in `main.rs` at pinned revision
`939dc5e`); this app requests one.

No telemetry. The OAuth token flows browser -> a loopback listener on
`127.0.0.1` -> Keychain, and never reaches any third party; the only
network counterparty is Spotify itself, for authentication and for the
audio stream. Logging is local `os_log` only.

The consent screen shows **Spotify**, not Bopify, because the client ID
being authorized is Spotify's own. That is expected — it is not a
phishing screen.

Bopify is not distributed. It is a personal tool, built from source, for
one account.
