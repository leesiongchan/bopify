# Bopify startup: always have something loaded

Date: 2026-09-26
Status: design approved section by section by the user on 2026-09-26; this written spec awaits their review. Implementation is not approved or started.

## Intent and scope

Bopify must never open on the "Nothing playing" screen. Today `AppEnvironment.connect()` calls `activate()` right after the engine connects. That makes Bopify the active Connect device with no content, so `PlayingView` falls through to `ContextURILoadView` (`phase == .idle && currentTrack == nil`).

Decisions the user made:

| Question | Decision |
| --- | --- |
| What does "play something" mean at launch? | The track is **loaded and paused**, ready to play with one click. There is no autoplay and no sudden sound. |
| Where does the track come from? | **Spotify's last session**, from any device, at its saved position. |
| What if another device is actively playing? | **Mirror it and don't touch it.** Show that device's track. Pressing Play moves playback to Bopify. |
| What if there is nothing to restore? | **Liked Songs**, paused on its first track. The paste-a-link screen remains only as the last resort. |

Scope ships in two phases. Phase 1 covers restore, the Liked Songs fallback, and the startup presentation. Phase 2 covers mirroring. Phase 2 also replaces today's mid-session "Playing on another device" state, which freezes on a stale track. Both phases share the startup event and the removal of the unconditional `activate()`.

Out of scope: autoplay at launch, choosing a fallback playlist, and the observed behaviour where a second Bopify instance's connection ends the first one's session.

## Approaches considered

The spike (appendix) decided between three restore mechanisms:

- **A. Relax librespot's own restore-on-connect (chosen).** `handle_connection_id_update` already parses `cluster.transfer_data` and calls `handle_transfer`. A `same_session` gate stops it, and that gate is always false for a freshly launched process. Run 1 showed that a forced, paused takeover through this path restores the context, track, position and queue. It needs no server round-trip.
- **B. Server transfer to ourselves** (`Spirc::transfer(Some(TransferRequest))`). Rejected for restore. The endpoint is documented only for "from the currently active device", and A made it unnecessary. It is still needed for phase 2's "play here".
- **C. Swift loads from the reported `player_state`.** Rejected. It loses queued tracks and shuffle/repeat state, and sessions started through the Web API have no context URI.

Where the Liked Songs fallback runs was a second choice:

- **Rust, inside the patched connect handler (chosen).** `Spirc::load` failures are only `debug!`-logged ("could not dispatch command"), so a load issued from Swift fails silently. Swift could not tell an empty Liked Songs from a slow one. Inside the handler, `handle_load` returns `Result` directly. This also leaves `bopify_load`, `SpotifyURI` and username plumbing untouched.
- **Swift.** Rejected. It needs a `start_playing` FFI parameter, a four-part `SpotifyURI`, and a new reply channel on `Spirc::load` to detect failure.

## Startup decision

`connect()` no longer calls `activate()`. When librespot receives the first connect cluster for this engine, the patched handler makes exactly one decision and emits exactly one startup event:

1. **Remote.** Another device is active (`active_device_id` is non-empty and differs from Bopify's own device id), and `player_state` has a track. Bopify stays inactive and reports the device name. This includes an active device that is paused. An active device without a track (for example a crashed Bopify with an empty session) does not count and falls through.
2. **Restored.** No device is active, and `transfer_data` parses and is usable: the context URI is non-empty and not `"-"`, or the current track URI is non-empty. Bopify takes the session over **paused**. The no-active-device condition matters: while a device is active, `transfer_data` is a thin stub that still carries a context (run 4), so restoring from it would pull another device's session.
3. **Liked Songs.** Otherwise, Bopify activates and loads `spotify:user:<session username>:collection` with `start_playing: false`. A failed restore also lands here.
4. **Nothing.** The Liked Songs load returned an error. Swift shows the paste-a-link view. The device remains active, so a pasted URI still loads.

Usability is checked on content, not on byte length. Run 0 produced a 66-byte `transfer_data` with context `""` and no track.

## librespot patch

The changes extend `rust/patches/librespot-queue-selection.patch`, because `scripts/prepare-librespot.sh` handles a single patch file. The README line describing the patch is updated to match.

- **Flag.** `ConnectConfig.startup_restore: bool`, default `false`, so upstream behaviour is unchanged. `Engine::new` sets it to `true`.
- **Once per engine.** `handle_connection_id_update` runs again whenever the dealer reconnects and delivers a new connection id. A `SpircTask` field records that the startup decision has run. Later connection-id updates follow the upstream path. Without this, a reconnect mid-playback could restore over the current session or mirror Bopify itself.
- **Pure decision function.** `startup_decision(cluster: &Cluster, own_device_id: &str) -> StartupDecision`, where the result is one of `Remote { device_name }`, `Restore(TransferState)` or `Fallback`. It holds no session and makes no I/O, so unit tests can use hand-built protobufs.
- **Forced pause.** The `Restore` branch sets `playback.is_paused = Some(true)` before `handle_transfer`. This must stay a pre-transfer flag, not a pause issued after loading, because it does two jobs:
  1. `handle_transfer` ends with `load_track(is_playing, …)`, so without the flag a session whose device died mid-song autoplays.
  2. When a session is not paused, `handle_transfer` extrapolates the position by `now - timestamp`. Run 3's stale state was 203 ms at a timestamp minutes old, so it would have resumed minutes into the track.
- **Errors are never fatal.** The run loop `break`s on an `Err` from `handle_connection_id_update`, which ends the Spirc task and reaches Swift as SessionLost. Both `handle_transfer` and the Liked Songs `handle_load` are `match`ed:
  - a failed restore logs a warning and falls through to Liked Songs;
  - a failed Liked Songs load logs a warning and reports `Nothing`.
- **Liked Songs branch.** It repeats the command path's work: `handle_activate()` and `notify()` as for `SpircCommand::Activate`, then `handle_load(LoadRequest::from_context_uri(…, LoadRequestOptions { start_playing: false, .. }), None, None)`, followed by the same state notification the `Load` command path performs.
- **Event.** A new `PlayerEvent::StartupResolved { outcome }` is emitted through a new `Player::emit_startup_resolved_event`. It uses the same `PlayerCommand` route the patch already uses for `SetQueue`. The outcome is `Restored`, `LikedSongs`, `Remote { device_name }` or `Nothing`. Its order relative to the branch's `Loading` event is not relied on; the Swift content rules below give the same result in either order.

## Wire contract and FFI

- `WireEvent::StartupResolved`, serialised as `{"type":"startupResolved","outcome":"restored"|"likedSongs"|"remote"|"nothing","deviceName":<string, remote only>}`. `translate` lists it by name. bopify-core logs `startup resolved outcome=…` at info in its own `playback` category. The `librespot` category is capped at Warn and redacted, so info lines there would be invisible.
- `BopifyDomain.PlaybackEvent` gains `.startupResolved(StartupOutcome)` in the same commit, as `event.rs` requires.
- Phase 1 changes no FFI signatures. `activate()` becomes unused, so it is removed as an orphan of this change: `bopify_activate`, `Engine::activate`, `PlaybackEngine.activate()`, `LibrespotEngine.activate()`, the stub's `activate()`, `PlayerModel.activate()`, and their tests. The header is regenerated. The foundation spec's §2.1 note, protocol block and ABI block (`2026-09-21-bopify-foundation-design.md` lines 36, 147, 189 and 203) are updated.
- Phase 2 adds `bopify_transfer(BopifyEngine *)`, which calls `Spirc::transfer(None)` and backs `PlaybackEngine.transferHere()`.

## Swift

- **State.** Two new types: `StartupOutcome`, with cases `.restored`, `.likedSongs`, `.remote(deviceName: String)` and `.nothing`, and `StartupPhase`, with cases `.pending` and `.resolved(StartupOutcome)`. `PlaybackState.startup` starts as `.pending`. `PlayerModel.apply` folds `.startupResolved` into it and logs the outcome at info. No later event resets it.
- **Content selection.** The inline `if` in `PlayingView` becomes a small enum next to `PlayerPresentation`, so its precedence is unit-tested. With a current track, the content is always the player. Without one, the first matching rule wins:
  1. `phase` is `.error`: the existing player/error UI, so a SessionLost during startup still surfaces;
  2. `startup` is `.pending`, `.resolved(.restored)` or `.resolved(.likedSongs)`, or `phase` is `.loading` or `.buffering`: a new **loading** presentation with the empty artwork disc and a spinner, styled like `SignedOutView`'s authenticating state. A restore or Liked Songs outcome means a track load is already in flight. If that load fails, an error event takes rule 1, so there is no need to wait for `Loading` and no flash of the paste view in between;
  3. `startup` is `.resolved(.remote(name))`: "Playing on <name>" (phase 1 only);
  4. otherwise, that is `.resolved(.nothing)`: the existing `ContextURILoadView`, now the last resort.
- **Compact mode.** `AppEnvironment.playerMode` honours the saved mode when a track exists *or* startup is `.pending`. Without this, compact users would see the window resize to expanded and back on every launch. `CompactPlayerView` shows the existing `player.loading` string in place of the title when there is no track. Remote and last-resort states still force expanded.
- **Strings.** Adding the remote title with the device name changes `Localizable.xcstrings`, which currently has the user's own uncommitted edits. Those edits must be preserved.

## Phase 2: mirror

1. **Verify first.** Check that `Spirc::transfer(None)` moves an actively playing phone session onto Bopify. This has not been tried. If it fails, stop and revisit the design before building the mirror UI.
2. **Remote events.** While Bopify is inactive and the flag is on, `handle_cluster_update` emits `PlayerEvent::RemotePlayback(Option<…>)` carrying the device name, track URI, context URI, playing flag, position, server timestamp and duration. It emits `None` when no other active device has a track. Mirror state comes from `player_state`, not `transfer_data`: while a device is active, `transfer_data` is a 1 KB stub with an empty track (run 4).
3. **Metadata.** bopify-core fetches track metadata the way `queue.rs` does and emits `WireEvent::RemotePlayback` with a `WireTrack`.
4. **Swift state.** `PlaybackState.remote: RemotePlayback?`. To avoid clock skew, Rust adjusts the position to the moment of receipt using only server clocks: `position_as_of_timestamp + (cluster.server_timestamp_ms - player_state.timestamp)` while playing. Swift then interpolates from its own receipt time, as `displayPositionMs` does for local playback. No local-versus-server clock comparison is needed.
5. **UI.** The mirror uses the player surface with transport disabled except Play, which calls `PlayerModel.transferHere()`. The status line reads "Playing on <device>". It also replaces the frozen mid-session inactive state. Compact mode shows the remote track with Play.
6. **Hand-over.** When Bopify becomes active, `remote` clears.

## Testing

Tests come first, one unit at a time.

- **librespot patch** (`cd rust && cargo test -p librespot-connect`, next to the patch's existing tests). `startup_decision` has one test per observed case:
  - no active device and a usable session → Restore;
  - the empty 66-byte session → Fallback;
  - another device active with a track → Remote, carrying its name;
  - an active device without a track (the run 0 ghost) → Fallback, never Restore;
  - a device active with a track, with a context-bearing thin `transfer_data` (run 4) → Remote, never Restore;
  - Bopify's own id as the active device → never Remote;
  - stale "playing" transfer data → the returned `TransferState` has `is_paused == Some(true)`.
- **bopify-core** (`cargo test`): `translate` produces the exact `startupResolved` JSON for each outcome.
- **Swift** (`swift test`):
  - `PlaybackEventTests` decodes each outcome and rejects a malformed one;
  - `PlayerModelTests` checks the fold: `.pending` until the event, then stable;
  - content-selection tests cover every precedence rule, including an error while `.pending` and a `.restored` outcome that arrives before `Loading`, plus the compact-while-pending rule.
- **Build:** `./scripts/build-rust.sh`, then `xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' build`.

## Live verification

These scenarios repeat the spike on the real build. Logs are captured with `/usr/bin/log stream --level debug --predicate 'subsystem == "my.snsoft.bopify"'`; zsh's builtin `log` shadows the binary.

1. No active device and a real last session: restored paused, with the right track, position and queue.
2. Kill Bopify mid-song, then relaunch: paused at the right position, not minutes ahead.
3. No usable session: Liked Songs, paused.
4. Phone actively playing: the phone keeps playing, and Bopify shows it. Phase 2: a skip on the phone updates the mirror, and Play moves playback to Bopify.
5. Normal quit and relaunch: Bopify's own session resumes.
6. No frame of "Nothing playing" between connect and the track, and compact stays compact.

UI changes get before/after screenshots and previews for the loading, remote and last-resort states. This shell lacks Screen Recording permission, so either the user grants it to the terminal or takes the screenshots.

## Risks and unknowns

- **`Spirc::transfer` for "play here" is untested.** Phase 2 starts by verifying it.
- **How long Spotify keeps a session with no active device is unknown.** The spike restored sessions minutes old, not a "next morning" gap. When the session is gone, the decision falls through to Liked Songs.
- **An empty Liked Songs has not been observed live.** It is covered by the `handle_load` error path and a unit test.
- **The patch grows,** and every librespot bump must carry it. The flag keeps upstream behaviour intact when it is off.
- **Inferred, not observed:** today's content-less `activate()` probably replaces the account's resume point on every launch, because run 0 reported the active Bopify's empty session as `transfer_data`. The new startup never activates without content, except in the `Nothing` branch.

## Appendix: spike findings (2026-09-26)

Setup: pinned librespot `939dc5e` plus the queue patch; temporary `warn!` lines in `handle_connection_id_update` and `handle_cluster_update`; the `librespot` log category made public for the run; environment flags to skip `activate()`, force a paused takeover, or load the collection. All temporary code was reverted, and `prepare-librespot.sh` verified the checkout against the patch afterwards.

| Run | Setup | Observed |
| --- | --- | --- |
| 0 | Accidental: a second Bopify (started from Xcode, activated with no content) was the active device | `active=<that Bopify>`, `ps.ctx=""`, no track, `transfer_data` 66 bytes (context `""`, no track). When the spike instance connected, the other instance's session ended with "unexpected shutdown". |
| 1 | No active device; last session was a playlist paused on Spotify desktop; forced paused takeover | `active=""`, `same_session=false`, `ps.ctx=spotify:playlist:37i9dQZF1E8NDRt5R5oIbG`, track `3WvM2dIR9iIxMGNMP7WsNw`, paused at 1545 ms, `transfer_data` 19,947 bytes. `idle → loading → paused`. The user confirmed the track and a populated queue. |
| 2 | No active device; `activate` and `load("spotify:user:121047766:collection", start_playing: false)` | The cluster showed run 1's Bopify session as the last session (it outlived SIGTERM). `idle → loading → paused`. The user confirmed a Liked Songs track. |
| 3 | The phone pressed play while run 2's Bopify was still active, so it acted as a remote; that Bopify was then killed | `active=""` with `ps.playing=true`, `paused=false`, 203 ms at a timestamp minutes old: a stale "playing" state from a vanished device. |
| 3b | Same inactive instance; the phone switched to "This iPhone" and skipped a track | Cluster updates arrived while Bopify was inactive: `active=<iPhone id>`, `name="iPhone"`, the track changed from `22Tmr1R5TVgtLOSYrgMWdu` to `0phqiLIH4JYk4jPissBOQE`, each with a position and timestamp. |
| 4 | Relaunch while the phone was actively playing, without `activate()` | `active=<iPhone id>`, `name="iPhone"`, `player_state` with context, track `0phqiLIH4JYk4jPissBOQE`, playing, position and duration. `transfer_data` was 1,156 bytes with an empty track. |

Other findings: librespot documents `spotify:user:<user_id>:collection` as the Liked Songs context (`core/src/spclient.rs`, `get_context` doc comment). Commands wait on `connect_established`, which is set inside `handle_connection_id_update` before the cluster checks, so the startup decision always runs before any queued command.
