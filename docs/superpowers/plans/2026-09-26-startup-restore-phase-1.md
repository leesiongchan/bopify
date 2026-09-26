# Startup Restore (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bopify never opens on "Nothing playing": at connect it restores Spotify's last session paused, or loads Liked Songs paused, or reports the device that is already playing.

**Architecture:** Our librespot patch gains a `ConnectConfig.startup_restore` flag. The first connect cluster runs a pure `startup_decision`, then restores (with a forced pause), activates and loads Liked Songs, or stays inactive. It always emits one `PlayerEvent::StartupResolved`. bopify-core forwards that as `startupResolved` JSON. Swift folds it into `PlaybackState.startup`, and a small `PlayerContent` enum picks between the player, a loading placeholder, "Playing on <device>" and the existing paste view. `activate()` is removed end to end.

**Tech Stack:** Rust (librespot `939dc5e` plus `rust/patches/librespot-queue-selection.patch`, rust-protobuf 3, serde), a C ABI, Swift 6 with Swift Testing, and SwiftUI on macOS 14 (arm64).

**Spec:** `docs/superpowers/specs/2026-09-26-startup-restore-design.md`. Read it first; it holds the spike evidence behind every rule below.

## Global Constraints

- **Pinned librespot.** Revision `939dc5ee9d833e1980f9495241219d9d4868a061`, checked out at `.build/librespot-939dc5e`. The only tracked record of our librespot changes is `rust/patches/librespot-queue-selection.patch`.
- **Regenerate the patch after every change to `.build/librespot-939dc5e`.** Run `git -C .build/librespot-939dc5e diff --no-ext-diff --binary HEAD > rust/patches/librespot-queue-selection.patch`, then `./scripts/prepare-librespot.sh`. The script must print `Pinned librespot queue patch verified.`
- **Never run `git checkout`, `git restore`, `git stash` or `git reset` inside `.build/librespot-939dc5e`.** The patch lives only in that checkout's working tree, not its index, so any of those commands would destroy it.
- **New files in the librespot checkout** must be registered with `git -C .build/librespot-939dc5e add -N <path>` before regenerating the patch. Otherwise they are missing from the diff, and the prepare script rejects them as untracked.
- **The connect crate has `#![warn(missing_docs)]`.** Every new `pub` item in `connect/` gets a doc comment.
- **Check `Bopify/Bopify/Localizable.xcstrings` before editing it.** The user had unrelated uncommitted edits in it on 2026-09-26. If `git status --short Bopify/Bopify/Localizable.xcstrings` shows it modified before your edit, **stop and ask the user** whether to commit their change first. Never commit their hunks as part of a task.
- **The shell is zsh.** `log` is a builtin, so use `/usr/bin/log`. `tail` may be aliased, so use `command tail`.
- **Commit messages** are an imperative subject under 72 characters plus a body that explains why. No `feat:` prefixes. No `Co-Authored-By` lines (AGENTS.md).
- **Logging** stays in our own categories: `playback` for decisions. Device names are personal data, so never log them publicly.
- **Comments** explain why, in at most two sentences.
- **Every commit ends green.** `swift test` and the relevant `cargo test` both pass before any commit that touches their tree.

## Commands used throughout

```sh
# Rust: our crate, then the patched connect crate (runs its tests through our workspace)
cargo test --manifest-path rust/Cargo.toml
cargo test --manifest-path rust/Cargo.toml -p librespot-connect
# Rebuild the static library, header and xcframework after any Rust or ABI change
./scripts/build-rust.sh
# Swift package
(cd Packages/BopifyCore && swift test)
# App
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' build
```

## File Structure

| File | Change | Responsibility |
| --- | --- | --- |
| `.build/librespot-939dc5e/playback/src/player.rs` | modify | `StartupOutcome`, `PlayerEvent::StartupResolved`, and its emitter |
| `.build/librespot-939dc5e/connect/src/startup.rs` | **create** | Pure `startup_decision(&Cluster, own_device_id)` and its tests |
| `.build/librespot-939dc5e/connect/src/lib.rs` | modify | `mod startup;` |
| `.build/librespot-939dc5e/connect/src/state.rs` | modify | `ConnectConfig.startup_restore` |
| `.build/librespot-939dc5e/connect/src/spirc.rs` | modify | Run the decision once per engine; restore or load Liked Songs; emit the outcome |
| `rust/patches/librespot-queue-selection.patch` | regenerate | Tracked copy of all of the above |
| `rust/crates/bopify-core/src/event.rs` | modify | `WireEvent::StartupResolved` and its translation |
| `rust/crates/bopify-core/src/engine.rs` | modify | Enable `startup_restore`; remove `activate` |
| `rust/crates/bopify-core/src/ffi.rs` | modify | Remove `bopify_activate` |
| `Packages/BopifyCore/Sources/BopifyDomain/PlaybackState.swift` | modify | `StartupOutcome`, `StartupPhase`, `PlaybackState.startup` |
| `Packages/BopifyCore/Sources/BopifyDomain/PlaybackEvent.swift` | modify | `.startupResolved` decoding |
| `Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift` | modify | Remove `activate()` |
| `Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift` | modify | Fold `.startupResolved`; remove `activate()` |
| `Packages/BopifyCore/Sources/BopifyPlayback/PlayerPresentation.swift` | modify | `PlayerContent` precedence |
| `Packages/BopifyCore/Sources/BopifyPlayback/LibrespotEngine.swift`, `StubPlaybackEngine.swift` | modify | Remove `activate()` |
| `Bopify/Bopify/Views/MiniPlayerView.swift` | modify | Render `PlayerContent` through a private `StartupContent` view |
| `Bopify/Bopify/Views/PlayerPreviews.swift` | modify | Previews for loading, remote and last resort |
| `Bopify/Bopify/Localizable.xcstrings` | modify | `player.remote.title %@` |
| `Bopify/Bopify/AppEnvironment.swift` | modify | Stop calling `activate()` |
| `docs/superpowers/specs/2026-09-21-bopify-foundation-design.md`, `README.md` | modify | ABI and patch descriptions |
| `docs/superpowers/verification/2026-09-26-startup-restore.md` | **create** | Live verification evidence |

---

### Before Task 1: prepare the tree

`.build/` and `artifacts/` are gitignored. A fresh checkout or an isolated worktree therefore has neither the librespot checkout that Tasks 1–3 edit nor the xcframework that `swift test` needs in order to configure.

- [ ] Run `./scripts/build-rust.sh`. It clones and patches `.build/librespot-939dc5e` when absent, then builds the xcframework. Expected: `Pinned librespot queue patch verified.` and `xcframework successfully written out`.
- [ ] Run `git -C .build/librespot-939dc5e rev-parse HEAD`. Expected: `939dc5ee9d833e1980f9495241219d9d4868a061`.
- [ ] Run `cargo test --manifest-path rust/Cargo.toml && cargo test --manifest-path rust/Cargo.toml -p librespot-connect && (cd Packages/BopifyCore && swift test)`. Expected: all green. This is the baseline, so any later failure belongs to this plan's changes.

---

### Task 1: `StartupResolved` crosses from librespot into Swift state

`event.rs` requires the wire contract and `BopifyDomain.PlaybackEvent` to change in the same commit, so this task covers the whole contract: the librespot event, the wire JSON, Swift decoding and the state fold.

**Files:**
- Modify: `.build/librespot-939dc5e/playback/src/player.rs`: after `pub struct QueueTrack` (around line 158); `enum PlayerCommand` (around line 141); `pub enum PlayerEvent` after `SetQueue` (around line 276); `impl Player` after `emit_set_queue_event` (around line 690); `PlayerInternal` command handler after the `EmitSetQueueEvent` arm (around line 2392); `impl fmt::Debug for PlayerCommand` after the `EmitSetQueueEvent` arm (around line 2608)
- Modify: `rust/crates/bopify-core/src/event.rs`
- Modify: `Packages/BopifyCore/Sources/BopifyDomain/PlaybackState.swift`
- Modify: `Packages/BopifyCore/Sources/BopifyDomain/PlaybackEvent.swift`
- Modify: `Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift:143-231` (`apply`)
- Test: `rust/crates/bopify-core/src/event.rs` (`mod tests`), `Packages/BopifyCore/Tests/DomainTests/PlaybackEventTests.swift`, `Packages/BopifyCore/Tests/PlaybackTests/PlayerModelTests.swift`
- Regenerate: `rust/patches/librespot-queue-selection.patch`

**Interfaces:**
- Produces, in `librespot_playback::player`: `pub enum StartupOutcome { Restored, LikedSongs, Remote { device_name: String }, Nothing }` (derives `Clone, Debug, PartialEq, Eq`); `PlayerEvent::StartupResolved { outcome: StartupOutcome }`; `Player::emit_startup_resolved_event(&self, outcome: StartupOutcome)`.
- Produces, in bopify-core: `WireEvent::StartupResolved { outcome: &'static str, device_name: Option<String> }`, serialised as `{"type":"startupResolved","outcome":"restored"|"likedSongs"|"remote"|"nothing"}`, plus `"deviceName"` only for `remote`.
- Produces, in Swift: `public enum StartupOutcome: Hashable, Sendable { case restored, likedSongs, nothing, remote(deviceName: String) }`; `public enum StartupPhase: Hashable, Sendable { case pending, resolved(StartupOutcome) }`; `PlaybackState.startup: StartupPhase`, defaulting to `.pending`; `PlaybackEvent.startupResolved(StartupOutcome)`.

Nothing emits this event until Task 6 turns the flag on, so the app behaves the same after this commit.

- [ ] **Step 1: Write the failing tests**

Append inside `mod tests` in `rust/crates/bopify-core/src/event.rs`:

```rust
    #[test]
    fn startup_outcomes_carry_a_device_name_only_when_remote() {
        let remote = translate(PlayerEvent::StartupResolved {
            outcome: StartupOutcome::Remote {
                device_name: "iPhone".into(),
            },
        });
        assert_eq!(
            serde_json::to_string(&remote.unwrap()).unwrap(),
            r#"{"type":"startupResolved","outcome":"remote","deviceName":"iPhone"}"#
        );
        for (outcome, wire) in [
            (StartupOutcome::Restored, "restored"),
            (StartupOutcome::LikedSongs, "likedSongs"),
            (StartupOutcome::Nothing, "nothing"),
        ] {
            let event = translate(PlayerEvent::StartupResolved { outcome }).unwrap();
            assert_eq!(
                serde_json::to_string(&event).unwrap(),
                format!(r#"{{"type":"startupResolved","outcome":"{wire}"}}"#)
            );
        }
    }
```

Change the import at the top of `event.rs` from `use librespot_playback::player::PlayerEvent;` to:

```rust
use librespot_playback::player::{PlayerEvent, StartupOutcome};
```

Add to `PlaybackEventTests`:

```swift
    @Test func decodesEveryStartupOutcome() throws {
        #expect(try decode(#"{"type":"startupResolved","outcome":"restored"}"#) == .startupResolved(.restored))
        #expect(try decode(#"{"type":"startupResolved","outcome":"likedSongs"}"#) == .startupResolved(.likedSongs))
        #expect(try decode(#"{"type":"startupResolved","outcome":"nothing"}"#) == .startupResolved(.nothing))
        #expect(try decode(#"{"type":"startupResolved","outcome":"remote","deviceName":"iPhone"}"#)
                == .startupResolved(.remote(deviceName: "iPhone")))
    }

    @Test func rejectsAnUnknownOutcomeAndARemoteWithoutADevice() {
        #expect(throws: (any Error).self) { try decode(#"{"type":"startupResolved","outcome":"teleported"}"#) }
        #expect(throws: (any Error).self) { try decode(#"{"type":"startupResolved","outcome":"remote"}"#) }
    }
```

Add to `PlayerModelTests`:

```swift
    @Test func startupStaysPendingUntilTheEngineResolvesIt() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        #expect(model.state.startup == .pending)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.loading])
        #expect(model.state.startup == .pending)
        await settle(model, engine, [.startupResolved(.restored), .trackChanged(makeTrack()), .paused(positionMs: 1545)])
        #expect(model.state.startup == .resolved(.restored))
        #expect(model.state.phase == .paused)
        #expect(model.state.positionMs == 1545)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test --manifest-path rust/Cargo.toml -p bopify-core startup_outcomes`
Expected: compile error `unresolved import librespot_playback::player::StartupOutcome`.
Run: `(cd Packages/BopifyCore && swift test --filter "PlaybackEventTests|PlayerModelTests")`
Expected: compile errors, `type 'PlaybackEvent' has no member 'startupResolved'` and `value of type 'PlaybackState' has no member 'startup'`.

- [ ] **Step 3: Add the librespot event**

In `playback/src/player.rs`, directly after the `QueueTrack` struct:

```rust
/// What `Spirc` did with the account's last session when its first connect
/// cluster arrived. Emitted once, and only when `ConnectConfig::startup_restore` is set.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StartupOutcome {
    /// The last session was taken over, paused.
    Restored,
    /// Nothing was restorable, so the user's Liked Songs were loaded, paused.
    LikedSongs,
    /// Another device is playing; this device stayed inactive.
    Remote {
        /// That device's name, as Spotify's device picker shows it.
        device_name: String,
    },
    /// Liked Songs could not be loaded either; the device is active and empty.
    Nothing,
}
```

In `enum PlayerCommand`, after the `EmitSetQueueEvent { .. },` variant:

```rust
    EmitStartupResolvedEvent(StartupOutcome),
```

In `pub enum PlayerEvent`, after the `SetQueue { .. },` variant:

```rust
    /// Fired once, after the connect-time startup decision.
    StartupResolved {
        outcome: StartupOutcome,
    },
```

In `impl Player`, after `emit_set_queue_event`:

```rust
    pub fn emit_startup_resolved_event(&self, outcome: StartupOutcome) {
        self.command(PlayerCommand::EmitStartupResolvedEvent(outcome));
    }
```

In the `PlayerInternal` command `match`, after the `PlayerCommand::EmitSetQueueEvent { .. } => self.send_event(PlayerEvent::SetQueue { .. }),` arm:

```rust
            PlayerCommand::EmitStartupResolvedEvent(outcome) => {
                self.send_event(PlayerEvent::StartupResolved { outcome })
            }
```

In `impl fmt::Debug for PlayerCommand`, after the `EmitSetQueueEvent` arm:

```rust
            PlayerCommand::EmitStartupResolvedEvent(outcome) => f
                .debug_tuple("EmitStartupResolvedEvent")
                .field(&outcome)
                .finish(),
```

- [ ] **Step 4: Add the wire event and its translation**

In `rust/crates/bopify-core/src/event.rs`, add this variant as the last entry of `pub enum WireEvent`, after `Failed { .. },`:

```rust
    #[serde(rename_all = "camelCase")]
    StartupResolved {
        outcome: &'static str,
        #[serde(skip_serializing_if = "Option::is_none")]
        device_name: Option<String>,
    },
```

In `translate`, directly after the `PlayerEvent::SetQueue { .. } => Some(WireEvent::QueueChanged { .. }),` arm:

```rust
        PlayerEvent::StartupResolved { outcome } => Some(startup_resolved(outcome)),
```

After the `dropped` function:

```rust
fn startup_resolved(outcome: StartupOutcome) -> WireEvent {
    let (outcome, device_name) = match outcome {
        StartupOutcome::Restored => ("restored", None),
        StartupOutcome::LikedSongs => ("likedSongs", None),
        StartupOutcome::Remote { device_name } => ("remote", Some(device_name)),
        StartupOutcome::Nothing => ("nothing", None),
    };
    // The outcome only: a device name is whatever the user called their phone.
    log::info!("event: startup resolved outcome={outcome}");
    WireEvent::StartupResolved {
        outcome,
        device_name,
    }
}
```

- [ ] **Step 5: Add the Swift state types**

At the top of `PlaybackState.swift`, before `public enum PlaybackPhase`:

```swift
/// What the engine did at connect time with the account's last session.
public enum StartupOutcome: Hashable, Sendable {
    case restored, likedSongs, nothing
    case remote(deviceName: String)
}

/// Pending until the engine's one startup event, so the UI can show loading
/// rather than "Nothing playing" while the session is restored.
public enum StartupPhase: Hashable, Sendable {
    case pending
    case resolved(StartupOutcome)
}
```

In `PlaybackState`, after `public var isActiveDevice = false`:

```swift
    public var startup: StartupPhase = .pending
```

- [ ] **Step 6: Decode the event**

In `PlaybackEvent.swift`, add `case startupResolved(StartupOutcome)` after `case failed(PlayerError)`. Add `outcome, deviceName` to `CodingKeys` (as a new `case outcome, deviceName` line). In `init(from:)`, add before `default:`:

```swift
        case "startupResolved":
            switch try c.decode(String.self, forKey: .outcome) {
            case "restored": self = .startupResolved(.restored)
            case "likedSongs": self = .startupResolved(.likedSongs)
            case "nothing": self = .startupResolved(.nothing)
            case "remote": self = .startupResolved(.remote(deviceName: try c.decode(String.self, forKey: .deviceName)))
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .outcome, in: c, debugDescription: "unrecognised startup outcome \(other)")
            }
```

- [ ] **Step 7: Fold it in `PlayerModel.apply`**

Add this case to the `switch event` in `apply`, after the `.failed` case. It's the only exhaustive switch over `PlaybackEvent`.

```swift
        case let .startupResolved(outcome):
            state.startup = .resolved(outcome)
            let kind = switch outcome {
            case .restored: "restored"
            case .likedSongs: "likedSongs"
            case .remote: "remote"
            case .nothing: "nothing"
            }
            BopifyLog.playback.info("startup resolved outcome=\(kind, privacy: .public)")
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `cargo test --manifest-path rust/Cargo.toml -p bopify-core startup_outcomes`
Expected: `test result: ok. 1 passed`.
Run: `cargo test --manifest-path rust/Cargo.toml && cargo test --manifest-path rust/Cargo.toml -p librespot-connect`
Expected: every test passes.
Run: `(cd Packages/BopifyCore && swift test)`
Expected: all Swift tests pass, including the three new ones. Don't run `./scripts/build-rust.sh` yet: it calls `prepare-librespot.sh`, which rejects checkout edits until Step 9 records them in the patch. This task changes no ABI, so the existing xcframework is fine.

- [ ] **Step 9: Regenerate and verify the patch**

```sh
git -C .build/librespot-939dc5e diff --no-ext-diff --binary HEAD > rust/patches/librespot-queue-selection.patch
./scripts/prepare-librespot.sh
```
Expected: `Pinned librespot queue patch verified.`

- [ ] **Step 10: Commit**

```bash
git add rust/patches/librespot-queue-selection.patch rust/crates/bopify-core/src/event.rs Packages/BopifyCore/Sources/BopifyDomain/PlaybackState.swift Packages/BopifyCore/Sources/BopifyDomain/PlaybackEvent.swift Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift Packages/BopifyCore/Tests/DomainTests/PlaybackEventTests.swift Packages/BopifyCore/Tests/PlaybackTests/PlayerModelTests.swift
git commit -m "Carry a one-shot startup outcome from librespot into player state" -m "The connect handler will decide at launch whether it restored the last session, loaded Liked Songs, found another device playing, or loaded nothing. Until that answer arrives the player has no track and an idle phase, the exact state that renders Nothing playing, so the outcome gets its own event and a pending-by-default slot in state."
```

---

### Task 2: Pure startup decision in the patched connect crate

**Files:**
- Create: `.build/librespot-939dc5e/connect/src/startup.rs`
- Modify: `.build/librespot-939dc5e/connect/src/lib.rs:15`, adding `mod startup;` after `mod queue;`
- Regenerate: `rust/patches/librespot-queue-selection.patch`

**Interfaces:**
- Produces (crate-private): `pub(crate) enum StartupDecision { Remote { device_name: String }, Restore(TransferState), Fallback }` (derives `Debug`), and `pub(crate) fn startup_decision(cluster: &Cluster, own_device_id: &str) -> StartupDecision`. A `Restore` always carries `playback.is_paused == Some(true)`.

- [ ] **Step 1: Write the module with its tests and a stub body**

Create `connect/src/startup.rs`:

```rust
//! Bopify: the connect-time decision behind `ConnectConfig::startup_restore`.

use crate::protocol::{connect::Cluster, transfer_state::TransferState};
use protobuf::Message;

#[derive(Debug)]
pub(crate) enum StartupDecision {
    Remote { device_name: String },
    Restore(TransferState),
    Fallback,
}

pub(crate) fn startup_decision(_cluster: &Cluster, _own_device_id: &str) -> StartupDecision {
    StartupDecision::Fallback
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
        for data in [session("", "", true), session("-", "", true), Vec::new()] {
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
            matches!(&decision, StartupDecision::Remote { device_name } if device_name == "iPhone"),
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
    fn this_device_is_never_mirrored() {
        let decision = startup_decision(&cluster(OWN, "spotify:track:x", Vec::new()), OWN);
        assert!(!matches!(decision, StartupDecision::Remote { .. }), "{decision:?}");
    }
}
```

In `connect/src/lib.rs`, add `mod startup;` on the line after `mod queue;`. Then register the file:

```sh
git -C .build/librespot-939dc5e add -N connect/src/startup.rs
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test --manifest-path rust/Cargo.toml -p librespot-connect startup`
Expected: 3 failures (`restores_the_last_session…`, `a_session_left_playing…`, `a_session_started_from_bare_uris…` panic with `expected Restore, got Fallback`) and 1 failure in `another_device_playing…`. The other three pass. A `function startup_decision is never used` warning is expected until Task 3.

- [ ] **Step 3: Implement the decision**

Replace the stub `startup_decision` with:

```rust
pub(crate) fn startup_decision(cluster: &Cluster, own_device_id: &str) -> StartupDecision {
    let active = cluster.active_device_id.as_str();
    if !active.is_empty() {
        let has_track = cluster
            .player_state
            .track
            .as_ref()
            .is_some_and(|track| !track.uri.is_empty());
        return if active != own_device_id && has_track {
            let device_name = cluster
                .device
                .get(active)
                .map(|device| device.name.clone())
                .unwrap_or_default();
            StartupDecision::Remote { device_name }
        } else {
            // A trackless active device has nothing to mirror, and while any device is
            // active the transfer data is a stub that would pull its context over.
            StartupDecision::Fallback
        };
    }
    match TransferState::parse_from_bytes(&cluster.transfer_data) {
        Ok(mut transfer) if is_usable(&transfer) => {
            // Set before handle_transfer, never as a pause after it: it also stops
            // handle_transfer extrapolating a stale timestamp past where playback was.
            transfer.playback.mut_or_insert_default().is_paused = Some(true);
            StartupDecision::Restore(transfer)
        }
        _ => StartupDecision::Fallback,
    }
}

/// Checks content, not byte length: an empty Bopify session still serialises
/// to 66 bytes of transfer data.
fn is_usable(transfer: &TransferState) -> bool {
    let context = transfer.current_session.context.uri.as_deref().unwrap_or_default();
    let track = transfer.playback.current_track.uri.as_deref().unwrap_or_default();
    (!context.is_empty() && context != "-") || !track.is_empty()
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test --manifest-path rust/Cargo.toml -p librespot-connect startup`
Expected: `test result: ok. 7 passed`.
Run: `cargo test --manifest-path rust/Cargo.toml -p librespot-connect && cargo test --manifest-path rust/Cargo.toml`
Expected: all pass.

- [ ] **Step 5: Regenerate and verify the patch**

```sh
git -C .build/librespot-939dc5e diff --no-ext-diff --binary HEAD > rust/patches/librespot-queue-selection.patch
./scripts/prepare-librespot.sh
```
Expected: `Pinned librespot queue patch verified.` Also confirm that `rg -c "startup.rs" rust/patches/librespot-queue-selection.patch` prints a non-zero count.

- [ ] **Step 6: Commit**

```bash
git add rust/patches/librespot-queue-selection.patch
git commit -m "Decide restore, mirror or fallback from the first connect cluster" -m "librespot already carries the account's last session in the connect cluster but only restores it for its own session id, which a fresh launch never has. A pure decision over the cluster makes each case the spike observed unit-testable: usable session, empty session, active device with and without a track, and a stale playing state that must resume paused."
```

---

### Task 3: Spirc runs the decision once, behind `ConnectConfig.startup_restore`

**Files:**
- Modify: `.build/librespot-939dc5e/connect/src/state.rs:80-109` (`ConnectConfig` and its `Default`)
- Modify: `.build/librespot-939dc5e/connect/src/spirc.rs`: imports (lines 1-45), `struct SpircTask` (around line 100), `Spirc::new` (around lines 235 and 314), `handle_connection_id_update` (after `self.connect_established = true;`, around line 1000), plus new methods placed directly after `handle_connection_id_update`
- Regenerate: `rust/patches/librespot-queue-selection.patch`

**Interfaces:**
- Consumes: `startup_decision` and `StartupDecision` (Task 2); `StartupOutcome` and `Player::emit_startup_resolved_event` (Task 1).
- Produces: `pub startup_restore: bool` on `ConnectConfig`, defaulting to `false`. With the flag off, behaviour is byte-for-byte upstream. Task 6 turns it on.

This handler needs a live `Session`, so it has no unit test. Its branches are the pure decision (Task 2) plus calls to existing librespot functions. Task 7 exercises it live.

- [ ] **Step 1: Add the config flag**

In `connect/src/state.rs`, add as the last field of `pub struct ConnectConfig`:

```rust
    /// Bopify: on the first connect cluster, restore the last session paused, else
    /// load Liked Songs paused, unless another device is playing (default: false)
    pub startup_restore: bool,
```

Add `startup_restore: false,` as the last field in `impl Default for ConnectConfig`.

- [ ] **Step 2: Carry the flag and a once-only marker on `SpircTask`**

In `spirc.rs`, add these two fields after `emit_set_queue_events: bool,` in `struct SpircTask`:

```rust
    startup_restore: bool,
    /// The startup decision runs on the first connection id only; later ones are dealer reconnects.
    startup_resolved: bool,
```

In `Spirc::new`, next to `let emit_set_queue_events = config.emit_set_queue_events;`:

```rust
        let startup_restore = config.startup_restore;
```

In the `SpircTask { .. }` initialiser, after `emit_set_queue_events,`:

```rust
            startup_restore,
            startup_resolved: false,
```

Extend the imports. In the `playback::{ .. }` group, change `player::{Player, PlayerEvent, PlayerEventChannel},` to:

```rust
        player::{Player, PlayerEvent, PlayerEventChannel, StartupOutcome},
```

and add a line inside the top-level `use crate::{ .. }` list:

```rust
    startup::{StartupDecision, startup_decision},
```

- [ ] **Step 3: Branch in `handle_connection_id_update`**

Directly after `self.connect_established = true;`, and before `let same_session = …`, insert:

```rust
        if self.startup_restore && !self.startup_resolved {
            self.startup_resolved = true;
            let outcome = self.resolve_startup(&cluster).await;
            self.player.emit_startup_resolved_event(outcome);
            return Ok(());
        }
```

- [ ] **Step 4: Add the two methods after `handle_connection_id_update`**

```rust
    /// Bopify: never returns an error, because an `Err` from the connection-id
    /// handler ends the Spirc task, and Swift would see a lost session.
    async fn resolve_startup(&mut self, cluster: &Cluster) -> StartupOutcome {
        match startup_decision(cluster, self.session.device_id()) {
            StartupDecision::Remote { device_name } => {
                return StartupOutcome::Remote { device_name };
            }
            StartupDecision::Restore(transfer) => match self.handle_transfer(transfer) {
                Ok(()) => return StartupOutcome::Restored,
                Err(why) => warn!("startup: restoring the last session failed: {why}"),
            },
            StartupDecision::Fallback => {}
        }
        self.load_liked_songs().await
    }

    /// Mirrors the Activate and Load command paths, but keeps the load's
    /// result, which the command path only debug-logs.
    async fn load_liked_songs(&mut self) -> StartupOutcome {
        self.handle_activate();
        let uri = format!("spotify:user:{}:collection", self.session.username());
        let request = LoadRequest::from_context_uri(
            uri,
            LoadRequestOptions {
                start_playing: false,
                ..Default::default()
            },
        );
        let outcome = match self.handle_load(request, None, None).await {
            Ok(()) => StartupOutcome::LikedSongs,
            Err(why) => {
                warn!("startup: loading liked songs failed: {why}");
                StartupOutcome::Nothing
            }
        };
        if let Err(why) = self.notify().await {
            warn!("startup: state update failed: {why}");
        }
        outcome
    }
```

- [ ] **Step 5: Build and run all Rust tests**

Run: `cargo test --manifest-path rust/Cargo.toml -p librespot-connect && cargo test --manifest-path rust/Cargo.toml`
Expected: all pass, and the Task 2 `never used` warning is gone.

- [ ] **Step 6: Regenerate and verify the patch**

```sh
git -C .build/librespot-939dc5e diff --no-ext-diff --binary HEAD > rust/patches/librespot-queue-selection.patch
./scripts/prepare-librespot.sh
```
Expected: `Pinned librespot queue patch verified.`

- [ ] **Step 7: Commit**

```bash
git add rust/patches/librespot-queue-selection.patch
git commit -m "Run the startup decision once per engine behind a connect flag" -m "With startup_restore set, the first connect cluster restores the last session paused, loads Liked Songs paused, or leaves a playing device alone, and always reports exactly one outcome. Failures are logged and downgraded rather than returned, because an error here ends the Spirc task. The flag defaults off, so upstream behaviour is unchanged until the engine opts in."
```

---

### Task 4: `PlayerContent` decides what the expanded player shows

**Files:**
- Modify: `Packages/BopifyCore/Sources/BopifyPlayback/PlayerPresentation.swift` (append)
- Test: `Packages/BopifyCore/Tests/PlaybackTests/PlayerPresentationTests.swift`

**Interfaces:**
- Consumes: `PlaybackState.startup` and `StartupOutcome` (Task 1).
- Produces: `public enum PlayerContent: Equatable, Sendable { case player, loading, remote(deviceName: String), chooseContext }` with `public init(_ state: PlaybackState)`.

Precedence, from the spec: a current track always means `.player`. Without a track, an `.error` phase gives `.player`, so the error UI surfaces. `.loading` or `.buffering`, or a startup of `.pending`, `.restored` or `.likedSongs`, gives `.loading`. `.remote(name)` gives `.remote(name)`. `.nothing` gives `.chooseContext` when idle, and `.player` otherwise, which keeps the old `idle && no track` meaning.

- [ ] **Step 1: Write the failing tests**

Append inside `PlayerPresentationTests`:

```swift
    private func track() -> Track {
        Track(uri: SpotifyURI("spotify:track:t")!, title: "T", artists: [], albumTitle: nil, artwork: nil, durationMs: 1)
    }
    @Test func aTrackAlwaysShowsThePlayer() {
        var state = PlaybackState()
        state.currentTrack = track()
        #expect(PlayerContent(state) == .player)
        state.startup = .resolved(.nothing)
        #expect(PlayerContent(state) == .player)
    }
    @Test func startupLoadsInsteadOfOfferingThePasteView() {
        var state = PlaybackState()
        #expect(PlayerContent(state) == .loading)
        // Restored or Liked Songs may be reported before the engine's Loading event.
        state.startup = .resolved(.restored)
        #expect(PlayerContent(state) == .loading)
        state.startup = .resolved(.likedSongs)
        #expect(PlayerContent(state) == .loading)
    }
    @Test func onlyANothingOutcomeOffersThePasteView() {
        var state = PlaybackState()
        state.startup = .resolved(.nothing)
        #expect(PlayerContent(state) == .chooseContext)
        state.phase = .loading
        #expect(PlayerContent(state) == .loading)
    }
    @Test func aRemoteOutcomeNamesTheDevice() {
        var state = PlaybackState()
        state.startup = .resolved(.remote(deviceName: "iPhone"))
        #expect(PlayerContent(state) == .remote(deviceName: "iPhone"))
    }
    @Test func errorsSurfaceEvenWhileStartupIsPending() {
        var state = PlaybackState()
        state.phase = .error(.playbackSessionLost)
        #expect(PlayerContent(state) == .player)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `(cd Packages/BopifyCore && swift test --filter PlayerPresentationTests)`
Expected: compile error, `cannot find 'PlayerContent' in scope`.

- [ ] **Step 3: Implement**

Append to `PlayerPresentation.swift`:

```swift
/// What the expanded player shows. It lives here, not in the view, so its
/// precedence is tested: startup must never flash the paste view.
public enum PlayerContent: Equatable, Sendable {
    case player, loading, remote(deviceName: String), chooseContext

    public init(_ state: PlaybackState) {
        guard state.currentTrack == nil else { self = .player; return }
        switch state.phase {
        case .error: self = .player
        case .loading, .buffering: self = .loading
        default:
            switch state.startup {
            case .pending, .resolved(.restored), .resolved(.likedSongs): self = .loading
            case let .resolved(.remote(deviceName)): self = .remote(deviceName: deviceName)
            case .resolved(.nothing): self = state.phase == .idle ? .chooseContext : .player
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `(cd Packages/BopifyCore && swift test)`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/BopifyCore/Sources/BopifyPlayback/PlayerPresentation.swift Packages/BopifyCore/Tests/PlaybackTests/PlayerPresentationTests.swift
git commit -m "Choose player content from track, phase and startup outcome" -m "The paste-a-link view becomes the last resort, shown only when the engine reports it could load nothing. Startup shows loading even if the restore outcome arrives before the engine's Loading event, and an error still surfaces while startup is pending."
```

---

### Task 5: The expanded player renders loading, remote and last-resort content

**Files:**
- Modify: `Bopify/Bopify/Views/MiniPlayerView.swift:103-108` (the start of `PlayingView.body`) and add a private `StartupContent` view after `ContextURILoadView` (around line 223)
- Modify: `Bopify/Bopify/Views/PlayerPreviews.swift`
- Modify: `Bopify/Bopify/Localizable.xcstrings` (**check the Global Constraints first**)

**Interfaces:**
- Consumes: `PlayerContent` (Task 4); `StartupPhase` (Task 1).

- [ ] **Step 1: Check the string catalog is clean**

Run: `git status --short Bopify/Bopify/Localizable.xcstrings`
Expected: no output. If it prints ` M …`, stop and ask the user whether to commit their change first.

- [ ] **Step 2: Route `PlayingView` through `PlayerContent`**

In `PlayingView.body`, replace:

```swift
            if state.phase == .idle && state.currentTrack == nil {
                ContextURILoadView(load: player.load)
                    .frame(maxHeight: .infinity)
            } else {
```

with:

```swift
            let content = PlayerContent(state)
            if content != .player {
                StartupContent(content: content, load: player.load)
                    .frame(maxHeight: .infinity)
            } else {
```

After the closing brace of `private struct ContextURILoadView`, add:

```swift
private struct StartupContent: View {
    let content: PlayerContent
    let load: (PlayRequest) -> Void

    var body: some View {
        switch content {
        case .chooseContext:
            ContextURILoadView(load: load)
        case let .remote(deviceName):
            placeholder { Text("player.remote.title \(deviceName)") }
        // .player never reaches here; PlayingView renders it directly.
        case .loading, .player:
            placeholder { ProgressView { Text("player.loading") }.controlSize(.small) }
        }
    }

    private func placeholder(@ViewBuilder _ label: () -> some View) -> some View {
        VStack(spacing: 18) {
            ArtworkView(image: nil, diameter: 156)
            label()
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.7))
        }
    }
}
```

- [ ] **Step 3: Add the string**

In `Bopify/Bopify/Localizable.xcstrings`, insert this entry between the `"player.progress.value"` entry and the `"player.unknownTrack"` entry:

```json
    "player.remote.title %@" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Playing on %@"
          }
        }
      }
    },
```

- [ ] **Step 4: Add previews and keep the existing idle preview meaningful**

In `PlayerPreviews.swift`, add a `startup` stored property and init parameter to `PlayerPreview`:

```swift
    var startup: StartupPhase = .pending
```

Change the init signature to:

```swift
    init(phase: PlaybackPhase, longTitle: Bool = false, missingArtwork: Bool = false,
         mode: PlayerMode = .expanded, queueCount: Int = 1, width: CGFloat? = nil,
         startup: StartupPhase = .pending) {
```

and add `self.startup = startup` in its body. In the `state` computed property, add `state.startup = startup` directly after `state.phase = phase`.

Replace the `"Ready to play"` preview with these three:

```swift
#Preview("Startup · loading") {
    PlayerPreview(phase: .idle, missingArtwork: true)
}

#Preview("Startup · playing on another device") {
    PlayerPreview(phase: .idle, missingArtwork: true, startup: .resolved(.remote(deviceName: "iPhone")))
}

#Preview("Last resort · paste a link") {
    PlayerPreview(phase: .idle, missingArtwork: true, startup: .resolved(.nothing))
}
```

- [ ] **Step 5: Build the app**

Run: `xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' build 2>&1 | rg "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Verify visually**

Render the three new previews, plus `"Abstract sample · dark"` as a control, with the Xcode MCP `RenderPreview` tool (or Xcode's canvas). Save them as `docs/superpowers/verification/assets/startup-loading.png`, `startup-remote.png`, `startup-last-resort.png` and `startup-control-playing.png`. Check each one:
- loading shows an empty disc and a small spinner with "Loading…";
- remote reads "Playing on iPhone";
- last resort is the unchanged paste view;
- the control is unchanged from `docs/superpowers/verification/assets/expanded-final.png`.

If rendering is unavailable in this environment, say so in the Task 7 verification doc instead of claiming it.

- [ ] **Step 7: Run the package tests again and commit**

Run: `(cd Packages/BopifyCore && swift test)`
Expected: all pass.

```bash
git add Bopify/Bopify/Views/MiniPlayerView.swift Bopify/Bopify/Views/PlayerPreviews.swift Bopify/Bopify/Localizable.xcstrings docs/superpowers/verification/assets/startup-*.png
git commit -m "Show loading or the playing device instead of Nothing playing" -m "While the engine restores a session or loads Liked Songs, the player shows a quiet loading disc, and when another device is playing it names that device. The paste view remains only for the case where nothing could be loaded."
```

---

### Task 6: Enable startup restore and remove `activate()` end to end

**Files:**
- Modify: `rust/crates/bopify-core/src/engine.rs:100-105` (the `ConnectConfig`) and `:135-137` (delete `activate`)
- Modify: `rust/crates/bopify-core/src/ffi.rs:256-267` (delete `bopify_activate` and fix the preceding comment) and `:459` (delete the test line)
- Modify: `Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift:19`
- Modify: `Packages/BopifyCore/Sources/BopifyPlayback/LibrespotEngine.swift:120`
- Modify: `Packages/BopifyCore/Sources/BopifyPlayback/StubPlaybackEngine.swift:25`
- Modify: `Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift:75-77`
- Modify: `Bopify/Bopify/AppEnvironment.swift:193-195`
- Modify: `docs/superpowers/specs/2026-09-21-bopify-foundation-design.md` (lines 36, 147, 189, 203), `README.md:36-37`

**Interfaces:**
- Consumes: `ConnectConfig.startup_restore` (Task 3). Swift decoding (Task 1) and rendering (Tasks 4–5) must already be in place, so the first emitted event is understood.
- Produces: an ABI without `bopify_activate`, and a `PlaybackEngine` protocol without `activate()`.

- [ ] **Step 1: Turn the flag on**

In `engine.rs`, change the `ConnectConfig` passed to `Spirc::new` to:

```rust
                ConnectConfig {
                    name: device_name.to_string(),
                    emit_set_queue_events: true,
                    // Decides from the first connect cluster what to load, so the
                    // device is never active without content (see the startup-restore spec).
                    startup_restore: true,
                    ..Default::default()
                },
```

- [ ] **Step 2: Remove `activate` from Rust and the ABI**

In `engine.rs`, delete:

```rust
    pub fn activate(&self) -> Result<(), BopifyError> {
        self.spirc.activate().map_err(command_failed)
    }
```

In `ffi.rs`, change the comment `// The five no-argument commands are spelled out rather than generated by a` to `// The four no-argument commands are spelled out rather than generated by a`, and delete:

```rust
/// # Safety
/// `handle` must be null or a live handle from `bopify_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bopify_activate(handle: *mut BopifyEngine) -> i32 {
    log::debug!("ffi: bopify_activate");
    // SAFETY: forwards this function's own contract to `with_engine`.
    unsafe { with_engine(handle, Engine::activate) }
}

```

In the `every_command_on_a_destroyed_handle_reports_session_lost` test, delete the line `assert_eq!(bopify_activate(ptr), lost);`.

- [ ] **Step 3: Remove `activate` from Swift**

- `PlaybackEngine.swift`: delete the line `    func activate() async throws`.
- `LibrespotEngine.swift`: delete the line `    @concurrent public func activate() async throws { try perform("activate") { bopify_activate(handle) } }`. Keep the comment block above it; it now documents `resume` and the commands that follow.
- `StubPlaybackEngine.swift`: delete `    public func activate() async throws { record("activate") }`.
- `PlayerModel.swift`: delete

```swift
    public func activate() {
        enqueue("activate") { [engine] in try await engine.activate() }
    }

```

- `AppEnvironment.swift`: in `connect()`, replace

```swift
            model.start()
            model.activate()
```

with

```swift
            model.start()
            // No activate(): the engine restores the last session or loads Liked Songs itself,
            // and stays inactive when another device is playing so it is not interrupted.
```

- [ ] **Step 4: Confirm nothing still references `activate`**

Run: `rg -n "bopify_activate|\bactivate\(\)|Engine::activate" rust/crates Packages Bopify --glob '!*.xcstrings'`
Expected: no output. (`hidesOnDeactivate` in `StatusPanel.swift` doesn't match this pattern.)

- [ ] **Step 5: Rebuild and run everything**

```sh
./scripts/build-rust.sh
cargo test --manifest-path rust/Cargo.toml
cargo test --manifest-path rust/Cargo.toml -p librespot-connect
(cd Packages/BopifyCore && swift test)
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' build 2>&1 | rg "error:|BUILD (SUCCEEDED|FAILED)"
```
Expected: `build-rust.sh` ends with `xcframework successfully written out`; the existing `WARN: Can't find BopifyError` header warnings are pre-existing and fine. All tests pass. `** BUILD SUCCEEDED **`. Also run `rg -c bopify_activate artifacts/include` and expect no matches.

- [ ] **Step 6: Update the docs**

In `docs/superpowers/specs/2026-09-21-bopify-foundation-design.md`:
- Line 36: replace the sentence with ``Spirc::activate()` makes the app the active Connect device without requiring a second Spotify client to be running. Since 2026-09-26 Bopify no longer calls it directly: the patched connect handler activates only when it has content to load (see `2026-09-26-startup-restore-design.md`).`
- Line 147: delete `    func activate() async throws              // become the active Connect device`.
- Line 189: delete `int32_t bopify_activate(BopifyEngine *);            /* Spirc::activate() */`.
- Line 203: replace ``bopify_activate` backs `PlaybackEngine.activate()`. `` at the start of the paragraph with `` `bopify_activate` was removed on 2026-09-26 with the startup-restore change. ``.

In `README.md`, replace `applies our exact queue-occurrence` / `selection patch in `.build/`` with `applies our exact queue-occurrence` / `selection and startup-restore patch in `.build/``, keeping the existing line wrapping.

- [ ] **Step 7: Commit**

```bash
git add rust/crates/bopify-core/src/engine.rs rust/crates/bopify-core/src/ffi.rs Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift Packages/BopifyCore/Sources/BopifyPlayback/LibrespotEngine.swift Packages/BopifyCore/Sources/BopifyPlayback/StubPlaybackEngine.swift Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift Bopify/Bopify/AppEnvironment.swift docs/superpowers/specs/2026-09-21-bopify-foundation-design.md README.md
git commit -m "Let the engine choose startup content and drop activate()" -m "Activating right after connect made Bopify the active device with nothing loaded, which is the Nothing playing screen, and it likely replaced the account's resume point. The engine now restores, loads Liked Songs, or stays out of the way of a playing device. With no caller left, activate() is removed from the protocol, the ABI and the Rust engine."
```

---

### Task 7: Live verification against a real account

**Files:**
- Create: `docs/superpowers/verification/2026-09-26-startup-restore.md`

This task needs the user: their phone, their Spotify account, and permission to launch the app. Ask before each scenario that involves their devices. Run **only one Bopify instance at a time**, because a second connection ends the first instance's session. A new build may trigger a keychain prompt that the user must allow.

- [ ] **Step 1: Build and prepare log capture**

```sh
./scripts/build-rust.sh
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-startup-restore build 2>&1 | rg "BUILD (SUCCEEDED|FAILED)"
/usr/bin/log stream --style compact --level debug --predicate 'subsystem == "my.snsoft.bopify"' > /private/tmp/bopify-startup-restore.log &
```

Launch with `/private/tmp/bopify-startup-restore/Build/Products/Debug/Bopify.app/Contents/MacOS/Bopify`. Quit through the status item's menu (Quit), not `kill`, except in scenario 2.

- [ ] **Step 2: Run the scenarios and record each result**

For each scenario, record the `startup resolved outcome=` line, the phase transitions, and what the user sees.

1. **Restore.** The user plays something on another device, pauses, then closes Spotify everywhere. Launch Bopify. Expect `outcome=restored`, then `loading → paused`, with the user confirming the right track, position and a populated Up Next.
2. **Killed mid-song.** Press play in Bopify, wait about 20 s, `kill` the process, and relaunch. Record the connect `outcome=` line explicitly. Expect `outcome=restored` and paused, not playing. The position may be near the track start: that is the last reported position, and it's a **pass**. A position beyond where playback was is a failure. So is `outcome=remote` naming "Bopify": the killed instance is still listed as active with a track (see the spec's ghost-instance risk). Record that as a failure, and don't fix it in this plan.
3. **Liked Songs, forced.** A real account rarely lacks a usable last session, and Task 2's unit tests cover only the pure decision, not `load_liked_songs`. That handler's order (activate, load, then one `notify` inside the connection-id handler) also differs from the spike, which ran activate and load as separate commands. So force the branch with a throwaway edit, using the spike's method:
   1. In `.build/librespot-939dc5e/connect/src/spirc.rs`, make `resolve_startup`'s first line `return self.load_liked_songs().await;`.
   2. Build without the prepare check: `env MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --release --manifest-path rust/Cargo.toml --target aarch64-apple-darwin`. Then `rm -rf artifacts/BopifyCoreFFI.xcframework && xcodebuild -create-xcframework -library rust/target/aarch64-apple-darwin/release/libbopify_core.a -headers artifacts/include -output artifacts/BopifyCoreFFI.xcframework`. Then rebuild the app with the Step 1 `xcodebuild` command.
   3. Launch. Expect `outcome=likedSongs`, then `loading → paused`, with the user confirming a Liked Songs track.
   4. Remove the edit by hand; never use `git checkout` in that checkout. Run `./scripts/prepare-librespot.sh` (it must print verified), then `./scripts/build-rust.sh`, then the Step 1 `xcodebuild` again.
4. **Another device playing.** The user plays on "This iPhone". Launch Bopify. Expect `outcome=remote`, the panel showing "Playing on <name>", and the user confirming the phone never paused.
5. **Normal quit.** Quit Bopify while paused mid-track, then relaunch. Expect `outcome=restored` at the same position.
6. **No flash.** In scenario 1 or 5, the user watches the panel during launch: after sign-in they should see the loading disc, then the track, and never the "Nothing playing" paste view.

- [ ] **Step 3: Write the verification doc**

Create `docs/superpowers/verification/2026-09-26-startup-restore.md` with: the date, the build command, one row per scenario (setup, expected, observed log lines, user confirmation, pass/fail/not reproduced), the preview images from Task 5, and any deviation from the spec with its cause. Stop the log stream (`kill %1`, or `pkill -f "log stream --style compact --level debug"`).

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/verification/2026-09-26-startup-restore.md
git commit -m "Record live verification of paused startup restore" -m "Evidence from real launches against the user's account for each startup outcome, including the deliberate resume-at-last-reported-position behaviour after a kill."
```

---

## Out of scope (phase 2, separate plan)

Mirroring (`RemotePlayback` events while inactive, metadata, live updates, the `transferHere()` / `bopify_transfer` "play here"), replacing the frozen mid-session inactive state, and surfacing `Stopped`/`Unavailable` when a whole context can't play. Phase 2 starts by verifying that `Spirc::transfer(None)` moves an actively playing phone session onto Bopify.
