# Bopify Foundation and First Slice — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a macOS menu-bar app where signing in with Spotify results in music playing from this Mac, with working play/pause, next and previous.

**Architecture:** A Rust staticlib wraps librespot's `Spirc` (which owns queue and transport) and exposes ~11 C functions over an opaque handle, pushing player events to Swift as JSON through a C callback. Swift owns authentication (PKCE, loopback, Keychain) and folds the event stream into observable state on the main actor. A `PlaybackEngine` protocol is the only seam between the UI and librespot, with a stub implementation carrying the entire automated test suite.

**Tech Stack:** Swift 6.4 / Xcode 27, SwiftUI + AppKit (`NSStatusItem` + `NSPanel`), Swift Testing, Rust 1.98 (edition 2024), librespot (`-core`, `-playback`, `-connect`, `-oauth`) pinned to one revision, cbindgen, Network framework, CryptoKit, Security framework.

**Spec:** `docs/superpowers/specs/2026-09-21-bopify-foundation-design.md` — read it before Task 1. This plan argues from it; where they disagree, the spec wins and this plan gets corrected.

## Global Constraints

- **Swift 6 language mode.** `SWIFT_VERSION = 6` in `.xcconfig`; `swiftLanguageMode(.v6)` in `Package.swift`. Xcode 27's template ships `5.0` — do not accept the default.
- **`MACOSX_DEPLOYMENT_TARGET = 14.0`**, set identically for Xcode *and* cargo. rustc defaults differ per arch and a mismatch produces link warnings that escalate.
- **arm64 only.** No `lipo`, no universal binary. One commented line in `scripts/build-rust.sh` documents how to restore it.
- **librespot is pinned to one git revision**, recorded in `rust/Cargo.toml`. Never depend on the crates.io release. There is no stable API: if a signature in this plan differs from the pinned source, **the source wins** — fix the code, then fix this plan.
- **OAuth scopes: `["streaming"]` and nothing else.**
- **Redirect URI: registered as `http://127.0.0.1/callback` with no port.** At runtime the listener binds a dynamic port and the full URI including that port is sent in the authorization request. `localhost` is rejected by Spotify.
- **`defaultLocalization: "en"`** in `Package.swift`; every user-visible string lives in `App/Localizable.xcstrings`. No user-facing string literals in Swift files.
- **Commit messages:** imperative subject under 72 characters, body explains *why*. **No `Co-Authored-By` trailer** — `AGENTS.md` §6 forbids it.
- **Every task ends green.** `swift test` and `cargo test` both pass before any commit that touches their tree.

---

## File Structure

**Rust (`rust/`)** — one crate, one responsibility per module.

| File | Responsibility |
|---|---|
| `Cargo.toml` | Workspace; pins the librespot revision |
| `crates/bopify-core/Cargo.toml` | Crate manifest; `crate-type = ["staticlib"]` |
| `crates/bopify-core/src/lib.rs` | Module wiring only |
| `crates/bopify-core/src/error.rs` | `BopifyError` → stable `i32` codes |
| `crates/bopify-core/src/event.rs` | `PlayerEvent` → the JSON wire format |
| `crates/bopify-core/src/engine.rs` | Owns the tokio runtime thread, `Session`, `Player`, `Spirc` |
| `crates/bopify-core/src/ffi.rs` | `extern "C"` surface; the only `unsafe` in the crate |
| `crates/bopify-core/src/bin/spike.rs` | Throwaway probe (Task 2); deleted in Task 4 |

**Swift package (`Packages/BopifyCore/`)** — three targets; `BopifyDomain` has zero dependencies.

| File | Responsibility |
|---|---|
| `Sources/BopifyDomain/SpotifyURI.swift` | Validated URI value type |
| `Sources/BopifyDomain/Track.swift` | `Track`, `ArtistSummary`, `Artwork` |
| `Sources/BopifyDomain/PlaybackState.swift` | `PlaybackState`, `PlaybackPhase` |
| `Sources/BopifyDomain/PlaybackEvent.swift` | Wire-format event enum |
| `Sources/BopifyDomain/PlaybackEngine.swift` | The seam |
| `Sources/BopifyDomain/PlayerError.swift` | Error taxonomy |
| `Sources/BopifyDomain/AuthModels.swift` | `AuthState`, `AuthSession`, `TokenSet` |
| `Sources/BopifyAuth/PKCE.swift` | Verifier/challenge derivation |
| `Sources/BopifyAuth/AuthorizationRequest.swift` | Authorization URL construction |
| `Sources/BopifyAuth/LoopbackCallbackListener.swift` | Dynamic-port HTTP listener |
| `Sources/BopifyAuth/TokenClient.swift` | Code exchange and refresh |
| `Sources/BopifyAuth/TokenStore.swift` | Keychain persistence |
| `Sources/BopifyAuth/SpotifyAuthService.swift` | Assembles the flow |
| `Sources/BopifyPlayback/EventBridge.swift` | C callback → `AsyncStream` |
| `Sources/BopifyPlayback/StubPlaybackEngine.swift` | Scriptable test engine |
| `Sources/BopifyPlayback/LibrespotEngine.swift` | Real engine over the FFI |
| `Sources/BopifyPlayback/PlayerModel.swift` | `@MainActor @Observable` facade |
| `Sources/CBopifyCore/` | `binaryTarget` wrapper + linker settings |

**App target (`App/`)** — views live here so `Text("key")` resolves against the main bundle.

| File | Responsibility |
|---|---|
| `BopifyApp.swift` | `@main`, `LSUIElement` |
| `AppEnvironment.swift` | Composition root — the only place concrete types are chosen |
| `MenuBar/StatusItemController.swift` | `NSStatusItem` lifecycle |
| `MenuBar/StatusPanel.swift` | Non-activating `NSPanel` hosting SwiftUI |
| `Views/MiniPlayerView.swift` | Root player surface |
| `Views/SignedOutView.swift` | Sign-in and auth states |
| `Views/TransportControls.swift` | Play/pause, next, previous |
| `Views/ArtworkView.swift` | Artwork with placeholder |

---

### Task 1: Repository scaffolding and a Rust workspace that builds librespot

Nothing else can proceed until librespot compiles on this machine. librespot's CI covers only Linux and Windows, so this is unproven ground, not a formality.

**Files:**
- Create: `.gitignore`
- Create: `rust/Cargo.toml`
- Create: `rust/crates/bopify-core/Cargo.toml`
- Create: `rust/crates/bopify-core/src/lib.rs`
- Create: `docs/spotify-app-setup.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a buildable `bopify-core` staticlib crate; the pinned librespot revision recorded in `rust/Cargo.toml`.

- [ ] **Step 1: Register the Spotify application (manual, blocks everything)**

Go to https://developer.spotify.com/dashboard and create an app.

- Redirect URI: `http://127.0.0.1/callback` — **no port number.** Loopback IP literals are the one exception to Spotify's exact-match rule and may take a dynamically assigned port. Registering with a port would pin us to it.
- After creation, open Settings → User Management and **add your own Spotify account**. The app owner is not implicitly allowlisted.
- Confirm that account has Spotify Premium. librespot supports Premium only, permanently.
- Copy the Client ID.

Record it (the Client ID is not a secret; PKCE exists precisely so no secret is needed):

```bash
mkdir -p docs
cat > docs/spotify-app-setup.md <<'EOF'
# Spotify application setup

- Client ID: `<paste-your-client-id>`
- Redirect URI registered: `http://127.0.0.1/callback` (no port — loopback
  literals may use a dynamically assigned port)
- Scopes requested: `streaming`
- Quota: Development Mode. Hard ceiling of 5 allowlisted users; the owner
  must be added explicitly under Settings -> User Management.
- The account must have Spotify Premium. librespot is Premium-only.
EOF
```

- [ ] **Step 2: Add `.gitignore`**

```bash
cat > .gitignore <<'EOF'
.DS_Store
rust/target/
artifacts/
*.xcframework
.build/
.swiftpm/
xcuserdata/
*.xcuserstate
EOF
```

- [ ] **Step 3: Create the Rust workspace pinning librespot**

Resolve the current `dev` head first — 0.8.0 is ten months old and has a reported `vergen-lib` conflict:

```bash
git ls-remote https://github.com/librespot-org/librespot.git dev
```

Take the SHA from that output and substitute it for `<REV>` below.

```bash
mkdir -p rust/crates/bopify-core/src
cat > rust/Cargo.toml <<'EOF'
[workspace]
members = ["crates/bopify-core"]
resolver = "3"

[workspace.package]
edition = "2024"
rust-version = "1.85"

# Pinned deliberately: librespot has no stable released API. Upgrading is
# a decision, not a side effect of a build.
[workspace.dependencies]
librespot-core = { git = "https://github.com/librespot-org/librespot.git", rev = "<REV>" }
librespot-playback = { git = "https://github.com/librespot-org/librespot.git", rev = "<REV>" }
librespot-connect = { git = "https://github.com/librespot-org/librespot.git", rev = "<REV>" }
librespot-metadata = { git = "https://github.com/librespot-org/librespot.git", rev = "<REV>" }
librespot-oauth = { git = "https://github.com/librespot-org/librespot.git", rev = "<REV>" }
EOF
```

- [ ] **Step 4: Create the crate manifest**

`rodio` is librespot-playback's default backend and needs no Homebrew packages on macOS; it reaches CoreAudio through cpal.

```bash
cat > rust/crates/bopify-core/Cargo.toml <<'EOF'
[package]
name = "bopify-core"
version = "0.1.0"
edition.workspace = true
rust-version.workspace = true

[lib]
crate-type = ["staticlib", "rlib"]

[dependencies]
librespot-core.workspace = true
librespot-connect.workspace = true
librespot-metadata.workspace = true
librespot-oauth.workspace = true
librespot-playback = { workspace = true, features = ["rodio-backend"] }
tokio = { version = "1", features = ["rt-multi-thread", "sync", "macros"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
EOF

cat > rust/crates/bopify-core/src/lib.rs <<'EOF'
//! C-ABI wrapper around librespot's Spirc for the Bopify macOS app.
EOF
```

- [ ] **Step 5: Build, and record the deployment target**

```bash
cd rust && MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --release
```

Expected: compiles. Budget several minutes for a cold build.

If it fails, work the error before continuing — this is the risk the task exists to retire. Two known shapes: a `vergen-lib` version conflict (use a newer `dev` revision) and a missing audio dependency (confirm `rodio-backend` is the enabled feature and no `alsa`/`pulseaudio` feature leaked in).

- [ ] **Step 6: Commit**

```bash
cd /Users/leesiongchan/Projects/bopify
git add .gitignore rust docs/spotify-app-setup.md
git commit -m "Add Rust workspace with librespot pinned to a revision" -m "librespot has no stable released API and its CI covers only Linux and
Windows, so the revision is pinned explicitly and the macOS build is
verified here before any other work depends on it."
```

---

### Task 2: Spike — prove Spirc plays audio and answer Q1 and Q5

A throwaway probe. Its output is findings, not code; the binary is deleted in Task 4. It answers two questions from spec §10 that change what later tasks must build.

**Files:**
- Create: `rust/crates/bopify-core/src/bin/spike.rs`
- Modify: `rust/crates/bopify-core/Cargo.toml` (add `[[bin]]`)
- Create: `docs/superpowers/specs/2026-09-21-spike-findings.md`

**Interfaces:**
- Consumes: the pinned librespot crates from Task 1.
- Produces: answers to Q1 (does `TrackChanged` carry title/artist/artwork?) and Q5 (does a token-authenticated device appear for Connect handoff?), recorded in the findings file. Task 6 and Task 14 depend on those answers.

- [ ] **Step 1: Declare the spike binary**

```bash
cat >> rust/crates/bopify-core/Cargo.toml <<'EOF'

[[bin]]
name = "spike"
path = "src/bin/spike.rs"
EOF
```

- [ ] **Step 2: Write the spike**

This uses `librespot-oauth` for convenience so the probe does not wait on the Swift auth work. Production auth is Swift (spec §2.12) — the spike is the only place `librespot-oauth` is used.

```rust
// rust/crates/bopify-core/src/bin/spike.rs
use std::sync::Arc;

use librespot_connect::{ConnectConfig, Spirc};
use librespot_core::{Session, SessionConfig, authentication::Credentials};
use librespot_oauth::OAuthClientBuilder;
use librespot_playback::{
    audio_backend,
    config::{AudioFormat, PlayerConfig},
    mixer::{Mixer, MixerConfig, softmixer::SoftMixer},
    player::Player,
};

const CLIENT_ID: &str = "<paste-your-client-id>";
const REDIRECT_URI: &str = "http://127.0.0.1:8898/callback";

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // 1. Token. Only `streaming` — the 26-scope bundle in librespot's CLI
    //    (OAUTH_SCOPES in main.rs at pinned revision 939dc5e) mirrors the
    //    Spotify desktop app and is not required here.
    let oauth = OAuthClientBuilder::new(CLIENT_ID, REDIRECT_URI, vec!["streaming"])
        .open_in_browser()
        .build()?;
    let token = oauth.get_access_token_async().await?;
    println!("[spike] token acquired, scopes: {:?}", token.scopes);

    // 2. Session. Do NOT connect it here -- Spirc::new does that itself,
    //    and Session's transport OnceLock rejects a second connect with the
    //    misleadingly named SessionError::NotConnected.
    let session = Session::new(SessionConfig::default(), None);
    let credentials = Credentials::with_access_token(token.access_token.clone());

    // 3. Player with the default rodio sink.
    let mixer = Arc::new(SoftMixer::open(MixerConfig::default()));
    let backend = audio_backend::find(None).ok_or("no audio backend")?;
    let player = Player::new(
        PlayerConfig::default(),
        session.clone(),
        mixer.get_soft_volume(),
        move || backend(None, AudioFormat::default()),
    );

    // 4. Log every event. Q1 is answered by reading this output: does the
    //    track-changed event carry title/artist/artwork, or only an id?
    let mut events = player.get_player_event_channel();
    tokio::spawn(async move {
        while let Some(event) = events.recv().await {
            println!("[spike][event] {event:?}");
        }
    });

    // 5. Spirc owns queue and transport.
    let (spirc, task) = Spirc::new(
        ConnectConfig { name: "Bopify Spike".to_string(), ..Default::default() },
        session.clone(),
        credentials,
        player,
        mixer,
    )
    .await?;

    spirc.activate()?;
    println!("[spike] activated. Open Spotify on your phone or the web player");
    println!("[spike] and look for a device named 'Bopify Spike'.");

    // 6. Drive the event loop. Without awaiting this future nothing runs.
    task.await;
    Ok(())
}
```

- [ ] **Step 3: Run it and answer Q5**

```bash
cd rust && MACOSX_DEPLOYMENT_TARGET=14.0 cargo run --bin spike
```

A browser opens for consent. Then, on your phone or at open.spotify.com, open the device picker and look for **Bopify Spike**.

- **Appears, and selecting it plays audio from the Mac** → Q5 resolved *yes*. Connect handoff is the content-selection path.
- **Does not appear** → Q5 resolved *no*. The fallback in spec §10 applies: drive `Spirc::load(LoadRequest::from_context_uri(...))` with a known playlist URI. Add that call after `activate()` and re-run to confirm audio still plays. Task 14's UI then needs an entry point that loads a context rather than waiting for handoff.

Either outcome is a pass for this task. An outcome of *no audio at all* is a failure — stop and debug before continuing.

- [ ] **Step 4: Record the findings**

```bash
cat > docs/superpowers/specs/2026-09-21-spike-findings.md <<'EOF'
# Spike findings (Task 2)

Date: <fill in>
librespot revision: <the pinned REV>

## Q5 — Does a token-authenticated device appear for Connect handoff?
Answer: <yes | no>
Evidence: <what you saw in the Spotify device picker>
Consequence: <handoff is the entry point | UI must load a context URI>

## Q1 — Does the track-changed event carry metadata?
Answer: <yes | no>
Fields actually observed: <paste the logged event>
Consequence: <no Web API needed in this slice | GET /v1/tracks/{id} required>

## Q4 — Do any Spirc commands block?
Answer: <observed behaviour>

## Other notes
<anything surprising: event ordering, position reporting, volume scale>
EOF
```

Fill every `<...>` in from what you actually observed. This file is read by Task 6 and Task 14.

- [ ] **Step 5: Commit**

```bash
git add rust/crates/bopify-core/src/bin/spike.rs rust/crates/bopify-core/Cargo.toml docs/superpowers/specs/2026-09-21-spike-findings.md
git commit -m "Add throwaway spike proving Spirc playback on macOS" -m "Answers the two open questions that change later work: whether a
token-authenticated device is offered for Connect handoff, and whether
track-changed events carry metadata. Deleted in the FFI task."
```

---

### Task 3: Error codes and the event wire format

Pure data mapping, fully testable in Rust with no network and no audio.

**Files:**
- Create: `rust/crates/bopify-core/src/error.rs`
- Create: `rust/crates/bopify-core/src/event.rs`
- Modify: `rust/crates/bopify-core/src/lib.rs`

**Interfaces:**
- Consumes: nothing.
- Produces: `BopifyError` with `fn code(&self) -> i32`; `WireEvent` serialising to the JSON contract Task 6 decodes in Swift. Codes: `0` ok, `-1` invalid argument, `-2` session lost, `-3` auth invalid or expired, `-4` premium required, `-5` network unavailable, `-99` unknown.

- [ ] **Step 1: Write the failing tests**

```rust
// rust/crates/bopify-core/src/error.rs
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_are_stable() {
        assert_eq!(BopifyError::InvalidArgument.code(), -1);
        assert_eq!(BopifyError::SessionLost.code(), -2);
        assert_eq!(BopifyError::AuthInvalid.code(), -3);
        assert_eq!(BopifyError::PremiumRequired.code(), -4);
        assert_eq!(BopifyError::NetworkUnavailable.code(), -5);
        assert_eq!(BopifyError::Unknown.code(), -99);
    }

    #[test]
    fn every_code_has_a_message() {
        for e in BopifyError::ALL {
            assert!(!e.message().is_empty());
        }
    }
}
```

```rust
// rust/crates/bopify-core/src/event.rs
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn playing_serialises_with_a_type_tag() {
        let json = serde_json::to_string(&WireEvent::Playing { position_ms: 1000 }).unwrap();
        assert_eq!(json, r#"{"type":"playing","positionMs":1000}"#);
    }

    #[test]
    fn track_changed_carries_metadata() {
        let json = serde_json::to_string(&WireEvent::TrackChanged {
            track_uri: "spotify:track:abc".into(),
            title: "Title".into(),
            artists: vec!["Artist".into()],
            album_title: Some("Album".into()),
            artwork_url: None,
            duration_ms: 240_000,
        })
        .unwrap();
        assert!(json.contains(r#""type":"trackChanged""#));
        assert!(json.contains(r#""durationMs":240000"#));
        assert!(json.contains(r#""artworkUrl":null"#));
    }

    #[test]
    fn active_device_changed_round_trips() {
        let json = serde_json::to_string(&WireEvent::ActiveDeviceChanged { is_active: false }).unwrap();
        assert_eq!(json, r#"{"type":"activeDeviceChanged","isActive":false}"#);
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd rust && cargo test -p bopify-core`
Expected: FAIL — `cannot find type BopifyError`, `cannot find type WireEvent`.

- [ ] **Step 3: Write the implementations**

```rust
// rust/crates/bopify-core/src/error.rs (above the test module)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BopifyError {
    InvalidArgument,
    SessionLost,
    AuthInvalid,
    PremiumRequired,
    NetworkUnavailable,
    Unknown,
}

impl BopifyError {
    pub const ALL: [BopifyError; 6] = [
        Self::InvalidArgument,
        Self::SessionLost,
        Self::AuthInvalid,
        Self::PremiumRequired,
        Self::NetworkUnavailable,
        Self::Unknown,
    ];

    pub fn code(&self) -> i32 {
        match self {
            Self::InvalidArgument => -1,
            Self::SessionLost => -2,
            Self::AuthInvalid => -3,
            Self::PremiumRequired => -4,
            Self::NetworkUnavailable => -5,
            Self::Unknown => -99,
        }
    }

    pub fn message(&self) -> &'static str {
        match self {
            Self::InvalidArgument => "invalid argument",
            Self::SessionLost => "playback session lost",
            Self::AuthInvalid => "access token rejected or expired",
            Self::PremiumRequired => "Spotify Premium is required",
            Self::NetworkUnavailable => "network unavailable",
            Self::Unknown => "unknown error",
        }
    }
}
```

```rust
// rust/crates/bopify-core/src/event.rs (above the test module)
use serde::Serialize;

/// The JSON contract between Rust and Swift. Changing a case or a field
/// name here is a breaking change: `BopifyDomain.PlaybackEvent` must
/// change in the same commit.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum WireEvent {
    #[serde(rename_all = "camelCase")]
    TrackChanged {
        track_uri: String,
        title: String,
        artists: Vec<String>,
        album_title: Option<String>,
        artwork_url: Option<String>,
        duration_ms: u32,
    },
    #[serde(rename_all = "camelCase")]
    Playing { position_ms: u32 },
    #[serde(rename_all = "camelCase")]
    Paused { position_ms: u32 },
    #[serde(rename_all = "camelCase")]
    Seeked { position_ms: u32 },
    #[serde(rename_all = "camelCase")]
    PositionCorrection { position_ms: u32 },
    #[serde(rename_all = "camelCase")]
    VolumeChanged { volume: u16 },
    Loading,
    EndOfTrack,
    #[serde(rename_all = "camelCase")]
    ActiveDeviceChanged { is_active: bool },
    #[serde(rename_all = "camelCase")]
    Failed { code: i32, message: String },
}
```

```rust
// rust/crates/bopify-core/src/lib.rs
//! C-ABI wrapper around librespot's Spirc for the Bopify macOS app.

pub mod error;
pub mod event;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd rust && cargo test -p bopify-core`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add rust/crates/bopify-core/src
git commit -m "Add stable FFI error codes and the event wire format" -m "Events cross the boundary as JSON rather than as mirrored variants:
librespot has 21 PlayerEvent cases and hand-mirroring them across an FFI
is a known source of silent drift on upgrade."
```

---

### Task 4: The engine and the C ABI

**Files:**
- Create: `rust/crates/bopify-core/src/engine.rs`
- Create: `rust/crates/bopify-core/src/ffi.rs`
- Create: `rust/cbindgen.toml`
- Create: `scripts/gen-header.sh`, `scripts/build-rust.sh`
- Modify: `rust/crates/bopify-core/src/lib.rs`, `rust/crates/bopify-core/Cargo.toml`
- Delete: `rust/crates/bopify-core/src/bin/spike.rs`

**Interfaces:**
- Consumes: `BopifyError`, `WireEvent` from Task 3.
- Produces: `artifacts/BopifyCoreFFI.xcframework` and `include/bopify_core.h` declaring exactly: `bopify_engine_create`, `bopify_engine_destroy`, `bopify_activate`, `bopify_play`, `bopify_pause`, `bopify_next`, `bopify_previous`, `bopify_seek`, `bopify_set_volume`, `bopify_load`, `bopify_update_token`. **Eleven functions, not twelve —
amended 2026-09-21:** `bopify_error_message` was removed per pre-flight
ruling F2. It is dead ABI with no Swift caller, and the PRD requires
user-facing error copy to be localised, which a Rust-side English string
bypasses. Swift maps codes via `PlayerError(ffiCode:)` and owns the text.

- [ ] **Step 1: Write the engine**

The engine owns a dedicated tokio runtime on its own thread. Blocking work never touches the caller.

```rust
// rust/crates/bopify-core/src/engine.rs
use std::sync::Arc;

use librespot_connect::{ConnectConfig, Spirc};
use librespot_core::{Session, SessionConfig, authentication::Credentials};
use librespot_playback::{
    audio_backend,
    config::{AudioFormat, PlayerConfig},
    mixer::{Mixer, MixerConfig, softmixer::SoftMixer},
    player::Player,
};
use tokio::runtime::Runtime;

use crate::{error::BopifyError, event::WireEvent};

/// Called on the librespot runtime thread. The Swift side must be safe to
/// invoke from a non-main thread.
pub type EventSink = Arc<dyn Fn(WireEvent) + Send + Sync>;

pub struct Engine {
    runtime: Runtime,
    spirc: Spirc,
}

impl Engine {
    pub fn new(access_token: &str, device_name: &str, sink: EventSink) -> Result<Self, BopifyError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|_| BopifyError::Unknown)?;

        let spirc = runtime.block_on(async {
            let session = Session::new(SessionConfig::default(), None);
            let credentials = Credentials::with_access_token(access_token);

            // Do NOT call session.connect() here. Spirc::new() connects the
            // session itself (connect/src/spirc.rs:223 at the pinned rev), and
            // Session holds its transport in a OnceLock whose second `set`
            // fails -- so a pre-connect makes Spirc::new die with the
            // misleadingly named SessionError::NotConnected. Connection errors
            // are classified off Spirc::new below instead.

            let mixer = Arc::new(SoftMixer::open(MixerConfig::default()));
            let backend = audio_backend::find(None).ok_or(BopifyError::Unknown)?;
            let player = Player::new(
                PlayerConfig::default(),
                session.clone(),
                mixer.get_soft_volume(),
                move || backend(None, AudioFormat::default()),
            );

            let mut events = player.get_player_event_channel();
            let event_sink = sink.clone();
            tokio::spawn(async move {
                while let Some(event) = events.recv().await {
                    if let Some(wire) = crate::event::translate(event) {
                        event_sink(wire);
                    }
                }
                event_sink(WireEvent::Failed {
                    code: BopifyError::SessionLost.code(),
                    message: BopifyError::SessionLost.message().to_string(),
                });
            });

            let (spirc, task) = Spirc::new(
                ConnectConfig { name: device_name.to_string(), ..Default::default() },
                session,
                credentials,
                player,
                mixer,
            )
            .await
            // This is now the only place a bad token or a non-Premium account
            // surfaces: librespot reports both through the same failure path,
            // and since Spotify removed `product` from GET /me in February
            // 2026 it is the only Premium signal available. Classifying it
            // here, not mapping it to Unknown, is what keeps PremiumRequired
            // and AuthInvalid reachable in the error taxonomy.
            .map_err(classify_connect_error)?;

            // The returned future is the event loop. Commands issued before
            // it is driven are queued, so spawning it here is correct.
            tokio::spawn(task);
            Ok::<_, BopifyError>(spirc)
        })?;

        Ok(Self { runtime, spirc })
    }

    pub fn activate(&self) -> Result<(), BopifyError> { self.spirc.activate().map_err(|_| BopifyError::SessionLost) }
    pub fn play(&self) -> Result<(), BopifyError> { self.spirc.play().map_err(|_| BopifyError::SessionLost) }
    pub fn pause(&self) -> Result<(), BopifyError> { self.spirc.pause().map_err(|_| BopifyError::SessionLost) }
    pub fn next(&self) -> Result<(), BopifyError> { self.spirc.next().map_err(|_| BopifyError::SessionLost) }
    pub fn previous(&self) -> Result<(), BopifyError> { self.spirc.prev().map_err(|_| BopifyError::SessionLost) }
    pub fn seek(&self, position_ms: u32) -> Result<(), BopifyError> { self.spirc.set_position_ms(position_ms).map_err(|_| BopifyError::SessionLost) }
    pub fn set_volume(&self, volume: u16) -> Result<(), BopifyError> { self.spirc.set_volume(volume).map_err(|_| BopifyError::SessionLost) }

    pub fn runtime(&self) -> &Runtime { &self.runtime }
    pub fn spirc(&self) -> &Spirc { &self.spirc }
}

fn classify_connect_error<E: std::fmt::Debug>(err: E) -> BopifyError {
    let text = format!("{err:?}").to_lowercase();
    if text.contains("premium") { BopifyError::PremiumRequired }
    else if text.contains("token") || text.contains("credential") || text.contains("unauthor") { BopifyError::AuthInvalid }
    else if text.contains("dns") || text.contains("connect") || text.contains("network") { BopifyError::NetworkUnavailable }
    else { BopifyError::Unknown }
}
```

> **Verify against the pinned source before moving on.** `SoftMixer::open`, `Spirc::new`'s tuple return, and the exact `LoadRequest` option type names were read from librespot v0.8.0 and you are on a `dev` revision. If a signature differs, the source wins: fix the code and correct this plan.

- [ ] **Step 2: Add `translate` and `load` support**

Append to `event.rs` a `pub fn translate(event: PlayerEvent) -> Option<WireEvent>` mapping librespot's variants onto `WireEvent`. Map exactly the cases the spike logged in Task 2; return `None` for the rest rather than inventing a wire case for every internal event. Add `Engine::load`:

```rust
    pub fn load(&self, context_uri: &str, start_track_uri: Option<&str>, position_ms: u32) -> Result<(), BopifyError> {
        // Option and request type names differ across librespot revisions --
        // read them from the pinned source.
        let request = librespot_connect::LoadRequest::from_context_uri(
            context_uri.to_string(),
            librespot_connect::LoadRequestOptions {
                start_playing: true,
                seek_to: position_ms,
                playing_track: start_track_uri.map(|u| librespot_connect::PlayingTrack::Uri(u.to_string())),
                ..Default::default()
            },
        );
        self.spirc.load(request).map_err(|_| BopifyError::SessionLost)
    }
```

- [ ] **Step 3: Write the C ABI**

```rust
// rust/crates/bopify-core/src/ffi.rs
use std::ffi::{CStr, CString, c_char, c_void};
use std::sync::Arc;

use crate::{engine::Engine, error::BopifyError};

pub type BopifyEventCallback = extern "C" fn(json: *const u8, len: usize, ctx: *mut c_void);

pub struct BopifyEngine {
    inner: Engine,
}

/// Wraps the Swift-provided context pointer so it can cross threads.
/// Swift guarantees the pointed-to object outlives the engine handle.
struct SendCtx(*mut c_void);
unsafe impl Send for SendCtx {}
unsafe impl Sync for SendCtx {}

unsafe fn str_from(ptr: *const c_char) -> Option<&'static str> {
    if ptr.is_null() { return None; }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_engine_create(
    access_token: *const c_char,
    device_name: *const c_char,
    callback: BopifyEventCallback,
    ctx: *mut c_void,
    out_err: *mut i32,
) -> *mut BopifyEngine {
    let fail = |code: i32| -> *mut BopifyEngine {
        if !out_err.is_null() { unsafe { *out_err = code }; }
        std::ptr::null_mut()
    };

    let (Some(token), Some(name)) = (unsafe { str_from(access_token) }, unsafe { str_from(device_name) })
    else { return fail(BopifyError::InvalidArgument.code()) };

    let ctx = SendCtx(ctx);
    let sink = Arc::new(move |event| {
        let Ok(json) = serde_json::to_vec(&event) else { return };
        callback(json.as_ptr(), json.len(), ctx.0);
    });

    match Engine::new(token, name, sink) {
        Ok(inner) => {
            if !out_err.is_null() { unsafe { *out_err = 0 }; }
            Box::into_raw(Box::new(BopifyEngine { inner }))
        }
        Err(e) => fail(e.code()),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_engine_destroy(handle: *mut BopifyEngine) {
    if !handle.is_null() { drop(unsafe { Box::from_raw(handle) }); }
}

macro_rules! command {
    ($name:ident, $method:ident) => {
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn $name(handle: *mut BopifyEngine) -> i32 {
            let Some(engine) = (unsafe { handle.as_ref() }) else {
                return BopifyError::InvalidArgument.code();
            };
            match engine.inner.$method() { Ok(()) => 0, Err(e) => e.code() }
        }
    };
}

command!(bopify_activate, activate);
command!(bopify_play, play);
command!(bopify_pause, pause);
command!(bopify_next, next);
command!(bopify_previous, previous);

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_seek(handle: *mut BopifyEngine, position_ms: u32) -> i32 {
    let Some(engine) = (unsafe { handle.as_ref() }) else { return BopifyError::InvalidArgument.code() };
    match engine.inner.seek(position_ms) { Ok(()) => 0, Err(e) => e.code() }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_set_volume(handle: *mut BopifyEngine, volume: u16) -> i32 {
    let Some(engine) = (unsafe { handle.as_ref() }) else { return BopifyError::InvalidArgument.code() };
    match engine.inner.set_volume(volume) { Ok(()) => 0, Err(e) => e.code() }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_load(
    handle: *mut BopifyEngine,
    context_uri: *const c_char,
    start_track_uri: *const c_char,
    start_position_ms: u32,
) -> i32 {
    let Some(engine) = (unsafe { handle.as_ref() }) else { return BopifyError::InvalidArgument.code() };
    let Some(context) = (unsafe { str_from(context_uri) }) else { return BopifyError::InvalidArgument.code() };
    let start = unsafe { str_from(start_track_uri) };
    match engine.inner.load(context, start, start_position_ms) { Ok(()) => 0, Err(e) => e.code() }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_update_token(handle: *mut BopifyEngine, access_token: *const c_char) -> i32 {
    let Some(_engine) = (unsafe { handle.as_ref() }) else { return BopifyError::InvalidArgument.code() };
    let Some(_token) = (unsafe { str_from(access_token) }) else { return BopifyError::InvalidArgument.code() };
    // librespot has no documented in-place credential swap. Returning
    // SessionLost tells Swift to tear down and rebuild the engine, which is
    // the behaviour the facade already implements for a dead session.
    BopifyError::SessionLost.code()
}

#[unsafe(no_mangle)]
pub extern "C" fn bopify_error_message(code: i32) -> *const c_char {
    let error = BopifyError::ALL.iter().find(|e| e.code() == code).copied().unwrap_or(BopifyError::Unknown);
    // Leaked deliberately: a 'static C string with no ownership transfer.
    CString::new(error.message()).unwrap().into_raw()
}
```

Update `lib.rs`:

```rust
pub mod engine;
pub mod error;
pub mod event;
pub mod ffi;
```

- [ ] **Step 4: Generate the header**

```bash
cat > rust/cbindgen.toml <<'EOF'
language = "C"
include_guard = "BOPIFY_CORE_H"
autogen_warning = "/* Generated by scripts/gen-header.sh. Do not edit. */"
[export]
include = ["BopifyEngine"]
EOF

cat > scripts/gen-header.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../rust"
cargo install cbindgen --locked 2>/dev/null || true
mkdir -p ../artifacts/include
cbindgen --config cbindgen.toml --crate bopify-core --output ../artifacts/include/bopify_core.h
EOF
chmod +x scripts/gen-header.sh
```

- [ ] **Step 5: Write the xcframework build script**

`binaryTarget` cannot carry linker settings, so the script prints the native libs for the wrapper target in Task 7.

```bash
mkdir -p scripts
cat > scripts/build-rust.sh <<'EOF'
#!/usr/bin/env bash
# Builds the Rust staticlib and packages it as an xcframework.
# Cargo cannot run as a SwiftPM plugin: plugins are sandboxed without
# network access and cargo needs both network and writes.
set -euo pipefail
cd "$(dirname "$0")/.."

export MACOSX_DEPLOYMENT_TARGET=14.0   # must match the Xcode target
TARGET=aarch64-apple-darwin            # arm64 only; for universal, build
                                       # x86_64-apple-darwin too and lipo them

cargo build --release --manifest-path rust/Cargo.toml --target "$TARGET"
./scripts/gen-header.sh

rm -rf artifacts/BopifyCoreFFI.xcframework
xcodebuild -create-xcframework \
  -library "rust/target/$TARGET/release/libbopify_core.a" \
  -headers artifacts/include \
  -output artifacts/BopifyCoreFFI.xcframework

echo "Link these in Package.swift (CBopifyCore linkerSettings):"
cargo rustc --release --manifest-path rust/crates/bopify-core/Cargo.toml \
  --target "$TARGET" -- --print=native-static-libs 2>&1 | grep native-static-libs || true
EOF
chmod +x scripts/build-rust.sh
```

- [ ] **Step 6: Delete the spike and build**

```bash
rm rust/crates/bopify-core/src/bin/spike.rs
# remove the [[bin]] block from rust/crates/bopify-core/Cargo.toml
cd rust && cargo test -p bopify-core && cd ..
./scripts/build-rust.sh
```

Expected: tests pass; `artifacts/BopifyCoreFFI.xcframework` exists; `artifacts/include/bopify_core.h` declares all eleven functions (twelve minus `bopify_error_message`, removed per the amendment at Task 4's Interfaces). Note the printed native libs — Task 7 needs them.

- [ ] **Step 7: Commit**

```bash
git add rust scripts
git commit -m "Add the C ABI over Spirc and the xcframework build" -m "Eleven commands plus a JSON event callback over an opaque handle. The
spike is deleted now that its findings are recorded. Cargo runs
out-of-band because SwiftPM plugins are sandboxed without network access."
```

---

### Task 5: Swift package skeleton and the domain URI type

**Files:**
- Create: `Packages/BopifyCore/Package.swift`
- Create: `Packages/BopifyCore/Sources/BopifyDomain/SpotifyURI.swift`
- Test: `Packages/BopifyCore/Tests/DomainTests/SpotifyURITests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: the package manifest with targets `BopifyDomain`, `BopifyAuth`, `BopifyPlayback`, `CBopifyCore`; `SpotifyURI` with `init?(_ raw: String)`, `var rawValue: String`, `var id: String`, `var kind: SpotifyURI.Kind`.

- [ ] **Step 1: Write the failing test**

```swift
// Packages/BopifyCore/Tests/DomainTests/SpotifyURITests.swift
import Testing
@testable import BopifyDomain

@Suite("SpotifyURI")
struct SpotifyURITests {
    @Test func parsesATrackURI() throws {
        let uri = try #require(SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6"))
        #expect(uri.kind == .track)
        #expect(uri.id == "6rqhFgbbKwnb9MLmUQDhG6")
        #expect(uri.rawValue == "spotify:track:6rqhFgbbKwnb9MLmUQDhG6")
    }

    @Test func parsesAPlaylistURI() throws {
        let uri = try #require(SpotifyURI("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"))
        #expect(uri.kind == .playlist)
    }

    @Test(arguments: ["", "spotify:track", "spotify::abc", "http://open.spotify.com/track/abc", "spotify:track:"])
    func rejectsMalformedInput(_ raw: String) {
        #expect(SpotifyURI(raw) == nil)
    }

    @Test func treatsUnknownKindsAsUnsupportedRatherThanCrashing() throws {
        let uri = try #require(SpotifyURI("spotify:audiobook:abc123"))
        #expect(uri.kind == .other("audiobook"))
    }
}
```

- [ ] **Step 2: Create the package manifest**

```swift
// Packages/BopifyCore/Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BopifyCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BopifyDomain", targets: ["BopifyDomain"]),
        .library(name: "BopifyAuth", targets: ["BopifyAuth"]),
        .library(name: "BopifyPlayback", targets: ["BopifyPlayback"]),
    ],
    targets: [
        .target(name: "BopifyDomain", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "BopifyAuth", dependencies: ["BopifyDomain"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "BopifyPlayback", dependencies: ["BopifyDomain"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "DomainTests", dependencies: ["BopifyDomain"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "AuthTests", dependencies: ["BopifyAuth"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "PlaybackTests", dependencies: ["BopifyPlayback"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
```

Create empty source directories so the manifest resolves:

```bash
mkdir -p Packages/BopifyCore/Sources/{BopifyDomain,BopifyAuth,BopifyPlayback}
mkdir -p Packages/BopifyCore/Tests/{DomainTests,AuthTests,PlaybackTests}
touch Packages/BopifyCore/Sources/BopifyAuth/.gitkeep Packages/BopifyCore/Sources/BopifyPlayback/.gitkeep
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd Packages/BopifyCore && swift test --filter SpotifyURI`
Expected: FAIL — `cannot find 'SpotifyURI' in scope`.

- [ ] **Step 4: Implement `SpotifyURI`**

```swift
// Packages/BopifyCore/Sources/BopifyDomain/SpotifyURI.swift
/// A validated Spotify URI. Parsing at the boundary means no other type
/// has to defend against malformed identifiers.
public struct SpotifyURI: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: Hashable, Sendable {
        case track, album, artist, playlist, episode, show
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "track": self = .track
            case "album": self = .album
            case "artist": self = .artist
            case "playlist": self = .playlist
            case "episode": self = .episode
            case "show": self = .show
            default: self = .other(raw)
            }
        }
    }

    public let rawValue: String
    public let kind: Kind
    public let id: String

    public init?(_ raw: String) {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "spotify",
              !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        self.rawValue = raw
        self.kind = Kind(parts[1])
        self.id = parts[2]
    }

    public var description: String { rawValue }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd Packages/BopifyCore && swift test --filter SpotifyURI`
Expected: PASS, 8 tests (the parameterised case counts as five).

- [ ] **Step 6: Commit**

```bash
git add Packages
git commit -m "Add Swift package skeleton and validated SpotifyURI" -m "Three targets: BopifyDomain has no dependencies so tests and views can
use the models without linking the Rust library. Swift 6 language mode is
set explicitly rather than inherited from the Xcode template default of 5."
```

---

### Task 6: Domain model — events, state, errors, and the seam

**Files:**
- Create: `Packages/BopifyCore/Sources/BopifyDomain/{Track,PlaybackState,PlaybackEvent,PlayerError,PlaybackEngine,AuthModels}.swift`
- Test: `Packages/BopifyCore/Tests/DomainTests/PlaybackEventTests.swift`

**Interfaces:**
- Consumes: `SpotifyURI` (Task 5); the JSON contract from Task 3.
- Produces: `PlaybackEvent` (`Decodable`), `PlaybackState`, `PlaybackPhase`, `PlayerError`, `Track`, `Artwork`, `ArtistSummary`, `PlayRequest`, `AuthState`, `TokenSet`, and `protocol PlaybackEngine`.

Before writing, read `docs/superpowers/specs/2026-09-21-spike-findings.md`. If Q1 was answered *no*, `Track` still carries `title`/`artists` — they are simply populated later from the Web API rather than from the event. The domain does not change.

- [ ] **Step 1: Write the failing test**

Fixtures are copied verbatim from the Rust test assertions in Task 3, so a drift in either direction fails here.

```swift
// Packages/BopifyCore/Tests/DomainTests/PlaybackEventTests.swift
import Testing
import Foundation
@testable import BopifyDomain

@Suite("PlaybackEvent decoding")
struct PlaybackEventTests {
    private func decode(_ json: String) throws -> PlaybackEvent {
        try JSONDecoder().decode(PlaybackEvent.self, from: Data(json.utf8))
    }

    @Test func decodesPlaying() throws {
        #expect(try decode(#"{"type":"playing","positionMs":1000}"#) == .playing(positionMs: 1000))
    }

    @Test func decodesTrackChanged() throws {
        let json = #"""
        {"type":"trackChanged","trackUri":"spotify:track:abc","title":"Title",
         "artists":["A","B"],"albumTitle":"Album","artworkUrl":null,"durationMs":240000}
        """#
        guard case let .trackChanged(track) = try decode(json) else {
            Issue.record("expected trackChanged"); return
        }
        #expect(track.title == "Title")
        #expect(track.artists.map(\.name) == ["A", "B"])
        #expect(track.durationMs == 240_000)
        #expect(track.artwork == nil)
        #expect(track.uri.id == "abc")
    }

    @Test func decodesActiveDeviceChanged() throws {
        #expect(try decode(#"{"type":"activeDeviceChanged","isActive":false}"#) == .activeDeviceChanged(isActive: false))
    }

    @Test func decodesFailureIntoTheErrorTaxonomy() throws {
        let json = #"{"type":"failed","code":-4,"message":"Spotify Premium is required"}"#
        #expect(try decode(json) == .failed(.premiumRequired))
    }

    @Test func mapsUnrecognisedCodesToUnknownRatherThanThrowing() throws {
        #expect(try decode(#"{"type":"failed","code":-12345,"message":"?"}"#) == .failed(.unknown))
    }

    @Test func throwsOnAnUnrecognisedEventType() {
        #expect(throws: (any Error).self) { try decode(#"{"type":"teleported"}"#) }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/BopifyCore && swift test --filter PlaybackEvent`
Expected: FAIL — `cannot find 'PlaybackEvent' in scope`.

- [ ] **Step 3: Write the domain types**

```swift
// Packages/BopifyCore/Sources/BopifyDomain/Track.swift
import Foundation

public struct ArtistSummary: Hashable, Sendable {
    public let name: String
    public init(name: String) { self.name = name }
}

public struct Artwork: Hashable, Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
}

public struct Track: Hashable, Sendable {
    public let uri: SpotifyURI
    public let title: String
    public let artists: [ArtistSummary]
    public let albumTitle: String?
    public let artwork: Artwork?
    public let durationMs: Int64

    public init(uri: SpotifyURI, title: String, artists: [ArtistSummary],
                albumTitle: String?, artwork: Artwork?, durationMs: Int64) {
        self.uri = uri; self.title = title; self.artists = artists
        self.albumTitle = albumTitle; self.artwork = artwork; self.durationMs = durationMs
    }
}
```

```swift
// Packages/BopifyCore/Sources/BopifyDomain/PlayerError.swift
/// The reachable subset of the PRD taxonomy for this slice. Cases for
/// features that do not exist yet are deliberately absent.
public enum PlayerError: Error, Hashable, Sendable {
    case authDenied
    case invalidCallback
    case authExpired
    case premiumRequired
    case networkUnavailable
    case playbackSessionLost
    case unknown

    /// Mirrors the stable codes in the Rust `BopifyError`.
    public init(ffiCode: Int32) {
        switch ffiCode {
        case -2: self = .playbackSessionLost
        case -3: self = .authExpired
        case -4: self = .premiumRequired
        case -5: self = .networkUnavailable
        default: self = .unknown
        }
    }
}
```

```swift
// Packages/BopifyCore/Sources/BopifyDomain/PlaybackEvent.swift
import Foundation

public enum PlaybackEvent: Hashable, Sendable {
    case trackChanged(Track)
    case playing(positionMs: Int64)
    case paused(positionMs: Int64)
    case seeked(positionMs: Int64)
    case positionCorrection(positionMs: Int64)
    case volumeChanged(volume: Double)
    case loading
    case endOfTrack
    case activeDeviceChanged(isActive: Bool)
    case failed(PlayerError)
}

extension PlaybackEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, positionMs, volume, isActive, code
        case trackUri, title, artists, albumTitle, artworkUrl, durationMs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "playing":            self = .playing(positionMs: try c.decode(Int64.self, forKey: .positionMs))
        case "paused":             self = .paused(positionMs: try c.decode(Int64.self, forKey: .positionMs))
        case "seeked":             self = .seeked(positionMs: try c.decode(Int64.self, forKey: .positionMs))
        case "positionCorrection": self = .positionCorrection(positionMs: try c.decode(Int64.self, forKey: .positionMs))
        case "loading":            self = .loading
        case "endOfTrack":         self = .endOfTrack
        case "activeDeviceChanged": self = .activeDeviceChanged(isActive: try c.decode(Bool.self, forKey: .isActive))
        case "failed":             self = .failed(PlayerError(ffiCode: try c.decode(Int32.self, forKey: .code)))
        case "volumeChanged":
            // librespot uses a u16 volume scale; the domain uses 0...1.
            let raw = try c.decode(Double.self, forKey: .volume)
            self = .volumeChanged(volume: raw / Double(UInt16.max))
        case "trackChanged":
            let raw = try c.decode(String.self, forKey: .trackUri)
            guard let uri = SpotifyURI(raw) else {
                throw DecodingError.dataCorruptedError(forKey: .trackUri, in: c, debugDescription: "malformed Spotify URI")
            }
            self = .trackChanged(Track(
                uri: uri,
                title: try c.decode(String.self, forKey: .title),
                artists: try c.decode([String].self, forKey: .artists).map(ArtistSummary.init(name:)),
                albumTitle: try c.decodeIfPresent(String.self, forKey: .albumTitle),
                artwork: try c.decodeIfPresent(String.self, forKey: .artworkUrl).flatMap(URL.init(string:)).map(Artwork.init(url:)),
                durationMs: try c.decode(Int64.self, forKey: .durationMs)
            ))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unrecognised event type \(type)")
        }
    }
}
```

```swift
// Packages/BopifyCore/Sources/BopifyDomain/PlaybackState.swift
public enum PlaybackPhase: Hashable, Sendable {
    case idle, loading, buffering, playing, paused, ended, error
}

public struct PlaybackState: Hashable, Sendable {
    public var phase: PlaybackPhase = .idle
    public var currentTrack: Track?
    public var positionMs: Int64 = 0
    public var durationMs: Int64 = 0
    public var volume: Double = 1.0
    public var canSeek = false
    public var canPrevious = false
    public var canNext = false
    /// False when another Spotify device has taken over. Without this the
    /// UI would show a phantom paused track indefinitely.
    public var isActiveDevice = false
    public var error: PlayerError?

    public init() {}
}
```

```swift
// Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift
public struct PlayRequest: Hashable, Sendable {
    public let contextURI: SpotifyURI
    public let startTrackURI: SpotifyURI?
    public let startPositionMs: Int64

    public init(contextURI: SpotifyURI, startTrackURI: SpotifyURI? = nil, startPositionMs: Int64 = 0) {
        self.contextURI = contextURI
        self.startTrackURI = startTrackURI
        self.startPositionMs = startPositionMs
    }
}

/// The only seam between the app and librespot. The engine emits events
/// and never exposes state: as a Connect device, another client can pause
/// or skip us, so state is observed rather than told.
public protocol PlaybackEngine: Sendable {
    var events: AsyncStream<PlaybackEvent> { get }

    func activate() async throws
    func load(_ request: PlayRequest) async throws
    func resume() async throws
    func pause() async throws
    func next() async throws
    func previous() async throws
    func seek(to milliseconds: Int64) async throws
    func setVolume(_ value: Double) async throws
}
```

```swift
// Packages/BopifyCore/Sources/BopifyDomain/AuthModels.swift
import Foundation

public enum AuthState: Hashable, Sendable {
    case signedOut, authenticating, signedIn, refreshing, needsReauthentication
    case error(PlayerError)
}

public struct TokenSet: Hashable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let grantedScopes: Set<String>

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, grantedScopes: Set<String>) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.grantedScopes = grantedScopes
    }

    /// Refresh early: an expired token silently kills the Spirc session.
    public func needsRefresh(now: Date = .now, margin: TimeInterval = 300) -> Bool {
        now.addingTimeInterval(margin) >= expiresAt
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/BopifyCore && swift test --filter PlaybackEvent`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/BopifyCore/Sources/BopifyDomain Packages/BopifyCore/Tests/DomainTests
git commit -m "Add domain models, event decoding and the playback seam" -m "The engine protocol exposes an event stream rather than state. As a
Connect device another client can change playback, so state must be
observed; this also adds isActiveDevice, which the PRD model lacked."
```

---

### Task 7: The C callback bridge and the FFI smoke test

Verifies the riskiest mechanism in the design — a C function pointer invoked from a non-main thread feeding an `AsyncStream` under Swift 6 strict concurrency (spec §6). The bridge test needs no Rust, so it runs even if the library is unbuilt.

**Files:**
- Create: `Packages/BopifyCore/Sources/BopifyPlayback/EventBridge.swift`
- Create: `Packages/BopifyCore/Sources/CBopifyCore/module.modulemap` (if cbindgen's header needs wrapping)
- Modify: `Packages/BopifyCore/Package.swift`
- Test: `Packages/BopifyCore/Tests/PlaybackTests/EventBridgeTests.swift`

**Interfaces:**
- Consumes: `PlaybackEvent` (Task 6); `artifacts/BopifyCoreFFI.xcframework` (Task 4).
- Produces: `final class EventBridge: Sendable` with `var events: AsyncStream<PlaybackEvent>`, `var opaqueContext: UnsafeMutableRawPointer`, `func finish()`, and the free function `bopifyEventTrampoline` matching `BopifyEventCallback`.

- [ ] **Step 1: Write the failing test**

```swift
// Packages/BopifyCore/Tests/PlaybackTests/EventBridgeTests.swift
import Testing
import Foundation
@testable import BopifyPlayback
import BopifyDomain

@Suite("EventBridge")
struct EventBridgeTests {
    @Test func deliversAnEventPushedFromABackgroundThread() async throws {
        let bridge = EventBridge()
        let json = Array(#"{"type":"playing","positionMs":4200}"#.utf8)

        Thread.detachNewThread {
            json.withUnsafeBufferPointer { buffer in
                bopifyEventTrampoline(buffer.baseAddress!, buffer.count, bridge.opaqueContext)
            }
        }

        var iterator = bridge.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event == .playing(positionMs: 4200))
    }

    @Test func dropsMalformedPayloadsInsteadOfCrashing() async throws {
        let bridge = EventBridge()
        let bad = Array("not json".utf8)
        let good = Array(#"{"type":"endOfTrack"}"#.utf8)

        Thread.detachNewThread {
            bad.withUnsafeBufferPointer { bopifyEventTrampoline($0.baseAddress!, $0.count, bridge.opaqueContext) }
            good.withUnsafeBufferPointer { bopifyEventTrampoline($0.baseAddress!, $0.count, bridge.opaqueContext) }
        }

        var iterator = bridge.events.makeAsyncIterator()
        #expect(await iterator.next() == .endOfTrack)
    }

    @Test func finishTerminatesTheStream() async throws {
        let bridge = EventBridge()
        bridge.finish()
        var iterator = bridge.events.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/BopifyCore && swift test --filter EventBridge`
Expected: FAIL — `cannot find 'EventBridge' in scope`.

- [ ] **Step 3: Implement the bridge**

```swift
// Packages/BopifyCore/Sources/BopifyPlayback/EventBridge.swift
import Foundation
import BopifyDomain

/// Bridges the Rust event callback onto an AsyncStream.
///
/// The callback arrives on librespot's tokio thread. AsyncStream.Continuation
/// is Sendable, so yielding from there is safe; ownership is handed to Rust as
/// an unretained pointer, and the caller must keep this object alive for at
/// least as long as the engine handle.
public final class EventBridge: Sendable {
    public let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation

    public init() {
        var escaped: AsyncStream<PlaybackEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { escaped = $0 }
        self.continuation = escaped
    }

    public var opaqueContext: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    public func yield(rawJSON: UnsafeRawBufferPointer) {
        guard let base = rawJSON.baseAddress, rawJSON.count > 0 else { return }
        let data = Data(bytes: base, count: rawJSON.count)
        // A malformed payload is a bug in the wire contract, not a user-facing
        // failure. Drop it rather than tearing down playback.
        guard let event = try? JSONDecoder().decode(PlaybackEvent.self, from: data) else { return }
        continuation.yield(event)
    }

    public func finish() { continuation.finish() }
}

/// Matches the Rust `BopifyEventCallback` signature exactly. Must be a
/// top-level function: C function pointers cannot capture context.
public func bopifyEventTrampoline(_ json: UnsafePointer<UInt8>, _ len: Int, _ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    let bridge = Unmanaged<EventBridge>.fromOpaque(ctx).takeUnretainedValue()
    bridge.yield(rawJSON: UnsafeRawBufferPointer(start: json, count: len))
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/BopifyCore && swift test --filter EventBridge`
Expected: PASS, 3 tests, **no concurrency warnings** — the package is in Swift 6 language mode, so a `Sendable` violation is a build error.

- [ ] **Step 5: Wire the binary target**

Add to `Package.swift`, using the native libs printed by `scripts/build-rust.sh` in Task 4:

```swift
        .binaryTarget(name: "BopifyCoreFFI", path: "../../artifacts/BopifyCoreFFI.xcframework"),
        .target(
            name: "CBopifyCore",
            dependencies: ["BopifyCoreFFI"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedLibrary("c++"),
            ]
        ),
```

and add `"CBopifyCore"` to `BopifyPlayback`'s dependencies. `binaryTarget` cannot carry linker settings, which is why the wrapper target exists.

- [ ] **Step 6: Smoke-test the real library**

```swift
// append to Packages/BopifyCore/Tests/PlaybackTests/EventBridgeTests.swift
import CBopifyCore

@Suite("FFI smoke test")
struct FFISmokeTests {
    @Test func rejectsANullTokenWithInvalidArgument() {
        var err: Int32 = 0
        let handle = bopify_engine_create(nil, "Bopify Test", bopifyEventTrampoline, nil, &err)
        #expect(handle == nil)
        #expect(err == -1)
    }
}
```

Run: `cd Packages/BopifyCore && swift test --filter FFI`
Expected: PASS. This proves the xcframework links, the header imports, and the Swift and Rust views of the ABI agree.

- [ ] **Step 7: Commit**

```bash
git add Packages/BopifyCore
git commit -m "Bridge the Rust event callback onto an AsyncStream" -m "Proves the riskiest mechanism in the design: a C function pointer
invoked from librespot's tokio thread feeding an AsyncStream under Swift 6
strict concurrency, plus a smoke test that Swift and Rust agree on the ABI."
```

---

### Task 8: PKCE primitives and the authorization URL

Pure functions — the easiest thing in the project to test and the easiest to get subtly wrong.

**Files:**
- Create: `Packages/BopifyCore/Sources/BopifyAuth/PKCE.swift`
- Create: `Packages/BopifyCore/Sources/BopifyAuth/AuthorizationRequest.swift`
- Test: `Packages/BopifyCore/Tests/AuthTests/PKCETests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PKCEPair` with `init(verifier: String)`, `static func random() -> PKCEPair`, `.verifier`, `.challenge`; `AuthorizationRequest` with `init(clientID:redirectURI:scopes:pkce:state:)` and `var url: URL`.

- [ ] **Step 1: Write the failing test**

The RFC 7636 appendix-B vector makes this verifiable against something other than our own implementation.

```swift
// Packages/BopifyCore/Tests/AuthTests/PKCETests.swift
import Testing
import Foundation
@testable import BopifyAuth

@Suite("PKCE")
struct PKCETests {
    @Test func matchesTheRFC7636TestVector() {
        let pair = PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pair.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func challengeIsBase64URLWithNoPadding() {
        let challenge = PKCEPair.random().challenge
        #expect(!challenge.contains("="))
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
    }

    @Test func verifierLengthIsWithinTheSpecRange() {
        let verifier = PKCEPair.random().verifier
        #expect(verifier.count >= 43 && verifier.count <= 128)
    }

    @Test func randomPairsDiffer() {
        #expect(PKCEPair.random().verifier != PKCEPair.random().verifier)
    }
}

@Suite("AuthorizationRequest")
struct AuthorizationRequestTests {
    private let pkce = PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")

    private func components() throws -> [String: String] {
        let request = AuthorizationRequest(
            clientID: "client123",
            redirectURI: "http://127.0.0.1:52341/callback",
            scopes: ["streaming"],
            pkce: pkce,
            state: "state123"
        )
        let parsed = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (parsed.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func targetsSpotifyAuthorizeEndpoint() throws {
        let request = AuthorizationRequest(clientID: "c", redirectURI: "http://127.0.0.1:1/callback",
                                           scopes: ["streaming"], pkce: pkce, state: "s")
        #expect(request.url.absoluteString.hasPrefix("https://accounts.spotify.com/authorize?"))
    }

    @Test func usesAuthorizationCodeWithS256() throws {
        let q = try components()
        #expect(q["response_type"] == "code")
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["code_challenge"] == pkce.challenge)
    }

    @Test func requestsOnlyTheStreamingScope() throws {
        #expect(try components()["scope"] == "streaming")
    }

    @Test func carriesTheLoopbackRedirectIncludingItsDynamicPort() throws {
        // Registered without a port; the concrete port must still be sent.
        #expect(try components()["redirect_uri"] == "http://127.0.0.1:52341/callback")
    }

    @Test func carriesStateForCSRFProtection() throws {
        #expect(try components()["state"] == "state123")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/BopifyCore && swift test --filter PKCE`
Expected: FAIL — `cannot find 'PKCEPair' in scope`.

- [ ] **Step 3: Implement**

```swift
// Packages/BopifyCore/Sources/BopifyAuth/PKCE.swift
import CryptoKit
import Foundation

public struct PKCEPair: Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = Data(digest).base64URLEncodedString()
    }

    public static func random() -> PKCEPair {
        var bytes = [UInt8](repeating: 0, count: 64)
        // SecRandomCopyBytes is the platform CSPRNG; PKCE security rests on it.
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return PKCEPair(verifier: Data(bytes).base64URLEncodedString())
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

```swift
// Packages/BopifyCore/Sources/BopifyAuth/AuthorizationRequest.swift
import Foundation

public struct AuthorizationRequest: Sendable {
    public let url: URL

    public init(clientID: String, redirectURI: String, scopes: [String], pkce: PKCEPair, state: String) {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "state", value: state),
        ]
        self.url = components.url!
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Packages/BopifyCore && swift test --filter PKCE && swift test --filter AuthorizationRequest`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/BopifyCore/Sources/BopifyAuth Packages/BopifyCore/Tests/AuthTests
git commit -m "Add PKCE derivation and Spotify authorization URL" -m "Verified against the RFC 7636 appendix B vector rather than only
against our own output. Requests the streaming scope alone."
```

---

### Task 9: The loopback callback listener

**Files:**
- Create: `Packages/BopifyCore/Sources/BopifyAuth/LoopbackCallbackListener.swift`
- Test: `Packages/BopifyCore/Tests/AuthTests/LoopbackCallbackListenerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `actor LoopbackCallbackListener` with `func start() throws -> Int` (returns the bound port), `func waitForCallback() async throws -> String` (the authorization code), `func stop()`; and `enum CallbackError: Error { case invalidCallback, accessDenied, stateMismatch }`.

- [ ] **Step 1: Write the failing test**

```swift
// Packages/BopifyCore/Tests/AuthTests/LoopbackCallbackListenerTests.swift
import Testing
import Foundation
@testable import BopifyAuth

@Suite("LoopbackCallbackListener")
struct LoopbackCallbackListenerTests {
    private func get(_ url: URL) async throws {
        _ = try? await URLSession.shared.data(from: url)
    }

    @Test func bindsAnEphemeralPort() async throws {
        let listener = LoopbackCallbackListener(expectedState: "s")
        let port = try await listener.start()
        #expect(port > 0)
        await listener.stop()
    }

    @Test func returnsTheAuthorizationCode() async throws {
        let listener = LoopbackCallbackListener(expectedState: "state123")
        let port = try await listener.start()

        async let code = listener.waitForCallback()
        try await get(URL(string: "http://127.0.0.1:\(port)/callback?code=abc123&state=state123")!)

        #expect(try await code == "abc123")
        await listener.stop()
    }

    @Test func rejectsAMismatchedState() async throws {
        let listener = LoopbackCallbackListener(expectedState: "expected")
        let port = try await listener.start()

        async let result = listener.waitForCallback()
        try await get(URL(string: "http://127.0.0.1:\(port)/callback?code=abc&state=attacker")!)

        await #expect(throws: CallbackError.stateMismatch) { _ = try await result }
        await listener.stop()
    }

    @Test func surfacesUserDenial() async throws {
        let listener = LoopbackCallbackListener(expectedState: "s")
        let port = try await listener.start()

        async let result = listener.waitForCallback()
        try await get(URL(string: "http://127.0.0.1:\(port)/callback?error=access_denied&state=s")!)

        await #expect(throws: CallbackError.accessDenied) { _ = try await result }
        await listener.stop()
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/BopifyCore && swift test --filter Loopback`
Expected: FAIL — `cannot find 'LoopbackCallbackListener' in scope`.

- [ ] **Step 3: Implement**

```swift
// Packages/BopifyCore/Sources/BopifyAuth/LoopbackCallbackListener.swift
import Foundation
import Network

public enum CallbackError: Error, Hashable, Sendable {
    case invalidCallback, accessDenied, stateMismatch, listenerFailed
}

/// A single-shot HTTP listener on 127.0.0.1 with an OS-assigned port.
///
/// Spotify rejects `localhost` but permits loopback IP literals, and those
/// alone may use a dynamically assigned port -- which is why the app is
/// registered as `http://127.0.0.1/callback` with no port.
public actor LoopbackCallbackListener {
    private let expectedState: String
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, any Error>?

    public init(expectedState: String) { self.expectedState = expectedState }

    public func start() throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                Task { await self?.handle(requestLine: request, on: connection) }
            }
        }
        listener.start(queue: .main)

        // NWListener assigns the port asynchronously; spin briefly for it.
        for _ in 0..<100 {
            if let port = listener.port?.rawValue, port != 0 { return Int(port) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw CallbackError.listenerFailed
    }

    public func waitForCallback() async throws -> String {
        try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(requestLine: String, on connection: NWConnection) {
        defer { connection.cancel() }
        guard let continuation else { return }
        self.continuation = nil

        respond(on: connection)

        guard let path = requestLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(path)") else {
            continuation.resume(throwing: CallbackError.invalidCallback); return
        }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        if query["error"] == "access_denied" { continuation.resume(throwing: CallbackError.accessDenied); return }
        guard query["state"] == expectedState else { continuation.resume(throwing: CallbackError.stateMismatch); return }
        guard let code = query["code"], !code.isEmpty else { continuation.resume(throwing: CallbackError.invalidCallback); return }
        continuation.resume(returning: code)
    }

    private func respond(on connection: NWConnection) {
        let body = "<html><body><h1>Bopify</h1><p>You can close this tab.</p></body></html>"
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Packages/BopifyCore && swift test --filter Loopback`
Expected: PASS, 4 tests. macOS may prompt for incoming-connection permission on first run — accept it.

- [ ] **Step 5: Commit**

```bash
git add Packages/BopifyCore/Sources/BopifyAuth Packages/BopifyCore/Tests/AuthTests
git commit -m "Add single-shot loopback listener for the OAuth callback" -m "Binds an OS-assigned port on 127.0.0.1. Spotify rejects localhost but
allows loopback literals to use dynamic ports, so the app is registered
without one. State is verified before the code is accepted."
```

---

### Task 10: Token exchange and refresh

**Files:**
- Create: `Packages/BopifyCore/Sources/BopifyAuth/TokenClient.swift`
- Test: `Packages/BopifyCore/Tests/AuthTests/TokenClientTests.swift`

**Interfaces:**
- Consumes: `TokenSet` (Task 6), `PKCEPair` (Task 8).
- Produces: `struct TokenClient: Sendable` with `init(clientID:session:)`, `func exchange(code:redirectURI:pkce:) async throws -> TokenSet`, `func refresh(refreshToken:) async throws -> TokenSet`.

Tested through a `URLProtocol` stub — this is our request-shaping logic, not Spotify's server. Per `AGENTS.md` §5 we test the boundary, not the third party.

- [ ] **Step 1: Write the failing test**

```swift
// Packages/BopifyCore/Tests/AuthTests/TokenClientTests.swift
import Testing
import Foundation
@testable import BopifyAuth
import BopifyDomain

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastBody: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // URLSession moves the body to a stream; read it back for assertions.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer[0..<read])
            }
            stream.close()
            Self.lastBody = String(data: data, encoding: .utf8)
        }
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("TokenClient", .serialized)
struct TokenClientTests {
    private func makeClient() -> TokenClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return TokenClient(clientID: "client123", session: URLSession(configuration: config))
    }

    private let success = #"""
    {"access_token":"AT","token_type":"Bearer","expires_in":3600,
     "refresh_token":"RT","scope":"streaming"}
    """#

    @Test func exchangesAuthorizationCodeForTokens() async throws {
        StubProtocol.handler = { _ in (200, Data(self.success.utf8)) }
        let tokens = try await makeClient().exchange(
            code: "CODE", redirectURI: "http://127.0.0.1:5000/callback",
            pkce: PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))

        #expect(tokens.accessToken == "AT")
        #expect(tokens.refreshToken == "RT")
        #expect(tokens.grantedScopes == ["streaming"])
        #expect(tokens.expiresAt > Date())
    }

    @Test func sendsPKCEVerifierAndClientIDButNoSecret() async throws {
        StubProtocol.handler = { _ in (200, Data(self.success.utf8)) }
        _ = try await makeClient().exchange(
            code: "CODE", redirectURI: "http://127.0.0.1:5000/callback",
            pkce: PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))

        let body = try #require(StubProtocol.lastBody)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code_verifier=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
        #expect(body.contains("client_id=client123"))
        #expect(!body.contains("client_secret"))
    }

    @Test func keepsTheExistingRefreshTokenWhenTheResponseOmitsOne() async throws {
        StubProtocol.handler = { _ in
            (200, Data(#"{"access_token":"AT2","token_type":"Bearer","expires_in":3600,"scope":"streaming"}"#.utf8))
        }
        let tokens = try await makeClient().refresh(refreshToken: "OLD_RT")
        // Spotify: "When a refresh token is not returned, continue using
        // the existing token."
        #expect(tokens.refreshToken == "OLD_RT")
        #expect(tokens.accessToken == "AT2")
    }

    @Test func mapsInvalidGrantToAuthExpired() async {
        StubProtocol.handler = { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
        await #expect(throws: PlayerError.authExpired) {
            _ = try await makeClient().refresh(refreshToken: "DEAD")
        }
    }

    @Test func mapsServerFailureToNetworkUnavailable() async {
        StubProtocol.handler = { _ in (503, Data()) }
        await #expect(throws: PlayerError.networkUnavailable) {
            _ = try await makeClient().refresh(refreshToken: "RT")
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/BopifyCore && swift test --filter TokenClient`
Expected: FAIL — `cannot find 'TokenClient' in scope`.

- [ ] **Step 3: Implement**

```swift
// Packages/BopifyCore/Sources/BopifyAuth/TokenClient.swift
import Foundation
import BopifyDomain

public struct TokenClient: Sendable {
    private let clientID: String
    private let session: URLSession
    private static let endpoint = URL(string: "https://accounts.spotify.com/api/token")!

    public init(clientID: String, session: URLSession = .shared) {
        self.clientID = clientID
        self.session = session
    }

    public func exchange(code: String, redirectURI: String, pkce: PKCEPair) async throws -> TokenSet {
        try await post([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": pkce.verifier,
        ], fallbackRefreshToken: nil)
    }

    public func refresh(refreshToken: String) async throws -> TokenSet {
        try await post([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ], fallbackRefreshToken: refreshToken)
    }

    private struct Response: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
        let scope: String?
    }

    private func post(_ fields: [String: String], fallbackRefreshToken: String?) async throws -> TokenSet {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { "\($0.key)=\(Self.escape($0.value))" }.joined(separator: "&").utf8)

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw PlayerError.networkUnavailable }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw PlayerError.unknown }
            return TokenSet(
                accessToken: decoded.access_token,
                // Spotify does not always rotate refresh tokens; keep the old
                // one when the response omits it.
                refreshToken: decoded.refresh_token ?? fallbackRefreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)),
                grantedScopes: Set(decoded.scope?.split(separator: " ").map(String.init) ?? [])
            )
        case 400, 401:
            throw PlayerError.authExpired
        default:
            throw PlayerError.networkUnavailable
        }
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Packages/BopifyCore && swift test --filter TokenClient`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/BopifyCore/Sources/BopifyAuth Packages/BopifyCore/Tests/AuthTests
git commit -m "Add PKCE token exchange and refresh" -m "No client secret is sent; PKCE exists so the installed app does not need
one. Spotify does not guarantee refresh-token rotation, so an omitted
refresh_token preserves the stored one."
```

---

### Task 11: Keychain storage and the auth service

**Files:**
- Create: `Packages/BopifyCore/Sources/BopifyAuth/TokenStore.swift`
- Create: `Packages/BopifyCore/Sources/BopifyAuth/SpotifyAuthService.swift`
- Test: `Packages/BopifyCore/Tests/AuthTests/TokenStoreTests.swift`

**Interfaces:**
- Consumes: `TokenSet`, `TokenClient`, `LoopbackCallbackListener`, `AuthorizationRequest`, `PKCEPair`.
- Produces: `protocol TokenStoring` (`save`, `load`, `clear`); `struct KeychainTokenStore: TokenStoring`; `actor SpotifyAuthService` with `func signIn() async throws -> TokenSet`, `func restore() async -> TokenSet?`, `func validAccessToken() async throws -> String`, `func signOut() async`.

- [ ] **Step 1: Write the failing test**

Uses a unique service name per run so tests never collide with the real app's items.

```swift
// Packages/BopifyCore/Tests/AuthTests/TokenStoreTests.swift
import Testing
import Foundation
@testable import BopifyAuth
import BopifyDomain

@Suite("KeychainTokenStore", .serialized)
struct TokenStoreTests {
    private func makeStore() -> KeychainTokenStore {
        KeychainTokenStore(service: "my.bopify.tests.\(UUID().uuidString)")
    }

    private var sample: TokenSet {
        TokenSet(accessToken: "AT", refreshToken: "RT",
                 expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                 grantedScopes: ["streaming"])
    }

    @Test func roundTripsATokenSet() throws {
        let store = makeStore()
        try store.save(sample)
        let loaded = try #require(store.load())
        #expect(loaded == sample)
        try store.clear()
    }

    @Test func overwritesAnExistingItem() throws {
        let store = makeStore()
        try store.save(sample)
        let updated = TokenSet(accessToken: "AT2", refreshToken: "RT2",
                               expiresAt: sample.expiresAt, grantedScopes: ["streaming"])
        try store.save(updated)
        #expect(store.load()?.accessToken == "AT2")
        try store.clear()
    }

    @Test func returnsNilWhenNothingIsStored() {
        #expect(makeStore().load() == nil)
    }

    @Test func clearRemovesTheItem() throws {
        let store = makeStore()
        try store.save(sample)
        try store.clear()
        #expect(store.load() == nil)
    }

    @Test func clearOnAnEmptyStoreIsNotAnError() throws {
        try makeStore().clear()
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/BopifyCore && swift test --filter KeychainTokenStore`
Expected: FAIL — `cannot find 'KeychainTokenStore' in scope`.

- [ ] **Step 3: Implement the store**

```swift
// Packages/BopifyCore/Sources/BopifyAuth/TokenStore.swift
import Foundation
import Security
import BopifyDomain

public protocol TokenStoring: Sendable {
    func save(_ tokens: TokenSet) throws
    func load() -> TokenSet?
    func clear() throws
}

/// Direct SecItem. No maintained Swift wrapper sets
/// kSecUseDataProtectionKeychain, which Apple recommends for all keychain
/// operations, and the whole surface is about sixty lines.
public struct KeychainTokenStore: TokenStoring {
    private let service: String
    private let account = "spotify-tokens"

    public init(service: String = "my.snsoft.bopify") { self.service = service }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func save(_ tokens: TokenSet) throws {
        let data = try JSONEncoder().encode(Stored(tokens))
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpected(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpected(status)
        }
    }

    public func load() -> TokenSet? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return stored.tokenSet
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpected(status) }
    }

    private struct Stored: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
        let grantedScopes: [String]

        init(_ tokens: TokenSet) {
            accessToken = tokens.accessToken; refreshToken = tokens.refreshToken
            expiresAt = tokens.expiresAt; grantedScopes = Array(tokens.grantedScopes)
        }
        var tokenSet: TokenSet {
            TokenSet(accessToken: accessToken, refreshToken: refreshToken,
                     expiresAt: expiresAt, grantedScopes: Set(grantedScopes))
        }
    }
}

public enum KeychainError: Error, Hashable, Sendable { case unexpected(OSStatus) }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/BopifyCore && swift test --filter KeychainTokenStore`
Expected: PASS, 5 tests.

**If they fail with `errSecMissingEntitlement` (-34018)**, that is spec §10 Q3 resolving against the data-protection keychain under local signing. Drop `kSecUseDataProtectionKeychain` to fall back to the file-based keychain, re-run, and record the outcome in the spike findings file.

- [ ] **Step 5: Write the auth service**

```swift
// Packages/BopifyCore/Sources/BopifyAuth/SpotifyAuthService.swift
import AppKit
import Foundation
import BopifyDomain

public actor SpotifyAuthService {
    private let clientID: String
    private let client: TokenClient
    private let store: any TokenStoring
    private var tokens: TokenSet?

    public init(clientID: String, client: TokenClient? = nil, store: any TokenStoring = KeychainTokenStore()) {
        self.clientID = clientID
        self.client = client ?? TokenClient(clientID: clientID)
        self.store = store
    }

    public func restore() -> TokenSet? {
        tokens = store.load()
        return tokens
    }

    public func signIn() async throws -> TokenSet {
        let pkce = PKCEPair.random()
        let state = UUID().uuidString
        let listener = LoopbackCallbackListener(expectedState: state)
        let port = try await listener.start()
        defer { Task { await listener.stop() } }

        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let request = AuthorizationRequest(clientID: clientID, redirectURI: redirectURI,
                                           scopes: ["streaming"], pkce: pkce, state: state)
        NSWorkspace.shared.open(request.url)

        let code: String
        do { code = try await listener.waitForCallback() }
        catch CallbackError.accessDenied { throw PlayerError.authDenied }
        catch { throw PlayerError.invalidCallback }

        let tokens = try await client.exchange(code: code, redirectURI: redirectURI, pkce: pkce)
        try store.save(tokens)
        self.tokens = tokens
        return tokens
    }

    /// Refreshes ahead of expiry: an expired token silently kills the
    /// Spirc session rather than failing loudly.
    public func validAccessToken() async throws -> String {
        guard let current = tokens ?? restore() else { throw PlayerError.authExpired }
        guard current.needsRefresh() else { return current.accessToken }
        guard let refreshToken = current.refreshToken else { throw PlayerError.authExpired }
        let refreshed = try await client.refresh(refreshToken: refreshToken)
        try store.save(refreshed)
        tokens = refreshed
        return refreshed.accessToken
    }

    public func signOut() {
        try? store.clear()
        tokens = nil
    }
}
```

- [ ] **Step 6: Verify the suite is green**

Run: `cd Packages/BopifyCore && swift test`
Expected: PASS, all suites.

- [ ] **Step 7: Commit**

```bash
git add Packages/BopifyCore
git commit -m "Add Keychain token storage and the Spotify auth service" -m "SecItem is used directly because no maintained Swift wrapper sets
kSecUseDataProtectionKeychain. Tokens refresh ahead of expiry since an
expired token kills the playback session silently rather than loudly."
```

---

### Task 12: The stub engine and the observable facade

Where the slice's real behaviour gets tested. Every state transition the UI can show is asserted here without audio, network, or Rust.

**Files:**
- Create: `Packages/BopifyCore/Sources/BopifyPlayback/StubPlaybackEngine.swift`
- Create: `Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift`
- Test: `Packages/BopifyCore/Tests/PlaybackTests/PlayerModelTests.swift`

**Interfaces:**
- Consumes: `PlaybackEngine`, `PlaybackEvent`, `PlaybackState` (Task 6).
- Produces: `final class StubPlaybackEngine: PlaybackEngine` with `func emit(_ event: PlaybackEvent)` and `var recordedCommands: [String]`; `@MainActor @Observable final class PlayerModel` with `var state: PlaybackState`, `func start()`, `func togglePlayPause()`, `func next()`, `func previous()`.

- [ ] **Step 1: Write the failing test**

```swift
// Packages/BopifyCore/Tests/PlaybackTests/PlayerModelTests.swift
import Testing
import Foundation
@testable import BopifyPlayback
import BopifyDomain

@MainActor
@Suite("PlayerModel")
struct PlayerModelTests {
    private func makeTrack() -> Track {
        Track(uri: SpotifyURI("spotify:track:abc")!, title: "Title",
              artists: [ArtistSummary(name: "Artist")], albumTitle: "Album",
              artwork: nil, durationMs: 240_000)
    }

    /// Emits events and waits for the model's consumer task to fold them in.
    private func settle(_ model: PlayerModel, _ engine: StubPlaybackEngine, _ events: [PlaybackEvent]) async {
        for event in events { engine.emit(event) }
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func startsIdle() {
        let model = PlayerModel(engine: StubPlaybackEngine())
        #expect(model.state.phase == .idle)
        #expect(model.state.currentTrack == nil)
    }

    @Test func trackChangedPopulatesMetadataAndDuration() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        await settle(model, engine, [.trackChanged(makeTrack())])

        #expect(model.state.currentTrack?.title == "Title")
        #expect(model.state.durationMs == 240_000)
        #expect(model.state.canNext)
        #expect(model.state.canPrevious)
    }

    @Test func playingThenPausedMovesThroughPhases() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()

        await settle(model, engine, [.playing(positionMs: 1000)])
        #expect(model.state.phase == .playing)
        #expect(model.state.positionMs == 1000)

        await settle(model, engine, [.paused(positionMs: 2000)])
        #expect(model.state.phase == .paused)
        #expect(model.state.positionMs == 2000)
    }

    @Test func bufferingPreservesTheCurrentTrack() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        await settle(model, engine, [.trackChanged(makeTrack()), .playing(positionMs: 1000), .loading])

        #expect(model.state.phase == .loading)
        #expect(model.state.currentTrack?.title == "Title")  // PLAY-07
    }

    @Test func losingTheActiveDeviceStopsPretendingToPlay() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        await settle(model, engine, [.trackChanged(makeTrack()), .playing(positionMs: 1000),
                                     .activeDeviceChanged(isActive: false)])

        #expect(model.state.isActiveDevice == false)
        #expect(model.state.phase == .idle)
    }

    @Test func failureSetsErrorAndErrorPhase() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        await settle(model, engine, [.failed(.premiumRequired)])

        #expect(model.state.phase == .error)
        #expect(model.state.error == .premiumRequired)
    }

    @Test func togglePlayPauseSendsTheCommandButDoesNotAssumeItWorked() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        await settle(model, engine, [.playing(positionMs: 0)])

        model.togglePlayPause()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(engine.recordedCommands.contains("pause"))
        // Commands are requests. Only an event may change the phase.
        #expect(model.state.phase == .playing)

        await settle(model, engine, [.paused(positionMs: 5)])
        #expect(model.state.phase == .paused)
    }

    @Test func externalPauseFromAnotherDeviceIsReflected() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        await settle(model, engine, [.playing(positionMs: 0), .paused(positionMs: 900)])

        #expect(model.state.phase == .paused)
        #expect(engine.recordedCommands.isEmpty)  // nobody pressed anything here
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/BopifyCore && swift test --filter PlayerModel`
Expected: FAIL — `cannot find 'PlayerModel' in scope`.

- [ ] **Step 3: Implement the stub engine**

```swift
// Packages/BopifyCore/Sources/BopifyPlayback/StubPlaybackEngine.swift
import Foundation
import BopifyDomain

/// Carries the entire automated test suite for everything above the seam.
public final class StubPlaybackEngine: PlaybackEngine, @unchecked Sendable {
    public let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let lock = NSLock()
    private var commands: [String] = []

    public init() {
        var escaped: AsyncStream<PlaybackEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { escaped = $0 }
        continuation = escaped
    }

    public var recordedCommands: [String] {
        lock.withLock { commands }
    }

    public func emit(_ event: PlaybackEvent) { continuation.yield(event) }

    private func record(_ name: String) { lock.withLock { commands.append(name) } }

    public func activate() async throws { record("activate") }
    public func load(_ request: PlayRequest) async throws { record("load:\(request.contextURI.rawValue)") }
    public func resume() async throws { record("resume") }
    public func pause() async throws { record("pause") }
    public func next() async throws { record("next") }
    public func previous() async throws { record("previous") }
    public func seek(to milliseconds: Int64) async throws { record("seek:\(milliseconds)") }
    public func setVolume(_ value: Double) async throws { record("setVolume:\(value)") }
}
```

- [ ] **Step 4: Implement the facade**

```swift
// Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift
import Foundation
import Observation
import BopifyDomain

/// Folds engine events into observable state on the main actor.
///
/// Deliberately not an actor: under SE-0461 a nonisolated async function
/// runs on the caller's actor, so an actor here would drag blocking FFI
/// work onto the main thread. Blocking work goes through @concurrent instead.
@MainActor
@Observable
public final class PlayerModel {
    public private(set) var state = PlaybackState()

    @ObservationIgnored private let engine: any PlaybackEngine
    @ObservationIgnored private var consumer: Task<Void, Never>?

    public init(engine: any PlaybackEngine) { self.engine = engine }

    /// One consumer for the model's lifetime. A per-view .task would
    /// resubscribe whenever view identity changed.
    public func start() {
        guard consumer == nil else { return }
        consumer = Task { [engine] in
            for await event in engine.events {
                self.apply(event)
            }
        }
    }

    public func stop() {
        consumer?.cancel()
        consumer = nil
    }

    public func togglePlayPause() {
        let shouldPause = state.phase == .playing
        Task { [engine] in
            // A failure is reported by the engine as an event; nothing is
            // assumed here about whether the command took effect.
            try? await shouldPause ? engine.pause() : engine.resume()
        }
    }

    public func next() { Task { [engine] in try? await engine.next() } }
    public func previous() { Task { [engine] in try? await engine.previous() } }
    public func activate() { Task { [engine] in try? await engine.activate() } }

    private func apply(_ event: PlaybackEvent) {
        switch event {
        case let .trackChanged(track):
            state.currentTrack = track
            state.durationMs = track.durationMs
            state.positionMs = 0
            state.canNext = true
            state.canPrevious = true
            state.canSeek = true
            state.error = nil
        case let .playing(position):
            state.phase = .playing; state.positionMs = position
            state.isActiveDevice = true; state.error = nil
        case let .paused(position):
            state.phase = .paused; state.positionMs = position
            state.isActiveDevice = true
        case let .seeked(position), let .positionCorrection(position):
            state.positionMs = position
        case let .volumeChanged(volume):
            state.volume = volume
        case .loading:
            // Metadata is preserved deliberately (PRD PLAY-07).
            state.phase = .loading
        case .endOfTrack:
            state.phase = .ended; state.positionMs = state.durationMs
        case let .activeDeviceChanged(isActive):
            state.isActiveDevice = isActive
            if !isActive { state.phase = .idle }
        case let .failed(error):
            state.phase = .error; state.error = error
            if error == .playbackSessionLost { state.isActiveDevice = false }
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Packages/BopifyCore && swift test --filter PlayerModel`
Expected: PASS, 8 tests.

- [ ] **Step 6: Commit**

```bash
git add Packages/BopifyCore
git commit -m "Add stub engine and the observable player facade" -m "Commands are requests; only engine events change phase, which is what
keeps the UI correct when another Spotify device drives playback. The
facade is not an actor: SE-0461 would route blocking FFI work to the
main actor."
```

---

### Task 13: The real librespot engine

> **AMENDMENT 2026-09-22 — the Swift code below is STALE. Read this first.**
>
> Tasks 4 and 7 changed the contract this task was written against. Where this
> task's code disagrees with `artifacts/include/bopify_core.h` or with the
> `EventBridge` that Task 7 actually shipped, **those win**. Known
> divergences, all verified:
>
> 1. **`bopify_engine_create` returns `OpaquePointer?`.** Every
>    `UnsafeMutablePointer(handle)` cast below is wrong and will not compile.
>    Pass the `OpaquePointer` straight through.
> 2. **`ctx` is retained, not unretained.** Task 7 replaced the brief's
>    `passUnretained` with `retainedContext()` / `releaseContext(_:)` (+1),
>    because the unretained version made every early-drop path a
>    use-after-free on a tokio thread. The shipped API is
>    `EventBridge.retainedContext() -> UnsafeMutableRawPointer` and the
>    **static** `EventBridge.releaseContext(_ ctx: UnsafeMutableRawPointer)`,
>    so **this task must keep the `ctx` pointer alongside the bridge
>    reference** — the release needs the pointer, not the object. It is a
>    **once-only** obligation this task owns. The teardown order is exactly:
>    `finish()` → `bopify_engine_destroy` → `EventBridge.releaseContext(ctx)`.
>    Releasing before destroy returns is a use-after-free; the C header states
>    that `ctx` must outlive destroy, and it is the one safety property Rust
>    deliberately cannot enforce.
> 3. **Do not tear down from `deinit`.** `deinit` runs wherever the last
>    release happens, including the main actor, and `bopify_engine_destroy`
>    blocks on the Rust runtime join and then librespot's audio-thread join.
>    This task needs an explicit `shutdown()` hopped to a background executor.
>    `bopify_engine_create` blocks for the whole network login and is subject
>    to the same rule.
> 4. **The event callback can fire before `bopify_engine_create` returns**
>    (librespot emits a volume event during login), so nothing may force-unwrap
>    a handle assigned from the create call.
> 5. **Commands need no serialisation, with one carve-out:** never issue a
>    command synchronously from inside the event callback — that can deadlock
>    against a concurrent destroy. The header documents this.
> 6. **A terminal `Failed` does not mean commands start failing.** After a
>    forwarder panic the Rust engine stays `alive`, so commands keep returning
>    success while the stream has already reported failure.
>

**Files:**
- Create: `Packages/BopifyCore/Sources/BopifyPlayback/LibrespotEngine.swift`
- Test: `Packages/BopifyCore/Tests/PlaybackTests/LibrespotEngineTests.swift`

**Interfaces:**
- Consumes: `EventBridge` (Task 7), `CBopifyCore` (Task 7), `PlaybackEngine` (Task 6).
- Produces: `final class LibrespotEngine: PlaybackEngine` with `init(accessToken: String, deviceName: String) throws` and `deinit` releasing the handle.

- [ ] **Step 1: Write the failing test**

Only the parts that need no Spotify account are automated. Playback itself is Task 14's manual acceptance check.

```swift
// Packages/BopifyCore/Tests/PlaybackTests/LibrespotEngineTests.swift
import Testing
@testable import BopifyPlayback
import BopifyDomain

@Suite("LibrespotEngine")
struct LibrespotEngineTests {
    @Test func rejectsAnInvalidTokenWithATypedError() {
        #expect(throws: (any Error).self) {
            _ = try LibrespotEngine(accessToken: "not-a-real-token", deviceName: "Bopify Test")
        }
    }

    @Test func mapsEveryFFICodeToADistinctError() {
        #expect(PlayerError(ffiCode: -2) == .playbackSessionLost)
        #expect(PlayerError(ffiCode: -3) == .authExpired)
        #expect(PlayerError(ffiCode: -4) == .premiumRequired)
        #expect(PlayerError(ffiCode: -5) == .networkUnavailable)
        #expect(PlayerError(ffiCode: -99) == .unknown)
        #expect(PlayerError(ffiCode: 12345) == .unknown)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/BopifyCore && swift test --filter LibrespotEngine`
Expected: FAIL — `cannot find 'LibrespotEngine' in scope`.

- [ ] **Step 3: Implement**

```swift
// Packages/BopifyCore/Sources/BopifyPlayback/LibrespotEngine.swift
import Foundation
import BopifyDomain
import CBopifyCore

public final class LibrespotEngine: PlaybackEngine, @unchecked Sendable {
    public var events: AsyncStream<PlaybackEvent> { bridge.events }

    private let bridge: EventBridge
    private let handle: OpaquePointer

    /// Blocking: connects to Spotify. Call from a @concurrent context, never
    /// from the main actor.
    public init(accessToken: String, deviceName: String) throws {
        let bridge = EventBridge()
        var code: Int32 = 0
        guard let handle = bopify_engine_create(accessToken, deviceName, bopifyEventTrampoline,
                                                bridge.opaqueContext, &code) else {
            throw PlayerError(ffiCode: code)
        }
        self.bridge = bridge
        self.handle = OpaquePointer(handle)
    }

    deinit {
        bridge.finish()
        bopify_engine_destroy(UnsafeMutablePointer(handle))
    }

    private func perform(_ body: () -> Int32) throws {
        let code = body()
        guard code == 0 else { throw PlayerError(ffiCode: code) }
    }

    public func activate() async throws { try perform { bopify_activate(UnsafeMutablePointer(handle)) } }
    public func resume() async throws   { try perform { bopify_play(UnsafeMutablePointer(handle)) } }
    public func pause() async throws    { try perform { bopify_pause(UnsafeMutablePointer(handle)) } }
    public func next() async throws     { try perform { bopify_next(UnsafeMutablePointer(handle)) } }
    public func previous() async throws { try perform { bopify_previous(UnsafeMutablePointer(handle)) } }

    public func seek(to milliseconds: Int64) async throws {
        try perform { bopify_seek(UnsafeMutablePointer(handle), UInt32(max(0, milliseconds))) }
    }

    public func setVolume(_ value: Double) async throws {
        let scaled = UInt16(max(0, min(1, value)) * Double(UInt16.max))
        try perform { bopify_set_volume(UnsafeMutablePointer(handle), scaled) }
    }

    public func load(_ request: PlayRequest) async throws {
        try perform {
            bopify_load(UnsafeMutablePointer(handle),
                        request.contextURI.rawValue,
                        request.startTrackURI?.rawValue,
                        UInt32(max(0, request.startPositionMs)))
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Packages/BopifyCore && swift test`
Expected: PASS, whole suite. The invalid-token test makes a real network attempt and may take a few seconds.

- [ ] **Step 5: Commit**

```bash
git add Packages/BopifyCore
git commit -m "Add the librespot-backed playback engine" -m "Wraps the C ABI behind the same protocol the stub implements, so
everything above the seam is unchanged by which engine is installed."
```

---

### Task 14: The app — menu bar, views, wiring, and manual acceptance

> **AMENDMENT 2026-09-22 — carried forward from Tasks 4, 7, 13 and the spike.**
> Seven items this task owns that the text below predates.
>
> 1. **`shutdown()` is not on the `PlaybackEngine` protocol.** `PlayerModel`
>    holds `any PlaybackEngine`, so the natural composition
>    `PlayerModel(engine: LibrespotEngine(...))` **erases the only route to
>    teardown**. The entire "a mistake is a leak, never a use-after-free"
>    property rests on `shutdown()` actually being reachable. Either keep a
>    reference to the concrete `LibrespotEngine` alongside the model, or add
>    `shutdown()` to the protocol — the latter also touches
>    `StubPlaybackEngine`. Decide deliberately; do not let it fall out.
> 2. **`LibrespotEngine.init` has no cancellation check** and no suspension
>    point after its guard, while `bopify_engine_create` blocks for the whole
>    network login. A cancelled enclosing task — a `.task` on a disappearing
>    view is the realistic case here — still runs the login to completion and
>    drops a live engine, leaking the Rust runtime and librespot's audio
>    thread for the process lifetime. Do not attach engine creation to a view
>    whose lifetime is shorter than the sign-in.
> 3. **Unify the bundle identifier.** The log subsystem is
>    `my.snsoft.bopify` (`BopifyLog.swift`) and the keychain service is
>    `my.bopify.tokens` (`TokenStore.swift`). Set the app's bundle ID and
>    reconcile all three **before first real use**: changing the keychain
>    service string after a token is stored orphans it and silently forces a
>    re-sign-in.
>
>    *Resolved 2026-09-22.* All three are now `my.snsoft.bopify`: the bundle
>    identifier (`PRODUCT_BUNDLE_IDENTIFIER`), the log subsystem, and the
>    keychain service default in `KeychainTokenStore.init`. Done before any
>    token was ever stored, so nothing was orphaned. `TokenStoreTests` was
>    unaffected — it already passes a unique per-run service string rather
>    than relying on the default.
> 4. **Re-test the data-protection keychain.** Spec §10 Q3 was resolved *no*
>    (`errSecMissingEntitlement`, -34018) **because no Xcode project or
>    provisioning profile existed**. This task creates one. Re-run the check
>    with `kSecUseDataProtectionKeychain: true`; if it now succeeds, drop the
>    documented legacy-keychain fallback.
>
>    *Withdrawn 2026-09-22 — the premise was wrong.* Creating an Xcode
>    project does not create a provisioning profile; a signing team does, and
>    this is a build-from-source personal tool with none. Checked on the
>    built product: `Signature=adhoc`, `TeamIdentifier=not set`, no
>    `Contents/embedded.provisionprofile`, and no `application-identifier` or
>    `keychain-access-groups` entitlement. Per TN3137 the data-protection
>    keychain needs exactly those, so the -34018 result is unchanged and
>    spec §10 Q3 stands resolved *no*. The legacy-keychain fallback in
>    `KeychainTokenStore` stays, and its comment is already accurate.
>    Revisit only if the app is ever signed with a real team.
> 5. **Watch for a hang on first teardown.** `bopify_engine_destroy` joins
>    the Rust runtime and then librespot's audio thread, whose network work
>    was driven by the runtime just shut down. It is plausible that cancelled
>    fetches close their channels and the thread exits; it is not proven, and
>    there is no timeout. This task is the first real exercise of that path.
> 6. **The manual walk is the first test of every command.** Nothing
>    automated proves any command's actual effect — a transposed argument
>    would not have been caught. Exercise play, pause, next, previous, seek
>    and volume individually and confirm each does what it says.
> 7. **A terminal `Failed` does not stop commands succeeding.** After a
>    forwarder panic the Rust engine stays `alive`, so the UI can show an
>    error while commands still return success. Do not infer engine health
>    from command return values.
>

**Files:**
- Create: `Config/Shared.xcconfig`, `Config/Bopify.xcconfig`
- Create: `App/BopifyApp.swift`, `App/AppEnvironment.swift`
- Create: `App/MenuBar/StatusItemController.swift`, `App/MenuBar/StatusPanel.swift`
- Create: `App/Views/{MiniPlayerView,SignedOutView,TransportControls,ArtworkView}.swift`
- Create: `App/Localizable.xcstrings`, `App/Bopify.entitlements`
- Create: `Bopify.xcodeproj` (via Xcode)

**Interfaces:**
- Consumes: `PlayerModel`, `LibrespotEngine`, `SpotifyAuthService`, `PlaybackState`.
- Produces: a runnable `.app`.

- [ ] **Step 1: Create the Xcode project**

In Xcode 27: File → New → Project → macOS → App. Name `Bopify`, interface SwiftUI, language Swift. Save at the repo root so the folder becomes `App/`.

Then, and this matters:

- Set **Swift Language Version to 6** in build settings. The template ships 5.0.
- Set **macOS Deployment Target to 14.0**, matching `MACOSX_DEPLOYMENT_TARGET` in `scripts/build-rust.sh`.
- Add `Packages/BopifyCore` as a local package dependency; link `BopifyDomain`, `BopifyAuth`, `BopifyPlayback`.
- Delete the generated `ContentView.swift`.
- Right-click the `App` group → convert to a **buildable folder** if it is not already one, so adding files never edits `project.pbxproj`.

- [ ] **Step 2: Configure Info.plist and entitlements**

Add to the target's Info.plist: `Application is agent (UIElement)` = `YES` (`LSUIElement`). Without it a menu-bar app shows a Dock icon.

```bash
mkdir -p App Config
cat > App/Bopify.entitlements <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
</dict>
</plist>
EOF
```

`network.server` is required for the OAuth loopback listener. The entitlement's discussion text mentions other computers, which reads as though loopback were exempt — it is not; the listener needs it.

```bash
cat > Config/Shared.xcconfig <<'EOF'
SWIFT_VERSION = 6
MACOSX_DEPLOYMENT_TARGET = 14.0
SWIFT_STRICT_CONCURRENCY = complete
CODE_SIGN_ENTITLEMENTS = App/Bopify.entitlements
EOF
cat > Config/Bopify.xcconfig <<'EOF'
#include "Shared.xcconfig"
PRODUCT_NAME = Bopify
PRODUCT_BUNDLE_IDENTIFIER = my.bopify.app
EOF
```

Assign `Config/Bopify.xcconfig` to both Debug and Release in the project's Info tab.

- [ ] **Step 3: Write the menu-bar surface**

`MenuBarExtra` is not used: `.menuBarExtraStyle(.window)` offers no way to dismiss the window programmatically and no access to the status item or its window (FB11984872, still open).

```swift
// App/MenuBar/StatusPanel.swift
import AppKit
import SwiftUI

/// Borderless, non-activating panel anchored under the status item.
/// Non-activating keeps the app out of the foreground; canBecomeKey keeps
/// keyboard events working inside it.
final class StatusPanel: NSPanel {
    init<Content: View>(content: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        backgroundColor = .clear
        contentView = NSHostingView(rootView: content)
    }

    override var canBecomeKey: Bool { true }
}
```

```swift
// App/MenuBar/StatusItemController.swift
import AppKit
import SwiftUI

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private var panel: StatusPanel?
    private var outsideClickMonitor: Any?

    init<Content: View>(content: Content) {
        statusItem = NSStatusBar.system.statusItem(withLength: .variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Bopify")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        panel = StatusPanel(content: content)
    }

    @objc private func toggle() {
        guard let panel, let button = statusItem.button else { return }
        if panel.isVisible { dismiss(); return }

        if let frame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) {
            let origin = NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY - panel.frame.height - 6)
            panel.setFrameOrigin(origin)
        }
        panel.makeKeyAndOrderFront(nil)

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    private func dismiss() {
        panel?.orderOut(nil)
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }
}
```

- [ ] **Step 4: Write the composition root and views**

```swift
// App/AppEnvironment.swift
import Foundation
import Observation
import BopifyAuth
import BopifyDomain
import BopifyPlayback

/// The only place concrete implementations are chosen.
@MainActor
@Observable
final class AppEnvironment {
    private(set) var authState: AuthState = .signedOut
    private(set) var player: PlayerModel?

    @ObservationIgnored private let auth = SpotifyAuthService(clientID: Secrets.spotifyClientID)

    func restoreOrPromptSignIn() async {
        if await auth.restore() != nil { await connect() }
    }

    func signIn() async {
        authState = .authenticating
        do {
            _ = try await auth.signIn()
            await connect()
        } catch {
            authState = .error(error as? PlayerError ?? .unknown)
        }
    }

    func signOut() async {
        player?.stop()
        player = nil
        await auth.signOut()
        authState = .signedOut
    }

    private func connect() async {
        do {
            let token = try await auth.validAccessToken()
            // Engine creation connects to Spotify and blocks; keep it off
            // the main actor.
            let engine = try await makeEngine(token: token)
            let model = PlayerModel(engine: engine)
            model.start()
            model.activate()
            player = model
            authState = .signedIn
        } catch {
            authState = .error(error as? PlayerError ?? .unknown)
        }
    }

    @concurrent
    private nonisolated func makeEngine(token: String) async throws -> LibrespotEngine {
        try LibrespotEngine(accessToken: token, deviceName: "Bopify")
    }
}

enum Secrets {
    /// Not a secret: PKCE exists so an installed app needs no client secret.
    static let spotifyClientID = "<paste-your-client-id>"
}
```

```swift
// App/Views/TransportControls.swift
import SwiftUI
import BopifyDomain
import BopifyPlayback

struct TransportControls: View {
    let state: PlaybackState
    let model: PlayerModel

    private var isPlaying: Bool { state.phase == .playing }

    var body: some View {
        HStack(spacing: 24) {
            Button(action: model.previous) {
                Image(systemName: "backward.fill")
            }
            .disabled(!state.canPrevious)
            .accessibilityLabel(Text("transport.previous"))

            Button(action: model.togglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
            }
            // State is never carried by icon shape alone.
            .accessibilityLabel(Text(isPlaying ? "transport.pause" : "transport.play"))
            .accessibilityValue(Text(isPlaying ? "transport.state.playing" : "transport.state.paused"))

            Button(action: model.next) {
                Image(systemName: "forward.fill")
            }
            .disabled(!state.canNext)
            .accessibilityLabel(Text("transport.next"))
        }
        .buttonStyle(.plain)
    }
}
```

Write `ArtworkView` (async image with a deliberate placeholder when `artwork` is nil), `SignedOutView` (sign-in button plus the authenticating and error presentations), and `MiniPlayerView` (switches on `authState`, and within `signedIn` on `state.phase`, covering idle, loading, playing, paused and error; shows a distinct message when `isActiveDevice` is false). Every string is a key in `Localizable.xcstrings` — no literals.

If Task 2 answered Q5 *no*, `MiniPlayerView`'s idle state needs a control that calls `model.load(...)` with a context URI instead of instructing the user to hand off.

```swift
// App/BopifyApp.swift
import SwiftUI

@main
struct BopifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment = AppEnvironment()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(content: MiniPlayerView(environment: environment))
        Task { await environment.restoreOrPromptSignIn() }
    }
}
```

- [ ] **Step 5: Build and run**

```bash
./scripts/build-rust.sh
xcodebuild -project Bopify.xcodeproj -scheme Bopify -configuration Debug build
```

Expected: builds with no concurrency errors. Then run from Xcode.

- [ ] **Step 6: Manual acceptance**

Automated tests cannot assert any of this. Walk it and record the result.

- [ ] Menu-bar icon appears; no Dock icon (`LSUIElement`)
- [ ] Clicking opens the panel; clicking outside dismisses it
- [ ] "Sign in with Spotify" opens the browser; consent returns to a signed-in state (AUTH-02, AUTH-03)
- [ ] Denying consent returns cleanly to signed out (AUTH-04)
- [ ] Playback starts — via Connect handoff, or via the context-URI control if Q5 was *no*
- [ ] **Audio is audible and comes from this Mac with the official Spotify desktop app not running** (PLAY-01)
- [ ] Artwork, title and artist match what is playing (PLAY-04)
- [ ] Play/pause works and the icon reflects the engine's state, not the click (PLAY-03)
- [ ] Next and previous change tracks (PLAY-02)
- [ ] Pausing from your phone updates the panel within a second
- [ ] Taking the device over from another Spotify client shows the inactive-device state, not a phantom paused track
- [ ] Closing the panel does not stop playback (PLAY-11)
- [ ] Quit and relaunch restores the session without a browser prompt (AUTH-05)
- [ ] VoiceOver announces play/pause and track metadata meaningfully (A11Y-02, A11Y-03)

Record failures as issues. A red item here is a bug in this slice, not a follow-up.

- [ ] **Step 7: Commit**

```bash
git add App Config Bopify.xcodeproj
git commit -m "Add the menu-bar app and wire the real playback engine" -m "NSStatusItem with a non-activating panel rather than MenuBarExtra,
which still cannot be dismissed programmatically. Completes the first
slice: signing in results in audio playing from this Mac."
```

---

## Self-Review

**Spec coverage.** §3 structure → Tasks 1, 5, 14. §4 domain → Task 6. §5 C ABI → Task 4 (all eleven functions — see the amendment at Task 4's Interfaces — including `bopify_activate` and the widened `bopify_load`). §6 concurrency → Tasks 7 and 12. §7 first feature and its six steps → Tasks 2, 4, 7, 11, 12, 14 in that order. §8 error taxonomy → Task 6 `PlayerError` plus Task 3's Rust codes; `premiumRequired` is mapped explicitly in `classify_connect_error`. §9 test boundary → automated in Tasks 3, 5–13; manual in Task 14 Step 6. §10 open questions → Q1 and Q5 in Task 2, Q2 in Task 1 Step 3, Q3 in Task 11 Step 4, Q4 in Task 2 Step 4. §11 deviations → the `isActiveDevice` behaviour is asserted in Task 12. §12 risks → no task required.

**Two gaps found and left deliberate.** `bopify_update_token` returns `SessionLost` rather than swapping credentials in place, because librespot exposes no documented way to do it; the facade's rebuild path covers the case, and Task 4 Step 3 says so in a comment. And session-rebuild-on-expiry is not exercised by an automated test — it needs a >1 hour session. Both are worth a follow-up slice; neither blocks this one.

**Type consistency.** `PlaybackEvent` cases match the Rust `WireEvent` tags one-for-one (`trackChanged`, `playing`, `paused`, `seeked`, `positionCorrection`, `volumeChanged`, `loading`, `endOfTrack`, `activeDeviceChanged`, `failed`). Error codes agree between Task 3's Rust `code()` and Task 6's `PlayerError(ffiCode:)`. Volume crosses as `u16` and is normalised to `0...1` in exactly one place (Task 6's decoder), with `LibrespotEngine.setVolume` scaling back. `PlayRequest` fields match `bopify_load`'s three parameters.

**Corrected 2026-09-21 (found building Task 2).** `Spirc::new` connects the
session internally, so the pre-connect `session.connect(...)` that Tasks 2 and
4 originally carried made `Spirc::new` fail at runtime with
`SessionError::NotConnected` -- code that compiles cleanly and dies on first
run. Both call sites are fixed. Error classification moved onto `Spirc::new`
so `PremiumRequired`/`AuthInvalid` stay reachable. Note `Spirc::new` passes
`store_credentials: true` internally.

**Standing caveat on the Rust code.** librespot is pinned to a `dev` revision and the signatures in Tasks 2 and 4 were read at tag v0.8.0. `SoftMixer::open`, `Spirc::new`'s tuple return, and the `LoadRequest` option type names are the most likely to have moved. Where the pinned source disagrees with this plan, the source wins — fix the code, then correct the plan.
