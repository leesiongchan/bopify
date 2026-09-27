# Remote Mirror and Play Here (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While another Connect device plays, Bopify's Monolith player mirrors it, with the device's track, status and moving progress. When nothing plays, it keeps the last track and says "Not playing". In both states, Play moves the account's session onto this Mac.

**Architecture:** Our librespot patch gains a `RemoteState` player event. A pure `remote_playback(&Cluster, own_id)` builds it from `player_state` using server clocks only. `startup_decision` now returns it for its `Remote` branch. Spirc emits it, change-only, from the startup cluster and from every cluster update while inactive. A new `SpircCommand::PlayHere` fetches a fresh cluster and runs `startup_decision` on it:
- another device playing → a spawned, non-blocking transfer request;
- a usable last session → restore it and play;
- otherwise → Liked Songs, playing.

On the Rust side, bopify-core adds the track's metadata on a latest-wins worker before the event reaches Swift, and exposes `bopify_play_here`. On the Swift side, `PlaybackState.remote` holds the mirror. `PlayerModel` interpolates the mirror's position and routes an inactive Play to `playHere()`. The Monolith view shows the mirror or the stale state without the attention rim.

**Tech Stack:** Rust (librespot `939dc5e` plus `rust/patches/librespot-queue-selection.patch`, rust-protobuf 3, tokio, serde), a C ABI, Swift 6 with Swift Testing, SwiftUI and AppKit on macOS (arm64), and native probe apps built by `docs/superpowers/verification/run-monolith-probe.py`.

**Spec:** `docs/superpowers/specs/2026-09-26-startup-restore-design.md`, section "Phase 2: mirror" (revised 2026-09-27). Read it and its appendix run 5 first. Phase 1's plan, `docs/superpowers/plans/2026-09-26-startup-restore-phase-1.md`, shows the patterns this plan extends.

## Global Constraints

- **Pinned librespot.** The revision is `939dc5ee9d833e1980f9495241219d9d4868a061`, checked out at `.build/librespot-939dc5e`. The only tracked record of our librespot changes is `rust/patches/librespot-queue-selection.patch`.
- **Regenerate the patch after every change to `.build/librespot-939dc5e`.**
  1. Run `git -C .build/librespot-939dc5e diff --no-ext-diff --binary HEAD > rust/patches/librespot-queue-selection.patch`.
  2. Run `./scripts/prepare-librespot.sh`. It must print `Pinned librespot queue patch verified.`
- **Never run `git checkout`, `git restore`, `git stash`, `git reset`, `git add` or `git commit` inside `.build/librespot-939dc5e`.** The patch lives only in that checkout's working tree, so any of those would destroy it or record it in the wrong repository. The only git command you run there is the `diff` above.
- **Run every command from the worktree root**, `/Users/leesiongchan/Projects/bopify/.worktrees/remote-mirror`. A `cd` into `.build/` or `Packages/` carries over to later commands, and `.build/librespot-939dc5e` is a separate git repository. This harness also refuses compound shell commands involving git, and commands with computed arguments. Run each command on its own line, with literal paths.
- **The connect crate has `#![warn(missing_docs)]`.** Every new `pub` item in `connect/` gets a doc comment. Document new `pub` items in `playback/` too.
- **Don't run `cargo fmt`.** It would reformat upstream librespot files, which churns the patch, and bopify-core files are not rustfmt-clean either. Format new code by hand to match the lines around it.
- **The wire rule.** A change to `rust/crates/bopify-core/src/event.rs` is a breaking change to `BopifyDomain.PlaybackEvent`, so both change in the same commit. `PlayerModel.apply` is exhaustive over `PlaybackEvent`, so its fold arm lands in that commit too.
- **Check `Bopify/Bopify/Localizable.xcstrings` before editing it.** If `git status --short Bopify/Bopify/Localizable.xcstrings` shows it modified before your edit, **stop and ask**. Never commit someone else's hunks. The main checkout has the user's own uncommitted edits to that file: never touch the main checkout.
- **The shell is zsh.** `log` is a builtin, so use `/usr/bin/log`. `tail` may be aliased, so use `command tail`.
- **Commit messages** are an imperative subject under 72 characters, plus a body that explains why. No `feat:` prefixes. No `Co-Authored-By` lines: AGENTS.md overrides any tool default.
- **Logging.**
  - Device names are personal data, and so are track titles. Our `playback` category is public, so log presence only, never a name or title.
  - librespot's category is private and capped at Warn, so its `debug!`/`info!` lines are invisible in normal builds. Use `warn!` there only for something a live run must see.
- **Comments** explain why, in at most two sentences.
- **Every commit ends green.** `cargo test --manifest-path rust/Cargo.toml` passes. So do `cargo test --manifest-path rust/Cargo.toml -p librespot-connect` whenever the librespot checkout changed, and `swift test --package-path Packages/BopifyCore` whenever Swift or the ABI changed. Any commit touching `Bopify/` must also pass the app build.

## Commands used throughout

```sh
# Rust: our crate, then the patched connect crate (its tests run through our workspace)
cargo test --manifest-path rust/Cargo.toml
cargo test --manifest-path rust/Cargo.toml -p librespot-connect
# Rebuild the static library, C header and xcframework after any Rust or ABI change
./scripts/build-rust.sh
# Swift package
swift test --package-path Packages/BopifyCore
# App, into a derived-data directory the probe runner can read
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-mirror-build build
```

## File Structure

| File | Change | Responsibility |
| --- | --- | --- |
| `.build/librespot-939dc5e/playback/src/player.rs` | modify | `RemoteState`, `PlayerEvent::RemotePlayback`, and its emitter |
| `.build/librespot-939dc5e/connect/src/startup.rs` | modify | `StartupDecision::Remote(RemoteState)`, pure `remote_playback`, `remote_changed` |
| `.build/librespot-939dc5e/connect/src/spirc.rs` | modify | Emit the mirror while inactive; `SpircCommand::PlayHere`, `Spirc::play_here`, `restore_session` |
| `.build/librespot-939dc5e/connect/Cargo.toml` | modify | tokio `rt` feature, for the spawned transfer request |
| `rust/patches/librespot-queue-selection.patch` | regenerate | Tracked copy of all of the above |
| `rust/crates/bopify-core/src/event.rs` | modify | `WireRemote`, `WireEvent::RemotePlayback`, its translation |
| `rust/crates/bopify-core/src/queue.rs` | modify | Share the track `lookup` with the mirror |
| `rust/crates/bopify-core/src/remote.rs` | **create** | Latest-wins track metadata for the mirror |
| `rust/crates/bopify-core/src/lib.rs` | modify | `mod remote;` |
| `rust/crates/bopify-core/src/engine.rs` | modify | Route the mirror through `remote.rs`; `Engine::play_here` |
| `rust/crates/bopify-core/src/ffi.rs` | modify | `bopify_play_here` |
| `Packages/BopifyCore/Sources/BopifyDomain/PlaybackState.swift` | modify | `RemotePlayback`, `PlaybackState.remote` |
| `Packages/BopifyCore/Sources/BopifyDomain/PlaybackEvent.swift` | modify | `.remotePlayback` decoding |
| `Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift` | modify | `playHere()` |
| `Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift` | modify | Fold the mirror; `playHere()`, `canPlayHere`; mirror-aware display clock |
| `Packages/BopifyCore/Sources/BopifyPlayback/PlayerPresentation.swift` | modify | `InactiveStatus` |
| `Packages/BopifyCore/Sources/BopifyPlayback/LibrespotEngine.swift`, `StubPlaybackEngine.swift` | modify | `playHere()` |
| `Packages/BopifyCore/Tests/...` (`PlaybackEventTests`, `PlayerModelTests`, `PlayerPresentationTests`) | modify | Tests for all of the above |
| `Bopify/Bopify/AppEnvironment.swift` | modify | `isListening` includes a mirror |
| `Bopify/Bopify/Views/MonolithPlayerView.swift` | modify | Mirror track, clock and status; no rim; queue and favourite disabled |
| `Bopify/Bopify/Views/TransportControls.swift` | modify | Play is enabled when it can play here |
| `Bopify/Bopify/PlaybackState+Localized.swift` | modify | `.idle` names the device or says "Not playing" |
| `Bopify/Bopify/Localizable.xcstrings` | modify | `player.notPlaying`, `player.remote.paused %@` |
| `docs/superpowers/verification/MonolithMirrorProbe.swift` | **create** | Native probe: mirror, paused mirror, stale state, Play, no rim |
| `docs/superpowers/verification/run-monolith-probe.py` | modify | `--probe mirror` |
| `docs/superpowers/verification/MonolithVisualProbe.swift` | modify | Inactive status now reads "Not playing" |
| `docs/superpowers/specs/2026-09-21-bopify-foundation-design.md`, `README.md` | modify | Protocol, ABI and patch descriptions |
| `docs/superpowers/specs/2026-09-26-startup-restore-design.md` | modify | Two implementation rulings; status after live verification |
| `docs/superpowers/verification/2026-09-26-startup-restore.md` | modify | Phase 2 live evidence |

---

### Before Task 1: confirm the baseline

This worktree already has `.build/librespot-939dc5e` and `artifacts/`. If either is missing, run `./scripts/build-rust.sh` first. It clones and patches librespot, then builds the xcframework.

- [ ] Run `./scripts/prepare-librespot.sh`. Expected: `Pinned librespot queue patch verified.`
- [ ] Run `git -C .build/librespot-939dc5e rev-parse HEAD`. Expected: `939dc5ee9d833e1980f9495241219d9d4868a061`.
- [ ] Run `cargo test --manifest-path rust/Cargo.toml`, then `cargo test --manifest-path rust/Cargo.toml -p librespot-connect`, then `swift test --package-path Packages/BopifyCore`. Expected: all green. This is the baseline, so any later failure belongs to this plan's changes.

---

### Task 1: `RemotePlayback` crosses from librespot into Swift state

The wire rule makes this one commit: the librespot event, its JSON, Swift decoding and the fold. Nothing emits the event yet.

**Files:**
- Modify: `.build/librespot-939dc5e/playback/src/player.rs` (anchors: `EmitStartupResolvedEvent` at ~148, `enum StartupOutcome` at ~164, `StartupResolved {` at ~295, `emit_startup_resolved_event` at ~715, the handler at ~2420, the Debug arm at ~2638)
- Modify: `rust/crates/bopify-core/src/event.rs`
- Modify: `Packages/BopifyCore/Sources/BopifyDomain/PlaybackState.swift`, `PlaybackEvent.swift`
- Modify: `Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift`
- Test: `rust/crates/bopify-core/src/event.rs` tests, `Packages/BopifyCore/Tests/DomainTests/PlaybackEventTests.swift`, `Packages/BopifyCore/Tests/PlaybackTests/PlayerModelTests.swift`
- Regenerate: `rust/patches/librespot-queue-selection.patch`

**Interfaces:**
- Produces, in Rust (`librespot_playback::player`):
  - `pub struct RemoteState { pub device_name: String, pub track_uri: String, pub is_playing: bool, pub position_ms: u32, pub duration_ms: u32 }`, deriving `Clone, Debug, PartialEq, Eq`;
  - `PlayerEvent::RemotePlayback { remote: Option<RemoteState> }`;
  - `Player::emit_remote_playback_event(&self, remote: Option<RemoteState>)`.
- Produces, in bopify-core (`crate::event`): `pub struct WireRemote { pub device_name: String, pub track_uri: String, pub track: Option<WireTrack>, pub is_playing: bool, pub position_ms: u32, pub duration_ms: u32 }`, and `WireEvent::RemotePlayback { remote: Option<WireRemote> }`. `translate` always sets `track: None`.
- Produces, in Swift:
  - `public struct RemotePlayback: Hashable, Sendable` with `deviceName: String`, `trackURI: SpotifyURI`, `track: Track?`, `isPlaying: Bool`, `positionMs: Int64` and `durationMs: Int64`, plus a memberwise `public init` in that order;
  - `PlaybackEvent.remotePlayback(RemotePlayback?)`;
  - `PlaybackState.remote: RemotePlayback?`, which is always `nil` while `isActiveDevice` is true.
- The wire JSON is `{"type":"remotePlayback","remote":null}` or `{"type":"remotePlayback","remote":{"deviceName":…,"trackUri":…,"track":<WireTrack object>|null,"isPlaying":…,"positionMs":…,"durationMs":…}}`.

- [ ] **Step 1: Write the failing Rust wire test**

In `rust/crates/bopify-core/src/event.rs`, change the import line to:

```rust
use librespot_playback::player::{PlayerEvent, RemoteState, StartupOutcome};
```

Append to `mod tests`, after `startup_outcomes_carry_a_device_name_only_when_remote`:

```rust
    #[test]
    fn remote_playback_serialises_the_mirror_or_null() {
        let none = translate(PlayerEvent::RemotePlayback { remote: None }).unwrap();
        assert_eq!(
            serde_json::to_string(&none).unwrap(),
            r#"{"type":"remotePlayback","remote":null}"#
        );
        let some = translate(PlayerEvent::RemotePlayback {
            remote: Some(RemoteState {
                device_name: "iPhone".into(),
                track_uri: "spotify:track:abc".into(),
                is_playing: true,
                position_ms: 7_500,
                duration_ms: 200_000,
            }),
        })
        .unwrap();
        assert_eq!(
            serde_json::to_string(&some).unwrap(),
            r#"{"type":"remotePlayback","remote":{"deviceName":"iPhone","trackUri":"spotify:track:abc","track":null,"isPlaying":true,"positionMs":7500,"durationMs":200000}}"#
        );
    }
```

- [ ] **Step 2: Run it and confirm it fails**

Run `cargo test --manifest-path rust/Cargo.toml remote_playback`. Expected: a compile error, because `RemoteState` and `PlayerEvent::RemotePlayback` don't exist.

- [ ] **Step 3: Add the librespot event**

In `.build/librespot-939dc5e/playback/src/player.rs`, make these edits:

1. In `enum PlayerCommand`, after `EmitStartupResolvedEvent(StartupOutcome),`, add:

```rust
    EmitRemotePlaybackEvent(Option<RemoteState>),
```

2. Directly after the closing `}` of `pub enum StartupOutcome`, add:

```rust

/// What another Connect device is playing, mirrored while this device is
/// inactive. Emitted only when `ConnectConfig::startup_restore` is set.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteState {
    /// The device's name, as Spotify's device picker shows it.
    pub device_name: String,
    /// The playing track's URI.
    pub track_uri: String,
    /// False while the device is paused.
    pub is_playing: bool,
    /// The position as of the cluster's server timestamp.
    pub position_ms: u32,
    /// The track's duration, as the device reported it.
    pub duration_ms: u32,
}
```

3. In `pub enum PlayerEvent`, after the `StartupResolved { outcome: StartupOutcome, },` variant, add:

```rust
    /// Fired when a mirrored device's playback changes; `None` once no other device plays.
    RemotePlayback {
        remote: Option<RemoteState>,
    },
```

4. After `pub fn emit_startup_resolved_event`, add:

```rust

    pub fn emit_remote_playback_event(&self, remote: Option<RemoteState>) {
        self.command(PlayerCommand::EmitRemotePlaybackEvent(remote));
    }
```

5. In the command handler, after the `PlayerCommand::EmitStartupResolvedEvent(outcome) => { … }` arm, add:

```rust

            PlayerCommand::EmitRemotePlaybackEvent(remote) => {
                self.send_event(PlayerEvent::RemotePlayback { remote })
            }
```

6. In `impl fmt::Debug for PlayerCommand`, after the `EmitStartupResolvedEvent` arm, add:

```rust
            // Presence only: the state carries the user's device name.
            PlayerCommand::EmitRemotePlaybackEvent(remote) => f
                .debug_tuple("EmitRemotePlaybackEvent")
                .field(&remote.is_some())
                .finish(),
```

If the compiler reports another non-exhaustive `match` on `PlayerEvent` or `PlayerCommand`, add the new variant there next to its `StartupResolved` sibling, the same way.

- [ ] **Step 4: Add the wire event and its translation**

In `rust/crates/bopify-core/src/event.rs`:

1. After `pub struct WireTrack { … }`, add:

```rust

/// Another device's playback, mirrored while Bopify is inactive.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WireRemote {
    pub device_name: String,
    pub track_uri: String,
    pub track: Option<WireTrack>,
    pub is_playing: bool,
    pub position_ms: u32,
    pub duration_ms: u32,
}
```

2. In `enum WireEvent`, after the `StartupResolved { … }` variant, add:

```rust
    RemotePlayback {
        remote: Option<WireRemote>,
    },
```

3. In `translate`, after `PlayerEvent::StartupResolved { outcome } => Some(startup_resolved(outcome)),`, add:

```rust
        PlayerEvent::RemotePlayback { remote } => Some(remote_playback(remote)),
```

4. After `fn startup_resolved`, add:

```rust

fn remote_playback(remote: Option<RemoteState>) -> WireEvent {
    // Presence only: a device name is whatever the user called their phone.
    log::debug!("event: remote playback present={}", remote.is_some());
    WireEvent::RemotePlayback {
        remote: remote.map(|remote| WireRemote {
            device_name: remote.device_name,
            track_uri: remote.track_uri,
            track: None,
            is_playing: remote.is_playing,
            position_ms: remote.position_ms,
            duration_ms: remote.duration_ms,
        }),
    }
}
```

- [ ] **Step 5: Run the Rust tests and regenerate the patch**

Run `cargo test --manifest-path rust/Cargo.toml`. Expected: PASS, including `remote_playback_serialises_the_mirror_or_null`. Then run `cargo test --manifest-path rust/Cargo.toml -p librespot-connect` (expected: PASS). Regenerate the patch and verify it as the Global Constraints describe.

- [ ] **Step 6: Write the failing Swift decoding tests**

In `Packages/BopifyCore/Tests/DomainTests/PlaybackEventTests.swift`, add inside the suite, after `rejectsAnUnknownOutcomeAndARemoteWithoutADevice`:

```swift
    @Test func decodesARemoteWithAndWithoutMetadata() throws {
        let json = #"""
        {"type":"remotePlayback","remote":{"deviceName":"iPhone","trackUri":"spotify:track:abc",
         "track":{"trackUri":"spotify:track:abc","title":"Title","artists":["A"],"albumTitle":null,"artworkUrl":null,"durationMs":200000},
         "isPlaying":true,"positionMs":7500,"durationMs":200000}}
        """#
        guard case let .remotePlayback(remote?) = try decode(json) else {
            Issue.record("expected a remote"); return
        }
        #expect(remote.deviceName == "iPhone")
        #expect(remote.trackURI.id == "abc")
        #expect(remote.track?.title == "Title")
        #expect(remote.isPlaying)
        #expect(remote.positionMs == 7500)
        #expect(remote.durationMs == 200_000)
        let bare = #"{"type":"remotePlayback","remote":{"deviceName":"iPhone","trackUri":"spotify:track:abc","track":null,"isPlaying":false,"positionMs":0,"durationMs":0}}"#
        guard case let .remotePlayback(withoutMetadata?) = try decode(bare) else {
            Issue.record("expected a remote"); return
        }
        #expect(withoutMetadata.track == nil)
        #expect(try decode(#"{"type":"remotePlayback","remote":null}"#) == .remotePlayback(nil))
    }

    @Test func rejectsARemoteWithAMalformedTrackURI() {
        #expect(throws: (any Error).self) {
            try decode(#"{"type":"remotePlayback","remote":{"deviceName":"iPhone","trackUri":"nope","track":null,"isPlaying":false,"positionMs":0,"durationMs":0}}"#)
        }
    }
```

In `Packages/BopifyCore/Tests/PlaybackTests/PlayerModelTests.swift`, add this helper directly after `private func makeTrack() -> Track { … }`:

```swift
    private func makeRemote(isPlaying: Bool = true, positionMs: Int64 = 1000) -> RemotePlayback {
        RemotePlayback(deviceName: "iPhone", trackURI: SpotifyURI("spotify:track:remote")!, track: nil,
                       isPlaying: isPlaying, positionMs: positionMs, durationMs: 200_000)
    }
```

Then add this test after `startupStaysPendingUntilTheEngineResolvesIt`:

```swift
    @Test(arguments: [PlaybackEvent.playing(positionMs: 0), .paused(positionMs: 0)])
    func theMirrorClearsWhenBopifyBecomesActiveAndStaysCleared(_ takeover: PlaybackEvent) async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.remotePlayback(makeRemote())])
        #expect(model.state.remote == makeRemote())
        await settle(model, engine, [.remotePlayback(nil)])
        #expect(model.state.remote == nil)
        await settle(model, engine, [.remotePlayback(makeRemote()), takeover])
        #expect(model.state.remote == nil)
        // A lookup that finishes after the takeover must not bring the mirror back.
        await settle(model, engine, [.remotePlayback(makeRemote())])
        #expect(model.state.remote == nil)
        await settle(model, engine, [.activeDeviceChanged(isActive: false), .remotePlayback(makeRemote(isPlaying: false))])
        #expect(model.state.remote == makeRemote(isPlaying: false))
    }
```

- [ ] **Step 7: Run it and confirm it fails**

Run `swift test --package-path Packages/BopifyCore`. Expected: a compile error, because `RemotePlayback` and `.remotePlayback` don't exist.

- [ ] **Step 8: Add the Swift state, decoding and fold**

In `Packages/BopifyCore/Sources/BopifyDomain/PlaybackState.swift`:

1. After `public enum StartupPhase { … }`, add:

```swift

/// What another Connect device is playing while Bopify is inactive.
public struct RemotePlayback: Hashable, Sendable {
    public let deviceName: String
    public let trackURI: SpotifyURI
    /// Nil when the metadata lookup failed.
    public let track: Track?
    public let isPlaying: Bool
    /// As of the event's receipt; the player model interpolates from there.
    public let positionMs: Int64
    public let durationMs: Int64

    public init(deviceName: String, trackURI: SpotifyURI, track: Track?,
                isPlaying: Bool, positionMs: Int64, durationMs: Int64) {
        self.deviceName = deviceName; self.trackURI = trackURI; self.track = track
        self.isPlaying = isPlaying; self.positionMs = positionMs; self.durationMs = durationMs
    }
}
```

2. In `PlaybackState`, after `public var startup: StartupPhase = .pending`, add:

```swift
    /// Another device's playback. Always nil while Bopify is the active device.
    public var remote: RemotePlayback?
```

In `Packages/BopifyCore/Sources/BopifyDomain/PlaybackEvent.swift`:

1. After `case startupResolved(StartupOutcome)`, add `case remotePlayback(RemotePlayback?)`.
2. Change the last `CodingKeys` line from `case outcome, deviceName` to `case outcome, deviceName, remote, isPlaying`.
3. In `init(from:)`, after the `case "startupResolved":` block and before `default:`, add:

```swift
        case "remotePlayback":
            self = .remotePlayback(try c.decodeNil(forKey: .remote) ? nil : Self.decodeRemote(from: c.superDecoder(forKey: .remote)))
```

4. After `private static func decodeTrack(from:)`, add:

```swift

    private static func decodeRemote(from decoder: any Decoder) throws -> RemotePlayback {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .trackUri)
        guard let uri = SpotifyURI(raw) else {
            throw DecodingError.dataCorruptedError(forKey: .trackUri, in: c, debugDescription: "malformed Spotify URI")
        }
        return RemotePlayback(
            deviceName: try c.decode(String.self, forKey: .deviceName),
            trackURI: uri,
            track: try c.decodeNil(forKey: .track) ? nil : Self.decodeTrack(from: c.superDecoder(forKey: .track)),
            isPlaying: try c.decode(Bool.self, forKey: .isPlaying),
            positionMs: try c.decode(Int64.self, forKey: .positionMs),
            durationMs: try c.decode(Int64.self, forKey: .durationMs)
        )
    }
```

In `Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift`, inside `apply`:

1. In both the `.playing` and `.paused` arms, add `state.remote = nil` after `state.isActiveDevice = true`.
2. After the `.startupResolved` arm, and before the closing `}` of the `switch`, add:

```swift
        case let .remotePlayback(remote):
            // A lookup still in flight when Bopify took over must not bring the mirror back.
            state.remote = state.isActiveDevice ? nil : remote
            BopifyLog.playback.debug("remote playback present=\(state.remote != nil, privacy: .public)")
```

- [ ] **Step 9: Run the tests and confirm they pass**

Run `swift test --package-path Packages/BopifyCore`. Expected: PASS, including `decodesARemoteWithAndWithoutMetadata`, `rejectsARemoteWithAMalformedTrackURI` and both arguments of `theMirrorClearsWhenBopifyBecomesActiveAndStaysCleared`.

- [ ] **Step 10: Commit**

```bash
git add rust/patches/librespot-queue-selection.patch rust/crates/bopify-core/src/event.rs Packages/BopifyCore/Sources/BopifyDomain/PlaybackState.swift Packages/BopifyCore/Sources/BopifyDomain/PlaybackEvent.swift Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift Packages/BopifyCore/Tests/DomainTests/PlaybackEventTests.swift Packages/BopifyCore/Tests/PlaybackTests/PlayerModelTests.swift
git commit -m "Carry another device's playback from librespot into Swift" -m "Phase 2 mirrors the active Connect device while Bopify is inactive. This adds the event end to end so the wire contract and the Swift fold change together; nothing emits it yet. The fold drops a mirror while Bopify is active, because a metadata lookup can finish after a takeover."
```

---

### Task 2: The mirror's track metadata, latest wins

**Files:**
- Create: `rust/crates/bopify-core/src/remote.rs`
- Modify: `rust/crates/bopify-core/src/queue.rs` (the `start` function)
- Modify: `rust/crates/bopify-core/src/lib.rs`
- Modify: `rust/crates/bopify-core/src/engine.rs` (`supervise_forwarder`, `forward_events` and its test)

**Interfaces:**
- Consumes: `WireRemote` and `WireEvent::RemotePlayback` from Task 1, `track_metadata`, and `EventSink` (`Arc<dyn Fn(WireEvent) + Send + Sync>`, from `engine.rs`).
- Produces:
  - `pub(crate) async fn queue::lookup(session: Session, raw: String) -> Option<WireTrack>`;
  - `pub(crate) fn remote::start(session: Session, sink: EventSink) -> tokio::sync::watch::Sender<Option<WireRemote>>`;
  - `forward_events(events, sink, metadata, remote: watch::Sender<Option<WireRemote>>)`.
- Behaviour: every `RemotePlayback` goes to the worker instead of the sink. The worker emits it with `track` filled from a cache, or after a lookup. A newer event cancels an older lookup, a failed lookup emits `track: None`, and `None` is emitted at once.

- [ ] **Step 1: Write the failing worker tests**

Create `rust/crates/bopify-core/src/remote.rs` with only the tests for now:

```rust
//! Track metadata for the mirrored device, latest-wins, off the transport drain.

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    use tokio::sync::mpsc;

    fn remote(uri: &str, is_playing: bool) -> WireRemote {
        WireRemote {
            device_name: "iPhone".into(),
            track_uri: uri.into(),
            track: None,
            is_playing,
            position_ms: 0,
            duration_ms: 1000,
        }
    }

    fn track(uri: String) -> WireTrack {
        WireTrack { track_uri: uri, title: "Title".into(), artists: vec![], album_title: None, artwork_url: None, duration_ms: 1000 }
    }

    fn recording_sink() -> (EventSink, mpsc::UnboundedReceiver<WireEvent>) {
        let (events, received) = mpsc::unbounded_channel();
        (Arc::new(move |event| { events.send(event).unwrap(); }), received)
    }

    async fn next(received: &mut mpsc::UnboundedReceiver<WireEvent>) -> Option<WireRemote> {
        let event = tokio::time::timeout(std::time::Duration::from_secs(1), received.recv()).await.unwrap().unwrap();
        match event {
            WireEvent::RemotePlayback { remote } => remote,
            other => panic!("expected remotePlayback, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn a_newer_mirror_wins_over_a_slower_lookup() {
        let (tx, rx) = watch::channel(None);
        let (sink, mut received) = recording_sink();
        let started = Arc::new(tokio::sync::Notify::new());
        let signal = started.clone();
        let task = tokio::spawn(run(rx, sink, move |uri: String| {
            let signal = signal.clone();
            async move {
                if uri == "old" {
                    signal.notify_one();
                    std::future::pending::<()>().await;
                }
                Some(track(uri))
            }
        }));
        tx.send_replace(Some(remote("old", true)));
        started.notified().await;
        tx.send_replace(Some(remote("new", true)));
        let mirrored = next(&mut received).await.unwrap();
        assert_eq!(mirrored.track_uri, "new");
        assert_eq!(mirrored.track.unwrap().track_uri, "new");
        assert!(received.try_recv().is_err());
        task.abort();
    }

    #[tokio::test]
    async fn a_cached_track_serves_a_new_position_without_a_lookup() {
        let (tx, rx) = watch::channel(None);
        let (sink, mut received) = recording_sink();
        let calls = Arc::new(AtomicUsize::new(0));
        let observed = calls.clone();
        let task = tokio::spawn(run(rx, sink, move |uri| {
            observed.fetch_add(1, Ordering::SeqCst);
            async move { Some(track(uri)) }
        }));
        tx.send_replace(Some(remote("a", true)));
        assert!(next(&mut received).await.unwrap().track.is_some());
        tx.send_replace(Some(remote("a", false)));
        let paused = next(&mut received).await.unwrap();
        assert!(!paused.is_playing);
        assert!(paused.track.is_some());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        task.abort();
    }

    #[tokio::test]
    async fn no_mirror_and_a_failed_lookup_both_reach_swift() {
        let (tx, rx) = watch::channel(None);
        let (sink, mut received) = recording_sink();
        let task = tokio::spawn(run(rx, sink, |_| async { None }));
        tx.send_replace(Some(remote("a", true)));
        let unresolved = next(&mut received).await.unwrap();
        assert_eq!(unresolved.device_name, "iPhone");
        assert!(unresolved.track.is_none());
        tx.send_replace(None);
        assert!(next(&mut received).await.is_none());
        task.abort();
    }
}
```

In `rust/crates/bopify-core/src/lib.rs`, add `mod remote;` after `mod queue;`.

- [ ] **Step 2: Run them and confirm they fail**

Run `cargo test --manifest-path rust/Cargo.toml remote::`. Expected: a compile error, because `run`, `watch`, `WireRemote` and the other names are undefined in `remote.rs`.

- [ ] **Step 3: Share the lookup and write the worker**

In `rust/crates/bopify-core/src/queue.rs`, replace the whole `pub(crate) fn start` function with:

```rust
/// Looks a track or episode up for display; `None` when it cannot be resolved.
pub(crate) async fn lookup(session: Session, raw: String) -> Option<WireTrack> {
    let uri = SpotifyUri::from_uri(&raw).ok()?;
    AudioItem::get_file(&session, uri).await.ok().map(track_metadata)
}

pub(crate) fn start(session: Session, sink: EventSink) -> watch::Sender<Option<MetadataRequest>> {
    let (sender, receiver) = watch::channel(None);
    tokio::spawn(run(receiver, sink, move |raw| lookup(session.clone(), raw)));
    sender
}
```

In `rust/crates/bopify-core/src/remote.rs`, between the module doc line and `#[cfg(test)]`, add:

```rust
use crate::{
    engine::EventSink,
    event::{WireEvent, WireRemote, WireTrack},
};
use librespot_core::Session;
use std::{collections::HashMap, future::Future};
use tokio::{sync::watch, task::JoinSet};

pub(crate) fn start(session: Session, sink: EventSink) -> watch::Sender<Option<WireRemote>> {
    let (sender, receiver) = watch::channel(None);
    tokio::spawn(run(receiver, sink, move |raw| crate::queue::lookup(session.clone(), raw)));
    sender
}

async fn run<F, Fut>(mut requests: watch::Receiver<Option<WireRemote>>, sink: EventSink, fetch: F)
where
    F: Fn(String) -> Fut + Send + 'static,
    Fut: Future<Output = Option<WireTrack>> + Send + 'static,
{
    let mut lookup = JoinSet::new();
    let mut cache: HashMap<String, WireTrack> = HashMap::new();
    loop {
        tokio::select! {
            biased;
            changed = requests.changed() => {
                if changed.is_err() { break; }
                // Latest wins: an older lookup, even one already finished, must never land after this one.
                lookup.abort_all();
                while lookup.join_next().await.is_some() {}
                let Some(mut remote) = requests.borrow_and_update().clone() else {
                    sink(WireEvent::RemotePlayback { remote: None });
                    continue;
                };
                if let Some(track) = cache.get(&remote.track_uri) {
                    remote.track = Some(track.clone());
                    sink(WireEvent::RemotePlayback { remote: Some(remote) });
                } else {
                    let pending = fetch(remote.track_uri.clone());
                    lookup.spawn(async move { (remote, pending.await) });
                }
            }
            result = lookup.join_next(), if !lookup.is_empty() => {
                let Some(Ok((mut remote, track))) = result else { continue };
                match &track {
                    Some(track) => {
                        // One track shows at a time, so a small bound that resets is enough.
                        if cache.len() >= 64 { cache.clear(); }
                        cache.insert(remote.track_uri.clone(), track.clone());
                    }
                    None => log::debug!("remote: metadata unavailable"),
                }
                remote.track = track;
                sink(WireEvent::RemotePlayback { remote: Some(remote) });
            }
        }
    }
}
```

- [ ] **Step 4: Run the worker tests and confirm they pass**

Run `cargo test --manifest-path rust/Cargo.toml remote::`. Expected: PASS for the three tests. The existing `queue::` tests must still pass.

- [ ] **Step 5: Write the failing routing test**

In `rust/crates/bopify-core/src/engine.rs`'s `mod tests`:

1. Change `use librespot_playback::player::PlayerEvent;` to `use librespot_playback::player::{PlayerEvent, RemoteState};`.
2. In `transport_drain_publishes_structure_before_metadata_without_waiting`, add `let (remote, _mirror) = tokio::sync::watch::channel(None);` after the `metadata` channel line. Change its call to `forward_events(rx, sink, metadata, remote).await;`.
3. Add this test after it:

```rust
    #[tokio::test]
    async fn the_mirror_waits_for_its_metadata_instead_of_reaching_swift_directly() {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let (metadata, _requests) = tokio::sync::watch::channel(None);
        let (remote, mirrored) = tokio::sync::watch::channel(None);
        let (output, mut received) = tokio::sync::mpsc::unbounded_channel();
        let sink: EventSink = Arc::new(move |event| { output.send(event).unwrap(); });
        tx.send(PlayerEvent::RemotePlayback { remote: Some(RemoteState { device_name: "iPhone".into(), track_uri: "spotify:track:abc".into(), is_playing: true, position_ms: 0, duration_ms: 1000 }) }).unwrap();
        drop(tx);
        forward_events(rx, sink, metadata, remote).await;
        let mirrored = mirrored.borrow().clone();
        assert_eq!(mirrored.map(|remote| remote.track_uri), Some("spotify:track:abc".to_string()));
        // Only the drain's closing SessionLost went straight to Swift.
        assert!(matches!(received.recv().await.unwrap(), WireEvent::Failed { .. }));
    }
```

Run `cargo test --manifest-path rust/Cargo.toml engine::`. Expected: a compile error, because `forward_events` takes three arguments.

- [ ] **Step 6: Route the mirror through the worker**

In `rust/crates/bopify-core/src/engine.rs`, replace `supervise_forwarder`'s first two lines:

```rust
    let metadata = crate::queue::start(session, sink.clone());
    let forwarder = tokio::spawn(forward_events(events, sink.clone(), metadata));
```

with:

```rust
    let metadata = crate::queue::start(session.clone(), sink.clone());
    let remote = crate::remote::start(session, sink.clone());
    let forwarder = tokio::spawn(forward_events(events, sink.clone(), metadata, remote));
```

Replace `forward_events`'s signature and loop head. Before:

```rust
async fn forward_events(
    mut events: PlayerEventChannel,
    sink: EventSink,
    metadata: tokio::sync::watch::Sender<Option<crate::queue::MetadataRequest>>,
) {
    while let Some(event) = events.recv().await {
        if let Some(wire) = crate::event::translate(event) {
            let request = crate::queue::MetadataRequest::from_event(&wire);
```

After:

```rust
async fn forward_events(
    mut events: PlayerEventChannel,
    sink: EventSink,
    metadata: tokio::sync::watch::Sender<Option<crate::queue::MetadataRequest>>,
    remote: tokio::sync::watch::Sender<Option<crate::event::WireRemote>>,
) {
    while let Some(event) = events.recv().await {
        if let Some(wire) = crate::event::translate(event) {
            // The mirror waits for its track metadata, so the remote worker publishes it.
            if let WireEvent::RemotePlayback { remote: mirrored } = wire {
                remote.send_replace(mirrored);
                continue;
            }
            let request = crate::queue::MetadataRequest::from_event(&wire);
```

- [ ] **Step 7: Run all Rust tests**

Run `cargo test --manifest-path rust/Cargo.toml`. Expected: PASS, including both `engine::` tests.

- [ ] **Step 8: Commit**

```bash
git add rust/crates/bopify-core/src/remote.rs rust/crates/bopify-core/src/queue.rs rust/crates/bopify-core/src/lib.rs rust/crates/bopify-core/src/engine.rs
git commit -m "Look up the mirrored track's metadata, latest wins" -m "The mirror needs a title and artwork, and cluster updates carry only a track URI. Lookups run off the transport drain like queue metadata. A newer mirror cancels an older lookup so a slow reply never shows a stale track, and a small cache serves the frequent position-only updates without a lookup."
```

---

### Task 3: Extract the mirror from a cluster

**Files:**
- Modify: `.build/librespot-939dc5e/connect/src/startup.rs` (the whole file is replaced below)
- Modify: `.build/librespot-939dc5e/connect/src/spirc.rs`: only `resolve_startup`'s `Remote` arm, at ~1048
- Regenerate: `rust/patches/librespot-queue-selection.patch`

**Interfaces:**
- Consumes: `RemoteState` from Task 1, via `crate::playback::player::RemoteState`.
- Produces:
  - `StartupDecision::Remote(RemoteState)`, replacing `Remote { device_name }`;
  - `pub(crate) fn remote_playback(cluster: &Cluster, own_device_id: &str) -> Option<RemoteState>`.
- The rules:
  - It returns `None` when no device is active, when the active device is ours, or when the active device has no track.
  - While the device plays, the position is `position_as_of_timestamp + (server_timestamp_ms - player_state.timestamp)`. While it is paused, the position is `position_as_of_timestamp`. Either way it is clamped to `0..=duration` when the duration is positive.
  - A device missing from `cluster.device` gets an empty name.

- [ ] **Step 1: Write the failing tests**

Replace the whole of `.build/librespot-939dc5e/connect/src/startup.rs` with the content below. Step 3 fills in the implementation; the tests are final.

```rust
//! Bopify: the connect-time decision behind `ConnectConfig::startup_restore`,
//! and the mirror of another device's playback.

use crate::{
    playback::player::RemoteState,
    protocol::{connect::Cluster, transfer_state::TransferState},
};
use protobuf::Message;

#[derive(Debug)]
pub(crate) enum StartupDecision {
    Remote(RemoteState),
    Restore(TransferState),
    Fallback,
}

pub(crate) fn startup_decision(cluster: &Cluster, own_device_id: &str) -> StartupDecision {
    todo!()
}

pub(crate) fn remote_playback(cluster: &Cluster, own_device_id: &str) -> Option<RemoteState> {
    todo!()
}

/// Checks content, not byte length: an empty Bopify session still serialises
/// to 66 bytes of transfer data.
fn is_usable(transfer: &TransferState) -> bool {
    let context = transfer.current_session.context.uri.as_deref().unwrap_or_default();
    let track = transfer.playback.current_track.uri.as_deref().unwrap_or_default();
    (!context.is_empty() && context != "-") || !track.is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::connect::DeviceInfo;

    const OWN: &str = "own-device";

    /// A serialised last session, shaped like the spike's `transfer_data`.
    fn session(context: &str, track: &str, paused: bool) -> Vec<u8> {
        let mut transfer = TransferState::new();
        transfer
            .current_session
            .mut_or_insert_default()
            .context
            .mut_or_insert_default()
            .uri = Some(context.into());
        let playback = transfer.playback.mut_or_insert_default();
        playback.current_track.mut_or_insert_default().uri = Some(track.into());
        playback.is_paused = Some(paused);
        playback.position_as_of_timestamp = Some(203);
        transfer.write_to_bytes().unwrap()
    }

    fn cluster(active: &str, playing_track: &str, transfer_data: Vec<u8>) -> Cluster {
        let mut cluster = Cluster::new();
        cluster.active_device_id = active.into();
        if !active.is_empty() {
            let mut device = DeviceInfo::new();
            device.name = "iPhone".into();
            cluster.device.insert(active.into(), device);
        }
        cluster
            .player_state
            .mut_or_insert_default()
            .track
            .mut_or_insert_default()
            .uri = playing_track.into();
        cluster.transfer_data = transfer_data;
        cluster
    }

    /// `cluster`, with the active device reporting playback at a known server time.
    fn reporting(active: &str, paused: bool, server_timestamp_ms: i64) -> Cluster {
        let mut cluster = cluster(active, "spotify:track:0phqiLIH4JYk4jPissBOQE", Vec::new());
        let state = cluster.player_state.mut_or_insert_default();
        state.is_playing = true;
        state.is_paused = paused;
        state.timestamp = 1_000;
        state.position_as_of_timestamp = 5_000;
        state.duration = 200_000;
        cluster.server_timestamp_ms = server_timestamp_ms;
        cluster
    }

    fn restored(decision: StartupDecision) -> TransferState {
        match decision {
            StartupDecision::Restore(transfer) => transfer,
            other => panic!("expected Restore, got {other:?}"),
        }
    }

    #[test]
    fn restores_the_last_session_paused_when_no_device_is_active() {
        let data = session(
            "spotify:playlist:37i9dQZF1E8NDRt5R5oIbG",
            "spotify:track:3WvM2dIR9iIxMGNMP7WsNw",
            true,
        );
        let transfer = restored(startup_decision(&cluster("", "", data), OWN));
        assert_eq!(
            transfer.current_session.context.uri.as_deref(),
            Some("spotify:playlist:37i9dQZF1E8NDRt5R5oIbG")
        );
        assert_eq!(transfer.playback.is_paused, Some(true));
    }

    #[test]
    fn a_session_left_playing_by_a_vanished_device_resumes_paused_at_its_reported_position() {
        let data = session(
            "spotify:user:121047766:collection",
            "spotify:track:22Tmr1R5TVgtLOSYrgMWdu",
            false,
        );
        let transfer = restored(startup_decision(&cluster("", "", data), OWN));
        assert_eq!(transfer.playback.is_paused, Some(true));
        assert_eq!(transfer.playback.position_as_of_timestamp, Some(203));
    }

    #[test]
    fn a_session_started_from_bare_uris_is_restored_from_its_track() {
        restored(startup_decision(
            &cluster("", "", session("-", "spotify:track:x", true)),
            OWN,
        ));
    }

    #[test]
    fn an_empty_or_missing_session_falls_back() {
        assert!(TransferState::parse_from_bytes(&[0xFF]).is_err());
        for data in [
            session("", "", true),
            session("-", "", true),
            Vec::new(),
            vec![0xFF],
        ] {
            let decision = startup_decision(&cluster("", "", data), OWN);
            assert!(matches!(decision, StartupDecision::Fallback), "{decision:?}");
        }
    }

    #[test]
    fn another_device_playing_a_track_is_mirrored_never_restored() {
        // Run 4: while a device is active, transfer_data is a stub that still names a context.
        let data = session("spotify:user:121047766:collection", "", false);
        let decision = startup_decision(
            &cluster("6dce37", "spotify:track:0phqiLIH4JYk4jPissBOQE", data),
            OWN,
        );
        assert!(
            matches!(&decision, StartupDecision::Remote(remote) if remote.device_name == "iPhone"),
            "{decision:?}"
        );
    }

    #[test]
    fn an_active_device_without_a_track_falls_back_never_restores() {
        // Run 0: a crashed Bopify stayed "active" with an empty session.
        let data = session("spotify:user:121047766:collection", "", true);
        let decision = startup_decision(&cluster("ghost", "", data), OWN);
        assert!(matches!(decision, StartupDecision::Fallback), "{decision:?}");
    }

    #[test]
    fn a_track_without_a_context_uri_is_restored_as_a_track_only_session() {
        let mut transfer = TransferState::new();
        transfer
            .playback
            .mut_or_insert_default()
            .current_track
            .mut_or_insert_default()
            .uri = Some("spotify:track:x".into());
        let data = transfer.write_to_bytes().unwrap();
        let transfer = restored(startup_decision(&cluster("", "", data), OWN));
        assert_eq!(transfer.current_session.context.uri.as_deref(), Some("-"));
        assert_eq!(transfer.playback.is_paused, Some(true));
    }

    #[test]
    fn this_device_is_never_mirrored() {
        let decision = startup_decision(&cluster(OWN, "spotify:track:x", Vec::new()), OWN);
        assert!(matches!(decision, StartupDecision::Fallback), "{decision:?}");
    }

    #[test]
    fn a_playing_mirror_advances_by_server_time_only() {
        let remote = remote_playback(&reporting("6dce37", false, 3_500), OWN).unwrap();
        assert_eq!(
            remote,
            RemoteState {
                device_name: "iPhone".into(),
                track_uri: "spotify:track:0phqiLIH4JYk4jPissBOQE".into(),
                is_playing: true,
                position_ms: 7_500,
                duration_ms: 200_000,
            }
        );
    }

    #[test]
    fn a_paused_mirror_holds_its_reported_position() {
        let remote = remote_playback(&reporting("6dce37", true, 3_500), OWN).unwrap();
        assert!(!remote.is_playing);
        assert_eq!(remote.position_ms, 5_000);
    }

    #[test]
    fn a_mirrored_position_never_passes_the_track_end() {
        let remote = remote_playback(&reporting("6dce37", false, 900_000), OWN).unwrap();
        assert_eq!(remote.position_ms, 200_000);
    }

    #[test]
    fn nothing_is_mirrored_without_another_active_device_with_a_track() {
        for cluster in [
            cluster("", "spotify:track:x", Vec::new()),
            cluster(OWN, "spotify:track:x", Vec::new()),
            cluster("ghost", "", Vec::new()),
        ] {
            assert_eq!(remote_playback(&cluster, OWN), None);
        }
    }

    #[test]
    fn a_device_missing_from_the_device_list_is_mirrored_without_a_name() {
        let mut cluster = reporting("6dce37", false, 3_500);
        cluster.device.clear();
        assert_eq!(remote_playback(&cluster, OWN).unwrap().device_name, "");
    }
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run `cargo test --manifest-path rust/Cargo.toml -p librespot-connect startup`. Expected: either a compile error in `spirc.rs`, because `StartupDecision::Remote { device_name }` no longer matches, or panics at `todo!()`.

- [ ] **Step 3: Implement the decision and the extraction**

In `startup.rs`, replace the two `todo!()` functions with:

```rust
pub(crate) fn startup_decision(cluster: &Cluster, own_device_id: &str) -> StartupDecision {
    if !cluster.active_device_id.is_empty() {
        // A trackless active device has nothing to mirror, and while any device is
        // active the transfer data is a stub that would pull its context over.
        return remote_playback(cluster, own_device_id)
            .map_or(StartupDecision::Fallback, StartupDecision::Remote);
    }
    match TransferState::parse_from_bytes(&cluster.transfer_data) {
        Ok(mut transfer) if is_usable(&transfer) => {
            // Set before handle_transfer, never as a pause after it: it also stops
            // handle_transfer extrapolating a stale timestamp past where playback was.
            transfer.playback.mut_or_insert_default().is_paused = Some(true);
            // handle_transfer rejects a missing context uri but restores a track-only session from "-".
            let context = transfer.current_session.mut_or_insert_default().context.mut_or_insert_default();
            context.uri.get_or_insert_with(|| "-".into());
            StartupDecision::Restore(transfer)
        }
        _ => StartupDecision::Fallback,
    }
}

/// What another active device is playing, or `None` when no other device is
/// active with a track. Reads `player_state`, because `transfer_data` is a
/// stub with an empty track while a device is active (run 4).
pub(crate) fn remote_playback(cluster: &Cluster, own_device_id: &str) -> Option<RemoteState> {
    let active = cluster.active_device_id.as_str();
    if active.is_empty() || active == own_device_id {
        return None;
    }
    let state = cluster.player_state.as_ref()?;
    let track_uri = state
        .track
        .as_ref()
        .map(|track| track.uri.clone())
        .filter(|uri| !uri.is_empty())?;
    let is_playing = state.is_playing && !state.is_paused;
    // Server clocks only, so a skewed Mac clock cannot move the mirror.
    let elapsed = if is_playing {
        (cluster.server_timestamp_ms - state.timestamp).max(0)
    } else {
        0
    };
    let mut position = (state.position_as_of_timestamp + elapsed).max(0);
    if state.duration > 0 {
        position = position.min(state.duration);
    }
    Some(RemoteState {
        device_name: cluster
            .device
            .get(active)
            .map(|device| device.name.clone())
            .unwrap_or_default(),
        track_uri,
        is_playing,
        position_ms: u32::try_from(position).unwrap_or(u32::MAX),
        duration_ms: u32::try_from(state.duration.max(0)).unwrap_or(u32::MAX),
    })
}
```

In `.build/librespot-939dc5e/connect/src/spirc.rs`, `resolve_startup`, replace:

```rust
            StartupDecision::Remote { device_name } => {
                return StartupOutcome::Remote { device_name };
            }
```

with:

```rust
            StartupDecision::Remote(remote) => {
                return StartupOutcome::Remote {
                    device_name: remote.device_name,
                };
            }
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run `cargo test --manifest-path rust/Cargo.toml -p librespot-connect`. Expected: PASS for all 13 `startup::` tests, with no new warnings. Run `cargo test --manifest-path rust/Cargo.toml` too (expected: PASS). Regenerate and verify the patch.

- [ ] **Step 5: Commit**

```bash
git add rust/patches/librespot-queue-selection.patch
git commit -m "Extract the mirrored device's playback from the cluster" -m "The mirror is built from player_state, because transfer_data is a stub while a device is active. Its position uses server clocks only, so a skewed Mac clock cannot move it. The startup decision's Remote branch now returns the same state, so launch and live updates follow one rule."
```

---

### Task 4: Spirc emits the mirror while inactive

**Files:**
- Modify: `.build/librespot-939dc5e/connect/src/startup.rs` (add `remote_changed` and its test)
- Modify: `.build/librespot-939dc5e/connect/src/spirc.rs`: the imports (1–35), the `SpircTask` fields (~102–104), their initialisation (~320–321), `resolve_startup` (~1046), `handle_cluster_update` (~1140) and `handle_activate` (~1470)
- Regenerate: `rust/patches/librespot-queue-selection.patch`

**Interfaces:**
- Consumes: `remote_playback` and `StartupDecision::Remote(RemoteState)` from Task 3, and `Player::emit_remote_playback_event` from Task 1.
- Produces:
  - `pub(crate) fn remote_changed(last: &mut Option<RemoteState>, next: &Option<RemoteState>) -> bool`;
  - the `SpircTask.last_remote` field and `SpircTask::publish_remote(&mut self, Option<RemoteState>)`.
- Behaviour, only when `startup_restore` is set:
  - The startup `Remote` outcome emits the mirror.
  - Every cluster update that leaves Bopify inactive emits `remote_playback(&cluster, own)`, including the update that deactivated it. It emits only when the value changed.
  - `handle_activate` forgets the last mirror without emitting.

- [ ] **Step 1: Write the failing test**

In `startup.rs`'s `mod tests`, add after `a_device_missing_from_the_device_list_is_mirrored_without_a_name`:

```rust
    #[test]
    fn only_a_changed_mirror_is_emitted() {
        let playing = remote_playback(&reporting("6dce37", false, 3_500), OWN);
        let mut last = None;
        assert!(remote_changed(&mut last, &playing));
        assert!(!remote_changed(&mut last, &playing));
        assert!(remote_changed(
            &mut last,
            &remote_playback(&reporting("6dce37", true, 3_500), OWN)
        ));
        assert!(remote_changed(&mut last, &None));
        assert!(!remote_changed(&mut last, &None));
    }
```

Run `cargo test --manifest-path rust/Cargo.toml -p librespot-connect startup`. Expected: a compile error, because `remote_changed` is undefined.

- [ ] **Step 2: Implement `remote_changed`**

In `startup.rs`, after `remote_playback`, add:

```rust

/// Records `next` as the last emitted mirror, and says whether it differs,
/// so Spirc emits only changes.
pub(crate) fn remote_changed(last: &mut Option<RemoteState>, next: &Option<RemoteState>) -> bool {
    if last == next {
        return false;
    }
    last.clone_from(next);
    true
}
```

- [ ] **Step 3: Wire the emission into Spirc**

In `.build/librespot-939dc5e/connect/src/spirc.rs`:

1. In the imports, change `player::{Player, PlayerEvent, PlayerEventChannel, StartupOutcome},` to `player::{Player, PlayerEvent, PlayerEventChannel, RemoteState, StartupOutcome},`. Change `startup::{StartupDecision, startup_decision},` to `startup::{StartupDecision, remote_changed, remote_playback, startup_decision},`.
2. In `struct SpircTask`, after `startup_resolved: bool,`, add:

```rust
    /// The mirror last emitted, so cluster updates emit only changes.
    last_remote: Option<RemoteState>,
```

3. In the `SpircTask { … }` initialiser, after `startup_resolved: false,`, add `last_remote: None,`.
4. In `resolve_startup`, replace the `Remote` arm from Task 3 with:

```rust
            StartupDecision::Remote(remote) => {
                let device_name = remote.device_name.clone();
                // Emitted with the outcome, so the mirror appears at launch.
                self.publish_remote(Some(remote));
                return StartupOutcome::Remote { device_name };
            }
```

5. After the closing `}` of `async fn load_liked_songs`, add:

```rust

    fn publish_remote(&mut self, remote: Option<RemoteState>) {
        if remote_changed(&mut self.last_remote, &remote) {
            self.player.emit_remote_playback_event(remote);
        }
    }
```

6. In `handle_cluster_update`, inside `if let Some(cluster) = cluster_update.cluster.take() {`, after the closing `}` of the `if became_inactive { … } else if self.connect_state.is_active() { … }` chain, add:

```rust
            // Bopify: this includes the update that just deactivated this device.
            if self.startup_restore && !self.connect_state.is_active() {
                let remote = remote_playback(&cluster, self.session.device_id());
                self.publish_remote(remote);
            }
```

7. In `fn handle_activate`, as its first statement, add:

```rust
        // Bopify: Swift drops the mirror on becoming active, so the next takeover must emit again.
        self.last_remote = None;
```

- [ ] **Step 4: Run the tests**

Run `cargo test --manifest-path rust/Cargo.toml -p librespot-connect`. Expected: PASS, including `only_a_changed_mirror_is_emitted`, with no warnings from `spirc.rs` or `startup.rs`. Then run `cargo test --manifest-path rust/Cargo.toml` (expected: PASS). Regenerate and verify the patch.

- [ ] **Step 5: Commit**

```bash
git add rust/patches/librespot-queue-selection.patch
git commit -m "Emit the mirror while Bopify is inactive" -m "Upstream ignores cluster updates while inactive, so the panel froze on a stale track after another device took over. Spirc now emits the active device's playback at launch and on every cluster update while inactive, only when it changes, and forgets it on activation so the next takeover is announced again."
```

---

### Task 5: A play-here command

**Files:**
- Modify: `.build/librespot-939dc5e/connect/src/spirc.rs`: `enum SpircCommand` (~126), `impl Spirc` after `pub fn transfer` (~521), `handle_command` (~771–850), `resolve_startup` and `load_liked_songs` (~1046–1092)
- Modify: `.build/librespot-939dc5e/connect/Cargo.toml`: the tokio line (31)
- Modify: `README.md` (line 37)
- Modify: `docs/superpowers/specs/2026-09-26-startup-restore-design.md` (Phase 2 items 2 and 7)
- Regenerate: `rust/patches/librespot-queue-selection.patch`

**Interfaces:**
- Consumes: `startup_decision`, `StartupDecision`, `publish_remote`, `load_liked_songs`, `handle_transfer`, `handle_play` and `notify`.
- Produces:
  - `pub fn Spirc::play_here(&self) -> Result<(), Error>`;
  - `SpircCommand::PlayHere`;
  - `fn SpircTask::restore_session(&mut self, TransferState) -> bool`;
  - `async fn SpircTask::load_liked_songs(&mut self, start_playing: bool) -> StartupOutcome`.
- Behaviour, only while inactive and with `startup_restore` set:
  1. Put the state and parse the returned `Cluster`.
  2. `Remote` → send `spclient().transfer(own, own, None)` on a spawned task, logging a failed reply at warn.
  3. `Restore` → `restore_session`, then `handle_play` and `notify`.
  4. Otherwise → Liked Songs with `start_playing: true`.

  While active it is `handle_play`. Without `startup_restore`, an inactive `PlayHere` is ignored with upstream's warning.

This task has no unit test: every branch is Spirc I/O. The pure decision it relies on is covered by Tasks 3 and 4. Task 9's live checks 2, 4 and 5 verify it, so the review gate here is the diff, the build and a clean test run.

- [ ] **Step 1: Add the command**

In `enum SpircCommand`, after `Play,`, add `PlayHere,`.

In `impl Spirc`, after `pub fn transfer(…) { … }`, add:

```rust

    /// Bopify: plays on this device from wherever the account's session is. It
    /// takes over another device, resumes the last session, or plays Liked Songs.
    ///
    /// Needs `ConnectConfig::startup_restore`. While this device is active it is [Spirc::play].
    pub fn play_here(&self) -> Result<(), Error> {
        Ok(self.commands.send(SpircCommand::PlayHere)?)
    }
```

In `.build/librespot-939dc5e/connect/Cargo.toml`, change `tokio = { version = "1", features = ["macros", "sync"] }` to `tokio = { version = "1", features = ["macros", "sync", "rt"] }`. `play_here` spawns a task, and today `rt` only reaches this crate through `librespot-core`.

- [ ] **Step 2: Share the restore and parameterise Liked Songs**

In `resolve_startup`, replace the whole `StartupDecision::Restore(transfer) => { … }` arm with:

```rust
            StartupDecision::Restore(transfer) => {
                if self.restore_session(transfer) {
                    return StartupOutcome::Restored;
                }
            }
```

Change its last line from `self.load_liked_songs().await` to `self.load_liked_songs(false).await`.

Directly after `resolve_startup`, add:

```rust

    /// Takes the last session over paused, as `startup_decision` prepared it.
    /// Returns false, with nothing left half-applied, when no track was loaded.
    fn restore_session(&mut self, transfer: TransferState) -> bool {
        match self.handle_transfer(transfer) {
            // handle_transfer returns Ok without loading when the session names no
            // playable track, so only a paused load counts as restored.
            Ok(()) if matches!(self.play_status, SpircPlayStatus::LoadingPause { .. }) => {
                return true;
            }
            Ok(()) => warn!("restore: the last session had no track to restore"),
            Err(why) => warn!("restore: restoring the last session failed: {why}"),
        }
        // A half-applied transfer must not be finished later on top of Liked Songs.
        self.transfer_state = None;
        false
    }
```

In `load_liked_songs`:
- Change the signature to `async fn load_liked_songs(&mut self, start_playing: bool) -> StartupOutcome {`.
- Change `start_playing: false,` to `start_playing,`.
- Change the two warning texts to `"liked songs: loading failed: {why}"` and `"liked songs: state update failed: {why}"`, since play here now uses this path as well as startup.

- [ ] **Step 3: Handle the command**

In `handle_command`, directly after the arm `SpircCommand::Activate if !self.connect_state.is_active() => { … }`, add:

```rust
            SpircCommand::PlayHere if self.startup_restore && !self.connect_state.is_active() => {
                self.handle_play_here().await;
                return Ok(());
            }
```

Change `SpircCommand::Play => self.handle_play(),` to `SpircCommand::Play | SpircCommand::PlayHere => self.handle_play(),`.

After `fn restore_session`, add:

```rust

    /// Bopify: logs its own failures, because the command loop only debug-logs
    /// an error. The cluster comes from a fresh state PUT, since cluster updates
    /// are not known to carry the full last session.
    async fn handle_play_here(&mut self) {
        use protobuf::Message as _;
        let cluster = match self.connect_state.send_state(&self.session).await {
            Ok(bytes) => Cluster::parse_from_bytes(&bytes).ok(),
            Err(why) => {
                warn!("play here: state update failed: {why}");
                return;
            }
        };
        let Some(cluster) = cluster else {
            warn!("play here: the state update returned no cluster");
            return;
        };
        match startup_decision(&cluster, self.session.device_id()) {
            StartupDecision::Remote(_) => {
                // Spawned, so this loop can answer the transfer request the server sends
                // before it replies; awaiting here dropped the dealer connection (run 5).
                let spclient = self.session.spclient().clone();
                let device_id = self.session.device_id().to_owned();
                tokio::spawn(async move {
                    // Run 5 moved playback despite a 410, so the reply is only logged.
                    if let Err(why) = spclient.transfer(&device_id, &device_id, None).await {
                        warn!("play here: transfer replied {why}");
                    }
                });
                return;
            }
            StartupDecision::Restore(transfer) => {
                if self.restore_session(transfer) {
                    self.handle_play();
                    if let Err(why) = self.notify().await {
                        warn!("play here: state update failed: {why}");
                    }
                    return;
                }
            }
            StartupDecision::Fallback => {}
        }
        self.load_liked_songs(true).await;
    }
```

- [ ] **Step 4: Update the README and the spec**

In `README.md`, change `selection and startup-restore patch in` to `selection, startup-restore and remote-mirror patch in`.

In `docs/superpowers/specs/2026-09-26-startup-restore-design.md`, Phase 2 item 2, change `decides from the most recent cluster, which `SpircTask` now keeps, using `startup_decision`:` to `decides from a fresh cluster, returned by a state PUT when the command runs, using `startup_decision`. Cluster updates are not known to carry the full last session:`.

In item 7, change `- Previews: mirror, paused remote, and stale.` to `- Native probe captures (the Monolith player replaced previews with probes): mirror, paused remote, and stale.`

- [ ] **Step 5: Build, test and regenerate**

Run `cargo test --manifest-path rust/Cargo.toml -p librespot-connect` and `cargo test --manifest-path rust/Cargo.toml`. Expected: PASS, with no warnings from `spirc.rs`. Regenerate and verify the patch.

- [ ] **Step 6: Commit**

```bash
git add rust/patches/librespot-queue-selection.patch README.md docs/superpowers/specs/2026-09-26-startup-restore-design.md
git commit -m "Add a play-here command that takes the session over" -m "Play on the mirror or on a stale track must move the account's session onto this Mac. The command reads a fresh cluster and reuses the startup decision: another device gets a transfer request sent off the Spirc loop, so the loop can answer the server's transfer (run 5 showed awaiting it drops the dealer), a usable last session is restored and played, and otherwise Liked Songs plays."
```

---

### Task 6: `bopify_play_here`, and Play routes to it while inactive

**Files:**
- Modify: `rust/crates/bopify-core/src/engine.rs` (after `pub fn play`, ~138)
- Modify: `rust/crates/bopify-core/src/ffi.rs` (the comment at ~256, after `bopify_play` at ~263, and the test at ~444)
- Modify: `Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift`
- Modify: `Packages/BopifyCore/Sources/BopifyPlayback/LibrespotEngine.swift` (after `resume`, line 123), `StubPlaybackEngine.swift`, `PlayerModel.swift`
- Modify: `Packages/BopifyCore/Tests/PlaybackTests/PlayerModelTests.swift` (including `FailingSelectionEngine` at the end)
- Modify: `docs/superpowers/specs/2026-09-21-bopify-foundation-design.md` (lines 148 and 188)

**Interfaces:**
- Consumes: `Spirc::play_here` from Task 5, and `PlaybackState.remote` from Task 1.
- Produces:
  - `Engine::play_here(&self) -> Result<(), BopifyError>`;
  - `int32_t bopify_play_here(BopifyEngine *)`;
  - `PlaybackEngine.playHere() async throws`;
  - `PlayerModel.canPlayHere: Bool`, which is true when inactive, not in an error, and there is a mirror or a current track;
  - `PlayerModel.playHere()`;
  - `togglePlayPause()` calls `playHere()` whenever `!state.isActiveDevice`.

- [ ] **Step 1: Write the failing FFI test**

In `ffi.rs`'s `every_command_on_a_destroyed_handle_reports_session_lost`, add `assert_eq!(bopify_play_here(ptr), lost);` after `assert_eq!(bopify_play(ptr), lost);`. Run `cargo test --manifest-path rust/Cargo.toml ffi::`. Expected: a compile error, because `bopify_play_here` is undefined.

- [ ] **Step 2: Add the engine command and the C entry point**

In `engine.rs`, after `pub fn play(&self) -> Result<(), BopifyError> { … }`, add:

```rust
    pub fn play_here(&self) -> Result<(), BopifyError> {
        self.spirc.play_here().map_err(command_failed)
    }
```

In `ffi.rs`, change the comment `// The four no-argument commands are spelled out rather than generated by a` to `// The five no-argument commands are spelled out rather than generated by a`. After the `bopify_play` function, add:

```rust

/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_play_here(handle: *mut BopifyEngine) -> i32 {
    log::debug!("ffi: bopify_play_here");
    // SAFETY: forwards this function's own contract to `with_engine`.
    unsafe { with_engine(handle, Engine::play_here) }
}
```

Run `cargo test --manifest-path rust/Cargo.toml`. Expected: PASS. Then run `./scripts/build-rust.sh`. Expected: `Pinned librespot queue patch verified.` and `xcframework successfully written out`. Check that `artifacts/include` now declares the entry point: `rg -n "bopify_play_here" artifacts/include`.

- [ ] **Step 3: Write the failing Swift tests**

In `PlayerModelTests.swift`, add after `theMirrorClearsWhenBopifyBecomesActiveAndStaysCleared`:

```swift
    @Test func playWhileInactiveAsksTheEngineToPlayHereWithoutAssumingItWorked() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        model.togglePlayPause()
        await settle(model, engine, [])
        #expect(engine.recordedCommands.isEmpty)  // nothing to take over yet
        await settle(model, engine, [.remotePlayback(makeRemote())])
        #expect(model.canPlayHere)
        model.togglePlayPause()
        await settle(model, engine, [])
        #expect(engine.recordedCommands == ["playHere"])
        // Only the engine's events may change the state.
        #expect(model.state.phase == .idle)
        #expect(model.state.remote == makeRemote())
    }

    @Test func aStaleTrackCanBePlayedHereButNotAfterAFailure() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.trackChanged(makeTrack()), .paused(positionMs: 0)])
        #expect(!model.canPlayHere)  // while active, Play is resume
        await settle(model, engine, [.activeDeviceChanged(isActive: false)])
        #expect(model.canPlayHere)
        model.playHere()
        await settle(model, engine, [])
        #expect(engine.recordedCommands == ["playHere"])
        await settle(model, engine, [.failed(.playbackSessionLost)])
        #expect(!model.canPlayHere)
    }
```

In `private struct FailingSelectionEngine` at the end of the file, add `func playHere() async throws { try await stub.playHere() }` after its `resume()` line.

Run `swift test --package-path Packages/BopifyCore`. Expected: a compile error, because `playHere` and `canPlayHere` don't exist.

- [ ] **Step 4: Add `playHere` to the protocol, the engines and the model**

In `PlaybackEngine.swift`, after `func resume() async throws`, add:

```swift
    /// Plays on this Mac while another device, or none, owns the session.
    func playHere() async throws
```

In `StubPlaybackEngine.swift`, after the `resume()` line, add `public func playHere() async throws { record("playHere") }`.

In `LibrespotEngine.swift`, after the `resume()` line, add:

```swift
    @concurrent public func playHere() async throws { try perform("playHere") { bopify_play_here(handle) } }
```

In `PlayerModel.swift`, replace:

```swift
    public func togglePlayPause() {
        guard state.isActiveDevice else { return }
```

with:

```swift
    /// Play takes the session over while Bopify is inactive, from a mirror or a stale track.
    public var canPlayHere: Bool {
        guard !state.isActiveDevice, state.remote != nil || state.currentTrack != nil else { return false }
        if case .error = state.phase { return false }
        return true
    }

    public func playHere() {
        guard canPlayHere else { return }
        enqueue("playHere") { [engine] in try await engine.playHere() }
    }

    public func togglePlayPause() {
        guard state.isActiveDevice else { playHere(); return }
```

- [ ] **Step 5: Run the tests and the app build**

Run `swift test --package-path Packages/BopifyCore`. Expected: PASS, including both new tests and the existing `togglePlayPauseSendsTheCommandButDoesNotAssumeItWorked`. Then run the app build from "Commands used throughout". Expected: no errors.

- [ ] **Step 6: Update the foundation spec**

In `docs/superpowers/specs/2026-09-21-bopify-foundation-design.md`, add `    func playHere() async throws` after line 148 (`    func resume() async throws`). Add `int32_t bopify_play_here(BopifyEngine *);` after line 188 (`int32_t bopify_play(BopifyEngine *);`).

- [ ] **Step 7: Commit**

```bash
git add rust/crates/bopify-core/src/engine.rs rust/crates/bopify-core/src/ffi.rs Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift Packages/BopifyCore/Sources/BopifyPlayback/LibrespotEngine.swift Packages/BopifyCore/Sources/BopifyPlayback/StubPlaybackEngine.swift Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift Packages/BopifyCore/Tests/PlaybackTests/PlayerModelTests.swift docs/superpowers/specs/2026-09-21-bopify-foundation-design.md
git commit -m "Route Play to play-here while Bopify is inactive" -m "Play did nothing once another device had the session. It now asks the engine to play here whenever there is a mirror or a stale track to take over, and changes nothing until the engine's events arrive. The command crosses the ABI as bopify_play_here."
```

---

### Task 7: The mirror's clock, and what the inactive status says

**Files:**
- Modify: `Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift`
- Modify: `Packages/BopifyCore/Sources/BopifyPlayback/PlayerPresentation.swift` (after `PlayerContent`)
- Test: `Packages/BopifyCore/Tests/PlaybackTests/PlayerModelTests.swift`, `PlayerPresentationTests.swift`

**Interfaces:**
- Consumes: `PlaybackState.remote` from Task 1.
- Produces:
  - `PlayerModel.remoteUpdatedAt: Date` (`private(set)`, internal, for tests);
  - `displayPositionMs(at:)`, which prefers the mirror;
  - `PlayerModel.displayDurationMs: Int64` and `PlayerModel.isPositionAdvancing: Bool`;
  - `public enum InactiveStatus: Equatable, Sendable { case playingOn(deviceName: String), pausedOn(deviceName: String), notPlaying }`, with `public init(_ state: PlaybackState)`.

- [ ] **Step 1: Write the failing tests**

In `PlayerModelTests.swift`, add after `aStaleTrackCanBePlayedHereButNotAfterAFailure`:

```swift
    @Test func theMirrorAdvancesFromItsReceiptTimeAndOwnsTheDisplayedDuration() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.trackChanged(makeTrack()), .paused(positionMs: 4000),
                                     .activeDeviceChanged(isActive: false), .remotePlayback(makeRemote(positionMs: 1000))])
        let anchor = model.remoteUpdatedAt
        #expect(model.displayPositionMs(at: anchor.addingTimeInterval(2)) == 3000)
        #expect(model.displayPositionMs(at: anchor.addingTimeInterval(600)) == 200_000)
        #expect(model.displayPositionMs(at: anchor.addingTimeInterval(-2)) == 1000)
        #expect(model.displayDurationMs == 200_000)
        #expect(model.isPositionAdvancing)
        await settle(model, engine, [.remotePlayback(makeRemote(isPlaying: false, positionMs: 5000))])
        #expect(model.displayPositionMs(at: model.remoteUpdatedAt.addingTimeInterval(20)) == 5000)
        #expect(!model.isPositionAdvancing)
        await settle(model, engine, [.remotePlayback(nil)])
        #expect(model.displayPositionMs(at: .now) == 4000)
        #expect(model.displayDurationMs == 240_000)
        #expect(!model.isPositionAdvancing)
    }
```

In `PlayerPresentationTests.swift`, add after `errorsSurfaceOverARemoteOutcome`:

```swift
    private func remote(isPlaying: Bool) -> RemotePlayback {
        RemotePlayback(deviceName: "iPhone", trackURI: SpotifyURI("spotify:track:r")!, track: nil,
                       isPlaying: isPlaying, positionMs: 0, durationMs: 1)
    }
    @Test func anInactiveStatusNamesTheMirroredDeviceOrSaysNothingPlays() {
        var state = PlaybackState()
        #expect(InactiveStatus(state) == .notPlaying)
        state.remote = remote(isPlaying: true)
        #expect(InactiveStatus(state) == .playingOn(deviceName: "iPhone"))
        state.remote = remote(isPlaying: false)
        #expect(InactiveStatus(state) == .pausedOn(deviceName: "iPhone"))
    }
```

Run `swift test --package-path Packages/BopifyCore`. Expected: a compile error, because `remoteUpdatedAt`, `displayDurationMs`, `isPositionAdvancing` and `InactiveStatus` don't exist.

- [ ] **Step 2: Implement the clock**

In `PlayerModel.swift`:

1. After `private(set) var positionUpdatedAt = Date.now`, add `private(set) var remoteUpdatedAt = Date.now`.
2. Replace the whole `displayPositionMs(at:)` function, with its doc comment, by:

```swift
    /// Interpolate for display without replacing the engine's authoritative position.
    /// A mirrored device's own clock takes precedence while Bopify is inactive.
    public func displayPositionMs(at date: Date) -> Int64 {
        if let remote = state.remote {
            let elapsed = remote.isPlaying ? max(0, date.timeIntervalSince(remoteUpdatedAt)) * 1000 : 0
            return Int64(min(Double(max(0, remote.durationMs)), Double(remote.positionMs) + elapsed))
        }
        let elapsed = state.phase == .playing ? max(0, date.timeIntervalSince(positionUpdatedAt)) * 1000 : 0
        let position = min(Double(max(0, state.durationMs)), max(0, Double(frozenDisplayPositionMs ?? state.positionMs) + elapsed))
        return Int64(position)
    }

    public var displayDurationMs: Int64 { state.remote?.durationMs ?? state.durationMs }

    /// Views run a display clock only while this is true.
    public var isPositionAdvancing: Bool { state.remote?.isPlaying ?? (state.phase == .playing) }
```

3. In `apply`'s `.remotePlayback` arm, add `remoteUpdatedAt = .now` after the `state.remote = …` line.

- [ ] **Step 3: Implement the status**

In `PlayerPresentation.swift`, after the closing `}` of `public enum PlayerContent`, add:

```swift

/// What the status line says while Bopify is not the active device.
public enum InactiveStatus: Equatable, Sendable {
    case playingOn(deviceName: String), pausedOn(deviceName: String), notPlaying

    public init(_ state: PlaybackState) {
        guard let remote = state.remote else { self = .notPlaying; return }
        self = remote.isPlaying ? .playingOn(deviceName: remote.deviceName) : .pausedOn(deviceName: remote.deviceName)
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run `swift test --package-path Packages/BopifyCore`. Expected: PASS, including both new tests and the existing display-position tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift Packages/BopifyCore/Sources/BopifyPlayback/PlayerPresentation.swift Packages/BopifyCore/Tests/PlaybackTests/PlayerModelTests.swift Packages/BopifyCore/Tests/PlaybackTests/PlayerPresentationTests.swift
git commit -m "Advance the mirror's position and name its device" -m "The mirror's position is anchored when its event arrives and interpolated only while that device plays, as local playback already is. The inactive status becomes a tested choice between naming the playing or paused device and saying nothing plays, replacing the fixed 'Playing on another device'."
```

---

### Task 8: The Monolith player shows the mirror and the stale state

**Files:**
- Modify: `Bopify/Bopify/AppEnvironment.swift:31`
- Modify: `Bopify/Bopify/Views/MonolithPlayerView.swift`
- Modify: `Bopify/Bopify/Views/TransportControls.swift`
- Modify: `Bopify/Bopify/PlaybackState+Localized.swift`
- Modify: `Bopify/Bopify/Localizable.xcstrings`
- Create: `docs/superpowers/verification/MonolithMirrorProbe.swift`
- Modify: `docs/superpowers/verification/run-monolith-probe.py`, `docs/superpowers/verification/MonolithVisualProbe.swift:68`

**Interfaces:**
- Consumes: `PlaybackState.remote`, `PlayerModel.canPlayHere`, `displayPositionMs(at:)`, `displayDurationMs`, `isPositionAdvancing` and `InactiveStatus`.
- Produces:
  - the UI rules from spec Phase 2 item 6;
  - `python3 docs/superpowers/verification/run-monolith-probe.py --derived-data <dir> --output <dir> --probe mirror`, which prints `MONOLITH MIRROR PASS` and exits 0 on success.

- [ ] **Step 1: Write the failing probe**

Check `git status --short Bopify/Bopify/Localizable.xcstrings` first: it must print nothing (Global Constraints).

Create `docs/superpowers/verification/MonolithMirrorProbe.swift`:

```swift
import SwiftUI
import ScreenCaptureKit
import BopifyPlayback
import BopifyDomain

// Production views against a stub engine; never starts Spotify.
@main struct MonolithMirrorProbe {
    private actor Library: LibraryService {
        func savedState(for uri: SpotifyURI) async throws -> Bool { false }
        func save(_ uri: SpotifyURI) async throws {}
        func remove(_ uri: SpotifyURI) async throws {}
    }
    static var output: URL { URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) }
    @MainActor static var failures: [String] = []
    @MainActor static func check(_ value: Bool, _ message: String) {
        print("\(value ? "PASS" : "FAIL"): \(message)")
        if !value { failures.append(message) }
        fflush(nil)
    }
    @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(900)) }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            let engine = StubPlaybackEngine()
            let player = PlayerModel(engine: engine)
            player.start()
            let environment = AppEnvironment(previewPlayer: player, favoriteService: Library())
            let status = StatusItemController(content: MiniPlayerView(environment: environment), environment: environment)
            let panel = app.windows.compactMap { $0 as? StatusPanel }.first!
            // The record is found by role, because the sleeve's title text carries the same label.
            func element(_ label: String, role: String? = nil) -> NSObject? {
                accessibilityTree(panel.contentView!).first {
                    attribute($0, "accessibilityLabel") as? String == label
                        && (role == nil || attribute($0, "accessibilityRole") as? String == role)
                }
            }
            func enabled(_ label: String) -> Bool? { element(label).map { booleanAction($0, "isAccessibilityEnabled") } }
            func recordStatus(_ title: String) -> String? { element(title, role: "AXButton").flatMap { attribute($0, "accessibilityValue") as? String } }
            func pressPlay() { _ = element("Play").map { booleanAction($0, "accessibilityPerformPress") } }
            status.perform(NSSelectorFromString("handleClick"))
            await settle()

            let phone = Track(uri: SpotifyURI("spotify:track:remote")!, title: "Remote track", artists: [ArtistSummary(name: "Phone Artist")],
                              albumTitle: nil, artwork: nil, durationMs: 200_000)
            func mirror(playing: Bool, at position: Int64) -> PlaybackEvent {
                .remotePlayback(RemotePlayback(deviceName: "iPhone", trackURI: phone.uri, track: phone,
                                               isPlaying: playing, positionMs: position, durationMs: 200_000))
            }
            engine.emit(.startupResolved(.remote(deviceName: "iPhone")))
            engine.emit(mirror(playing: true, at: 1000))
            await settle()
            check(environment.isListening && environment.presentation.mode == .expanded && panel.frame.size == CGSize(width: 484, height: 264),
                  "a mirrored track opens the record and sleeve at listening geometry")
            check(recordStatus("Remote track") == "Playing on iPhone", "the record names the mirrored track and its device")
            check(enabled("Play") == true, "Play is enabled while mirroring")
            for label in ["Previous", "Next", "Shuffle", "Repeat", "Up Next", "Spotify favorite", "Mute"] {
                check(enabled(label) == false, "\(label) is disabled while mirroring")
            }
            let playing = await capture(panel, "mirror-playing")
            pressPlay()
            await settle()
            check(engine.recordedCommands == ["playHere"], "Play on the mirror asks the engine to play here")

            engine.emit(mirror(playing: false, at: 5000))
            await settle()
            check(recordStatus("Remote track") == "Paused on iPhone", "a paused device is named as paused")
            let paused = await capture(panel, "mirror-paused")

            let stale = Track(uri: SpotifyURI("spotify:track:stale")!, title: "Stale track", artists: [], albumTitle: nil, artwork: nil, durationMs: 240_000)
            engine.emit(.trackChanged(stale))
            engine.emit(.paused(positionMs: 1545))
            await settle()
            check(recordStatus("Stale track") == "Paused" && player.state.remote == nil, "becoming active drops the mirror")
            let baseline = await capture(panel, "active-paused")
            engine.emit(.activeDeviceChanged(isActive: false))
            engine.emit(.remotePlayback(nil))
            await settle()
            check(recordStatus("Stale track") == "Not playing", "with no device playing, the last track stays and says so")
            check(enabled("Play") == true, "Play is enabled in the stale state")
            let idle = await capture(panel, "stale")
            pressPlay()
            await settle()
            check(engine.recordedCommands == ["playHere", "playHere"], "Play in the stale state asks the engine to play here")

            engine.emit(.failed(.networkUnavailable))
            await settle()
            let error = await capture(panel, "error")
            if let playing, let paused, let baseline, let idle, let error {
                let limit = orangePixels(baseline) + 80
                check(orangePixels(error) > limit, "the rim detector sees an error rim")
                check(orangePixels(playing) <= limit && orangePixels(paused) <= limit && orangePixels(idle) <= limit,
                      "neither the mirror nor the stale state draws the attention rim")
            }
            player.stop()
            print(failures.isEmpty ? "MONOLITH MIRROR PASS" : "MONOLITH MIRROR FAIL")
            if !failures.isEmpty { exit(1) }
            withExtendedLifetime(status) { app.terminate(nil) }
        }
        app.run()
    }

    @MainActor static func capture(_ panel: StatusPanel, _ name: String) async -> CGImage? {
        do {
            let content = try await SCShareableContent.currentProcess
            guard let window = content.windows.first(where: { $0.windowID == panel.windowNumber }) else {
                check(false, "capture \(name): window missing"); return nil
            }
            let config = SCStreamConfiguration()
            config.width = Int(panel.frame.width * 2)
            config.height = Int(panel.frame.height * 2)
            config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: output.appendingPathComponent(name + ".png"))
            print("capture: \(name)")
            return image
        } catch {
            check(false, "capture \(name): \(error)")
            return nil
        }
    }
    /// The same orange test as MonolithVisualProbe's rim check, over the whole window.
    @MainActor static func orangePixels(_ image: CGImage) -> Int {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.2 && color.redComponent > 0.5 && color.greenComponent > 0.15
                    && color.redComponent > color.greenComponent * 1.15 && color.greenComponent > color.blueComponent * 1.3 { count += 1 }
            }
        }
        return count
    }
    @MainActor static func attribute(_ value: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard value.responds(to: selector) else { return nil }
        return value.perform(selector)?.takeUnretainedValue()
    }
    @MainActor static func booleanAction(_ value: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        precondition(value.responds(to: selector), "missing accessibility method \(name)")
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(value.method(for: selector), to: Action.self)(value, selector)
    }
    @MainActor static func accessibilityTree(_ value: Any) -> [NSObject] {
        guard let element = value as? NSObject else { return [] }
        return [element] + ((attribute(element, "accessibilityChildren") as? [Any]) ?? []).flatMap { accessibilityTree($0) }
    }
}
```

In `run-monolith-probe.py`:
- Change `choices=["window", "visual", "artwork", "composition"]` to `choices=["window", "visual", "artwork", "composition", "mirror"]`.
- In the probe mapping, change `'composition': 'MonolithCompositionProbe.swift'}` to `'composition': 'MonolithCompositionProbe.swift', 'mirror': 'MonolithMirrorProbe.swift'}`.

In `MonolithVisualProbe.swift` line 68, change `(.activeDeviceChanged(isActive: false), "Playing on another device"),` to `(.activeDeviceChanged(isActive: false), "Not playing"),`. After a takeover with no mirror yet, the status now says nothing plays here.

- [ ] **Step 2: Run the probe and confirm it fails**

Run the app build, then `python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-mirror-build --output /private/tmp/bopify-mirror-probe --probe mirror`. Expected: `MONOLITH MIRROR FAIL`. At least the listening-geometry check, the status checks and the disabled-control checks fail. If the probe fails because ScreenCaptureKit lacks Screen Recording permission, report that. Never remove the captures to get past it.

- [ ] **Step 3: Implement the UI**

In `AppEnvironment.swift`, replace `var isListening: Bool { authState == .signedIn && player?.state.currentTrack != nil }` with:

```swift
    var isListening: Bool {
        authState == .signedIn && (player?.state.currentTrack != nil || player?.state.remote != nil)
    }
```

In `MonolithPlayerView.swift`:

1. Replace the `direction`, `track` and `occurrenceID` properties with:

```swift
    // Bopify's queue says nothing about which way a mirrored device moved.
    private var direction: CarouselDirection {
        guard player.state.remote == nil else { return .fade }
        return player.state.queue.map { carouselDirection(old: previousQueue, new: $0) } ?? .fade
    }
    private var track: Track? {
        if let remote = player.state.remote { return remote.track }
        guard let current = player.state.queue?.current else { return player.state.currentTrack }
        return current.uri == player.state.currentTrack?.uri ? player.state.currentTrack : current.track
    }
    private var occurrenceID: String {
        player.state.remote?.trackURI.rawValue ?? player.state.queue?.current?.id ?? player.state.currentTrack?.uri.rawValue ?? "missing"
    }
```

2. In `needsAttention`, change `return player.commandNotice != nil || !player.state.isActiveDevice` to `return player.commandNotice != nil`. Another device playing, or none, is not an error.
3. In `record(diameter:)`, change `TimelineView(PlaybackClockSchedule(running: player.state.phase == .playing && presentation.isVisible, reducedMotion: reduceMotion))` to `TimelineView(PlaybackClockSchedule(running: player.isPositionAdvancing && presentation.isVisible, reducedMotion: reduceMotion))`. Change `durationMs: player.state.durationMs,` in the `RadialProgressView` call to `durationMs: player.displayDurationMs,`.
4. In `controls`, change the `FavoriteButton`'s `.disabled(track?.uri != player.state.currentTrack?.uri)` to `.disabled(player.state.remote != nil || track?.uri != player.state.currentTrack?.uri)`.
5. In `controls`, change `TimelineView(PlaybackClockSchedule(running: player.state.phase == .playing && presentation.isVisible, reducedMotion: true))` to `TimelineView(PlaybackClockSchedule(running: player.isPositionAdvancing && presentation.isVisible, reducedMotion: true))`. Change `Text(playbackTime(player.state.durationMs))` to `Text(playbackTime(player.displayDurationMs))`.
6. In `controls`, after the queue button's `.accessibilityLabel(Text("queue.title"))`, add `.disabled(player.state.remote != nil)`. The remote queue is not modelled.
7. In `status`, change `case .idle: Text("player.inactiveDevice.title")` to `case .idle: player.state.localizedStatusText`.

In `TransportControls.swift`, change the Play button's `.disabled(!canControl || state.phase == .loading || state.phase == .buffering)` to `.disabled(!(canControl || model.canPlayHere) || state.phase == .loading || state.phase == .buffering)`.

In `PlaybackState+Localized.swift`, add `import BopifyPlayback` after `import BopifyDomain`. Replace `case .idle: Text("player.inactiveDevice.title")` with:

```swift
        case .idle:
            switch InactiveStatus(self) {
            case let .playingOn(deviceName): Text("player.remote.title \(deviceName)")
            case let .pausedOn(deviceName): Text("player.remote.paused \(deviceName)")
            case .notPlaying: Text("player.notPlaying")
            }
```

In `Localizable.xcstrings`, insert this entry between the `"player.loading"` and `"player.nowPlaying"` entries:

```json
    "player.notPlaying" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Not playing"
          }
        }
      }
    },
```

Insert this entry between the `"player.progress.value"` and `"player.remote.title %@"` entries:

```json
    "player.remote.paused %@" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Paused on %@"
          }
        }
      }
    },
```

`player.inactiveDevice.title` stays, because `MiniPlayerView.swift`'s `StartupPlayerContent` still uses it.

- [ ] **Step 4: Run every probe and the tests**

Run the app build, then run each of these and check its result:

```sh
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-mirror-build --output /private/tmp/bopify-mirror-probe --probe mirror
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-mirror-build --output /private/tmp/bopify-mirror-visual --probe visual
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-mirror-build --output /private/tmp/bopify-mirror-composition --probe composition
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-mirror-build --output /private/tmp/bopify-mirror-window --probe window
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-mirror-build --output /private/tmp/bopify-mirror-artwork --probe artwork
```

Expected: `MONOLITH MIRROR PASS`, and each other probe prints its own PASS line and exits 0. Also run `swift test --package-path Packages/BopifyCore` (expected: PASS).

Open and look at `/private/tmp/bopify-mirror-probe/mirror-playing.png`, `mirror-paused.png` and `stale.png`. In the report, describe each one:
- the title shown;
- the status line;
- that no orange rim is present;
- that the controls other than Play look disabled.

These captures stand in for previews, as the spec now says (Task 5, Step 4). Also check `git diff Bopify/Bopify/Localizable.xcstrings`: it should show only the two new entries. Report any reformatting Xcode added.

- [ ] **Step 5: Commit**

```bash
git add Bopify/Bopify/AppEnvironment.swift Bopify/Bopify/Views/MonolithPlayerView.swift Bopify/Bopify/Views/TransportControls.swift Bopify/Bopify/PlaybackState+Localized.swift Bopify/Bopify/Localizable.xcstrings docs/superpowers/verification/MonolithMirrorProbe.swift docs/superpowers/verification/run-monolith-probe.py docs/superpowers/verification/MonolithVisualProbe.swift
git commit -m "Show the mirrored device and the stale state in the player" -m "After a takeover the record froze on Bopify's old track with an error rim and 'Playing on another device'. It now shows the other device's track and moving progress with its name, or keeps the last track and says nothing plays, and Play takes the session over. Other controls stay disabled because the remote queue is not modelled. A native probe checks the states, the controls and the missing rim."
```

---

### Task 9: Live verification against a real account

**Files:**
- Modify: `docs/superpowers/verification/2026-09-26-startup-restore.md` (append a Phase 2 section)
- Modify: `docs/superpowers/specs/2026-09-26-startup-restore-design.md` (the status line, line 4)

The controller runs this task with the user, not a subagent. It needs the user's phone, their Spotify account, and permission to launch the app. Ask before each scenario that involves their devices. Run **only one Bopify instance at a time**, because a second connection ends the first instance's session. A new build may trigger a keychain prompt that the user must allow.

- [ ] **Step 1: Build with diagnostic logging and start log capture**

Check 5 must see librespot's dealer lines, so this run uses the same local, never-committed diagnostic edit as appendix run 5. In `rust/crates/bopify-core/src/logging.rs`:
- change `const LIBRESPOT_CEILING: LevelFilter = LevelFilter::Warn;` to `LevelFilter::Debug`;
- change `librespot: Category::new(CATEGORY_LIBRESPOT, false),` to `true`.

Then:

```sh
./scripts/build-rust.sh
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-mirror-build build
/usr/bin/log stream --style compact --level debug --predicate 'subsystem == "my.snsoft.bopify"' > /private/tmp/bopify-mirror.log
```

Run the log stream in the background. Launch with `/private/tmp/bopify-mirror-build/Build/Products/Debug/Bopify.app/Contents/MacOS/Bopify`, and quit through the status item's Quit menu item.

- [ ] **Step 2: Run the five scenarios and record each result**

For each scenario, record:
- the `startup resolved outcome=` and `remote playback present=` lines;
- the phase transitions;
- any `play here:` warnings;
- what the user sees.

1. **The mirror follows.** The user plays on the phone and then launches Bopify. Expect `outcome=remote`, then the record and sleeve showing the phone's track with "Playing on <device>" and a moving ring. The user skips a track on the phone. Expect the mirror to follow within a few seconds, and the phone never to pause.
2. **Play here moves playback.** The user presses Play on the mirror. Expect `loading → playing` on Bopify, the sleeve's status clearing, and the user confirming that the phone stopped and the Mac continues the same track at about the same position.
3. **A takeover becomes the mirror.** While Bopify plays, the user picks the phone in Spotify's device picker. Expect `activeDeviceChanged` inactive, then the mirror with "Playing on <device>". There should be no orange rim and no frozen stale track.
4. **Stale, then resume that session.** The user pauses on the phone (expect "Paused on <device>"), then closes Spotify on the phone. Once the phone leaves the cluster, expect the last track with "Not playing" and no rim. The user presses Play. Expect that session restored here and playing from its last reported position, not Liked Songs. If the phone lingers in the cluster, record how long it took to leave.
5. **No dealer drop.** In the log from scenario 2, look for what run 5 showed: the server's "Request disconnect", a failed reply to its transfer request, and a new connection id. Their absence is a **pass**. Also record whether the `play here: transfer replied` warning appeared, and with what status.

- [ ] **Step 3: Remove the diagnostic edit and rebuild**

Run `git diff rust/crates/bopify-core/src/logging.rs`. It must show only the two diagnostic lines. Restore them by hand, and confirm `git status --short` shows no change to `logging.rs`. Then rerun `./scripts/build-rust.sh` and the Step 1 `xcodebuild`. Stop the log stream with `pkill -f "log stream --style compact --level debug"`.

- [ ] **Step 4: Write the evidence**

Append a "Phase 2: mirror and play here (2026-09-27)" section to `docs/superpowers/verification/2026-09-26-startup-restore.md`. Include:
- the build commands, and a note that it was a diagnostic-logging build;
- one row per scenario: setup, expected, observed log lines, user confirmation, and pass/fail/not reproduced;
- the probe captures from Task 8, by path;
- any deviation from the spec with its cause.

Don't paste user ids or anything the diagnostic librespot log revealed beyond the lines named above. If every scenario passed, update the spec's status line (line 4): replace `and approved on 2026-09-27, and is not yet implemented.` with `and approved on 2026-09-27, then implemented and live-verified on <the run's date> (see the verification doc's Phase 2 section).` Otherwise, record what failed and leave the status as it is.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/verification/2026-09-26-startup-restore.md docs/superpowers/specs/2026-09-26-startup-restore-design.md
git commit -m "Record live verification of mirroring and play here" -m "Evidence from real sessions for each phase 2 scenario, including whether sending the transfer off the Spirc loop avoided run 5's dealer drop."
```

---

## Out of scope

- **The space bar while inactive.** `StatusItemController`'s `onTogglePlayback` stays gated on an active device; only the Play button calls play here.
- **Mirroring the remote queue.** Up Next stays disabled while mirroring.
- **A phone playing a local file.** Its URI has more than three parts, so `SpotifyURI` rejects it, the event is dropped at decoding, and the mirror keeps its previous value.
- **Surfacing `Stopped`/`Unavailable`** when a whole context can't play (a phase 1 risk, still open).
- **A brief "Not playing" at a takeover.** The deactivation reaches Swift before the mirror's metadata lookup finishes, so "Not playing" shows for about as long as one lookup.
