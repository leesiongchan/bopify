# Bopify startup: always have something loaded

Date: 2026-09-26
Status: approved by the user on 2026-09-26 for implementation planning, including resuming at the last reported position rather than extrapolating. Phase 1 was implemented and live-verified on 2026-09-26 (see `docs/superpowers/verification/2026-09-26-startup-restore.md`); phase 2 (mirroring and play here) was revised for the Monolith player and approved on 2026-09-27, and is not yet implemented.

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
  1. **It prevents autoplay.** `handle_transfer` ends with `load_track(is_playing, …)`, so without the flag a session whose device died mid-song would start playing.
  2. **It resumes at the last reported position without extrapolating.** For a session that was not paused, `handle_transfer` otherwise adds `now - timestamp` to the position. That is only right if the device really kept playing until now. After a crash or kill, the timestamp is stale; after a next-morning launch, extrapolation would run past the end of the track.

  The trade-off is deliberate and deterministic: a session that was killed while playing resumes at its last state change, often near the start of the track. In run 3 that meant 203 ms, where extrapolation would have given about 25 s. A graceful quit is unaffected, because shutdown pauses, disconnects and reports the current position (run 2).
- **Errors are never fatal.** The run loop `break`s on an `Err` from `handle_connection_id_update`, which ends the Spirc task and reaches Swift as SessionLost. Both `handle_transfer` and the Liked Songs `handle_load` are `match`ed:
  - a failed restore logs a warning and falls through to Liked Songs;
  - a failed Liked Songs load logs a warning and reports `Nothing`.
- **Liked Songs branch.** It repeats the command path's work: `handle_activate()` and `notify()` as for `SpircCommand::Activate`, then `handle_load(LoadRequest::from_context_uri(…, LoadRequestOptions { start_playing: false, .. }), None, None)`, followed by the same state notification the `Load` command path performs.
- **Event.** A new `PlayerEvent::StartupResolved { outcome }` is emitted through a new `Player::emit_startup_resolved_event`. It uses the same `PlayerCommand` route the patch already uses for `SetQueue`. The outcome is `Restored`, `LikedSongs`, `Remote { device_name }` or `Nothing`. Its order relative to the branch's `Loading` event is not relied on; the Swift content rules below give the same result in either order.

## Wire contract and FFI

- `WireEvent::StartupResolved`, serialised as `{"type":"startupResolved","outcome":"restored"|"likedSongs"|"remote"|"nothing","deviceName":<string, remote only>}`. `translate` lists it by name. bopify-core logs `startup resolved outcome=…` at info in its own `playback` category. The `librespot` category is capped at Warn and redacted, so info lines there would be invisible.
- `BopifyDomain.PlaybackEvent` gains `.startupResolved(StartupOutcome)` in the same commit, as `event.rs` requires.
- Phase 1 changes no FFI signatures. `activate()` becomes unused, so it is removed as an orphan of this change: `bopify_activate`, `Engine::activate`, `PlaybackEngine.activate()`, `LibrespotEngine.activate()`, the stub's `activate()`, `PlayerModel.activate()`, and their tests. The header is regenerated. The foundation spec's §2.1 note, protocol block and ABI block (`2026-09-21-bopify-foundation-design.md` lines 36, 147, 189 and 203) are updated.
- Phase 2 adds `bopify_play_here(BopifyEngine *)`, which calls `Spirc::play_here()` and backs `PlaybackEngine.playHere()` (see Phase 2).

## Swift

- **State.** Two new types: `StartupOutcome`, with cases `.restored`, `.likedSongs`, `.remote(deviceName: String)` and `.nothing`, and `StartupPhase`, with cases `.pending` and `.resolved(StartupOutcome)`. `PlaybackState.startup` starts as `.pending`. `PlayerModel.apply` folds `.startupResolved` into it and logs the outcome at info. No later event resets it.
- **Content selection.** The inline `if` in `PlayingView` becomes a small enum next to `PlayerPresentation`, so its precedence is unit-tested. With a current track, the content is always the player. Without one, the first matching rule wins:
  1. `phase` is `.error`: the existing player/error UI, so a SessionLost during startup still surfaces;
  2. `startup` is `.pending`, `.resolved(.restored)` or `.resolved(.likedSongs)`, or `phase` is `.loading` or `.buffering`: a new **loading** presentation with the empty artwork disc and a spinner, styled like `SignedOutView`'s authenticating state. A restore or Liked Songs outcome means a track load is already in flight, so there is no need to wait for `Loading` and no flash of the paste view in between. A single unavailable track is skipped by Spirc, and the next one reaches Swift. See Risks for a context in which nothing can play;
  3. `startup` is `.resolved(.remote(name))`: "Playing on <name>" (phase 1 only);
  4. otherwise, that is `.resolved(.nothing)`: the existing `ContextURILoadView`, now the last resort.
- **Phase 1 remote state has no in-app action.** Bopify is inactive, so `load` does nothing, and "play here" arrives only in phase 2. In phase 1, the user can still hand playback to Bopify from the phone's Connect device picker. If phase 2's transfer check fails, this state stays as it is until the design is revisited.
- **Compact mode is unchanged.** `playerMode` stays expanded until a track exists. Signing in already forces the expanded layout at launch (`StatusItemController.configure` clamps the first frame to it), so honouring compact while startup is pending would only move the single launch resize earlier, not remove it. The user dropped that rule on 2026-09-26.
- **Strings.** Adding the remote title with the device name changes `Localizable.xcstrings`, which currently has the user's own uncommitted edits. Those edits must be preserved.

## Phase 2: mirror

1. **Verify first.** Check that `Spirc::transfer(None)` moves an actively playing phone session onto Bopify. If it fails, stop and revisit the design before building the mirror UI. Verified on 2026-09-26 (appendix run 5): playback moved, but the HTTP call returned 410 and took 3.2 s. So "play here" judges success by the incoming transfer and `Playing` event, not the reply, and sends the request without blocking the Spirc loop.
Revised on 2026-09-27 for the Monolith player (record and sleeve, no compact mode) and the run 5 findings; approved by the user.

2. **One "play here" command.** `SpircCommand::PlayHere` (`Spirc::play_here()`, behind `startup_restore`) decides from a fresh cluster, the reply to the same state PUT the startup decision reads (`notify_new_device_appeared`), using `startup_decision`. Cluster updates are not known to carry the full last session:
   - another device active with a track: send the transfer request (`spclient().transfer(own, own, None)`) on a spawned task, so the Spirc loop keeps answering the dealer. The reply, including a 410, is only logged. Success is the server's incoming transfer and the `Playing` event that follows. That transfer plays even when the other device was paused;
   - no active device and a usable last session: restore it exactly as at startup (forced paused, no extrapolation), then resume playback;
   - otherwise: load Liked Songs with `start_playing: true`.
   This covers both the mirror's Play and the stale state after a takeover whose device later stopped (the user chose "resume that session here" on 2026-09-27).
3. **Remote events.** `PlayerEvent::RemotePlayback(Option<RemoteState>)`, where `RemoteState` carries the device name, track URI, playing flag, position and duration. It is emitted from the startup cluster when the outcome is `Remote` (so the mirror appears at launch), and from every cluster update while Bopify is inactive, including the one that deactivates it. It is emitted only when the value changes, and is `None` when no other device is active with a track. The extraction is a pure function next to `startup_decision`, unit-tested the same way. Mirror state comes from `player_state`, not `transfer_data`: while a device is active, `transfer_data` is a 1 KB stub with an empty track (run 4). To avoid clock skew, the position uses server clocks only: `position_as_of_timestamp + (cluster.server_timestamp_ms - player_state.timestamp)` while playing, and `position_as_of_timestamp` while paused.
4. **bopify-core.** `WireEvent::RemotePlayback` carries the device name, a `WireTrack` looked up with the same `AudioItem::get_file` path `queue.rs` uses, the playing flag and the position. Lookups are latest-wins with a cache, so a slow lookup never overwrites a newer track. `None` serialises as `{"type":"remotePlayback","remote":null}`. Device names never reach the public log category.
5. **Swift state.** `PlaybackState.remote: RemotePlayback?` (device name, `Track`, playing flag, position at receipt). Swift interpolates from its own receipt time, as `displayPositionMs` does for local playback. `PlayerModel.playHere()` backs Play whenever Bopify is inactive. `remote` clears when Bopify becomes active, and nothing is set optimistically: until the engine's events arrive, the existing loading/buffering status shows.
6. **Monolith UI.**
   - `AppEnvironment.isListening` becomes "signed in and (a current track or a remote track)", so the record and sleeve show a remote device instead of the placeholder disc. The startup `remote` placeholder stays only as the fallback for the moment before the first `RemotePlayback`.
   - **Mirror.** While Bopify is inactive, a remote track takes precedence over Bopify's stale track. The record shows its artwork, and the sleeve shows its title and artists. The progress ring advances but is not seekable, and the status line reads "Playing on <device>" or "Paused on <device>". Only Play is enabled, and it calls `playHere()`. Previous, next, seek, shuffle, repeat, volume, mute, queue and favourite stay disabled, because the remote queue is not modelled. There is no orange attention rim, since another device playing is not an error. The record's reflection does not rotate, because nothing plays on this Mac.
   - **Stale state.** When Bopify is inactive and no other device is active, the record keeps the last track it showed: the stopped device's last mirrored track at its last reported position, or Bopify's own last track when nothing was mirrored. Play resumes the account's last session, which is that mirrored track's session (the user chose this on 2026-09-27 over keeping Bopify's own track; at launch Bopify has none). The status reads "Not playing" instead of "Playing on another device". Play is enabled and calls `playHere()`, and there is no rim.
   - New strings: "Paused on %@" and "Not playing". "Playing on %@" already exists.
7. **Tests.**
   - Rust: remote-state extraction (position maths, the `None` cases, own device, change-only emission), `translate`, and the wire JSON.
   - Swift: decoding; the fold (remote set, cleared, and cleared on becoming active); the precedence of remote track and status; and `togglePlayPause` routing to `playHere()` when inactive.
   - Previews: mirror, paused remote, and stale.
8. **Live.**
   1. The phone plays, then skips a track; the mirror follows.
   2. Play here moves playback, and the phone stops.
   3. A takeover mid-session becomes the mirror.
   4. The phone pauses and closes, leaving the stale state; Play resumes that session here.
   5. Check whether the non-blocking transfer avoids run 5's dealer drop.

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
  - content-selection tests cover every precedence rule, including an error while `.pending` and a `.restored` outcome that arrives before `Loading`.
- **Build:** `./scripts/build-rust.sh`, then `xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' build`.

## Live verification

These scenarios repeat the spike on the real build. Logs are captured with `/usr/bin/log stream --level debug --predicate 'subsystem == "my.snsoft.bopify"'`; zsh's builtin `log` shadows the binary.

1. No active device and a real last session: restored paused, with the right track, position and queue.
2. Kill Bopify mid-song, then relaunch: paused, not playing, at the last position the killed session reported. That is often near the start of the track, and that counts as a **pass** (see Forced pause). A position beyond where playback actually was is a failure.
3. No usable session: Liked Songs, paused.
4. Phone actively playing: the phone keeps playing, and Bopify shows it. Phase 2's own scenarios are listed under Phase 2.
5. Normal quit and relaunch: Bopify's own session resumes.
6. No frame of "Nothing playing" between connect and the track.

UI changes get before/after screenshots and previews for the loading, remote and last-resort states. This shell lacks Screen Recording permission, so either the user grants it to the terminal or takes the screenshots.

## Risks and unknowns

- **`Spirc::transfer` for "play here" works, but its reply is misleading and it is slow.** Run 5 moved playback, yet the reply was `410 Gone` after 3.2 s. Upstream awaits it inside the Spirc loop, which left the server's transfer request unanswered, and the server dropped the dealer connection; it reconnected within a second and playback continued. The request came from inside the startup handler there, so whether a non-blocking send avoids the drop is unverified.
- **How long Spotify keeps a session with no active device is unknown.** The spike restored sessions minutes old, not a "next morning" gap. When the session is gone, the decision falls through to Liked Songs.
- **An empty Liked Songs has not been observed live.** It is covered by the `handle_load` error path and a unit test.
- **Unverified: a restored or Liked Songs context in which no track can play.** `translate` drops `Unavailable` and `Stopped` (`event.rs`). If Spirc exhausts the context, Swift receives nothing further, and the panel could stay on the loading presentation. This is not handled in phase 1. If it is observed, surfacing `Stopped` is the first candidate fix.
- **Unverified: a ghost Bopify after an unclean exit.** Device ids are random per launch (every spike run had a different own id). If a killed Bopify is still listed as active *with a track* when the next one connects, `startup_decision` returns `Remote` naming "Bopify". Phase 1 ignores cluster updates while inactive, so the panel would stay on "Playing on Bopify" until a relaunch. In the spike, an instance killed a few seconds before the next launch was already gone (runs 2 and 3 both saw `active=""`), but that is two observations, not a guarantee. Live verification scenario 2 checks it. It will be fixed only on evidence.
- **The patch grows,** and every librespot bump must carry it. The flag keeps upstream behaviour intact when it is off.
- **Inferred, not observed:** today's content-less `activate()` probably replaces the account's resume point on every launch, because run 0 reported the active Bopify's empty session as `transfer_data`. The new startup never activates without content, except in the `Nothing` branch.

## Appendix: spike findings (2026-09-26)

Setup: pinned librespot `939dc5e` plus the queue patch; temporary `warn!` lines in `handle_connection_id_update` and `handle_cluster_update`; the `librespot` log category made public for the run; environment flags to skip `activate()`, force a paused takeover, or load the collection. All temporary code was reverted, and `prepare-librespot.sh` verified the checkout against the patch afterwards.

| Run | Setup | Observed |
| --- | --- | --- |
| 0 | Accidental: a second Bopify (started from Xcode, activated with no content) was the active device | `active=<that Bopify>`, `ps.ctx=""`, no track, `transfer_data` 66 bytes (context `""`, no track). When the spike instance connected, the other instance's session ended with "unexpected shutdown". |
| 1 | No active device; last session was a playlist paused on Spotify desktop; forced paused takeover | `active=""`, `same_session=false`, `ps.ctx=spotify:playlist:37i9dQZF1E8NDRt5R5oIbG`, track `3WvM2dIR9iIxMGNMP7WsNw`, paused at 1545 ms, `transfer_data` 19,947 bytes. `idle → loading → paused`. The user confirmed the track and a populated queue. |
| 2 | No active device; `activate` and `load("spotify:user:121047766:collection", start_playing: false)` | The cluster showed run 1's Bopify session as the last session (it outlived SIGTERM). `idle → loading → paused`. The user confirmed a Liked Songs track. |
| 3 | The phone pressed play while run 2's Bopify was still active, so it acted as a remote; that Bopify was then killed | `active=""` with `ps.playing=true`, `paused=false`, 203 ms at timestamp `1790418322113`. That is about 18:25:22, derived from run 3b's iPhone update at 18:27:07.98 carrying `1790418427830`, so the state was about 25 s old when the cluster arrived at 18:25:47.6. This is a stale "playing" state left by a vanished device. |
| 3b | Same inactive instance; the phone switched to "This iPhone" and skipped a track | Cluster updates arrived while Bopify was inactive: `active=<iPhone id>`, `name="iPhone"`, the track changed from `22Tmr1R5TVgtLOSYrgMWdu` to `0phqiLIH4JYk4jPissBOQE`, each with a position and timestamp. |
| 4 | Relaunch while the phone was actively playing, without `activate()` | `active=<iPhone id>`, `name="iPhone"`, `player_state` with context, track `0phqiLIH4JYk4jPissBOQE`, playing, position and duration. `transfer_data` was 1,156 bytes with an empty track. |
| 5 | Phase 2 check, 23:31. The phone was actively playing; a throwaway edit made the startup `Remote` branch send what `SpircCommand::Transfer(None)` sends while inactive: `spclient().transfer(own, own, None)` | The POST to `connect/transfer/from/<own>/to/<own>` returned `410 Gone` after 3.2 s. Straight after, Bopify handled a server transfer request, loaded the phone's track at 27 s with playing on, and was `playing` 0.6 s later; the cluster named Bopify active. The server then closed the dealer socket ("Request disconnect"), and the reply to its transfer request failed. The dealer reconnected within a second, and that connection id took the upstream path (startup guard held). The phone left the cluster 15 s later. The user confirmed that the phone stopped, the Mac continued the same track from about 0:27, and Pause worked. |

Other findings: librespot documents `spotify:user:<user_id>:collection` as the Liked Songs context (`core/src/spclient.rs`, `get_context` doc comment). Commands wait on `connect_established`, which is set inside `handle_connection_id_update` before the cluster checks, so the startup decision always runs before any queued command.
