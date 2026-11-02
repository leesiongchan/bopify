# Refused audio keys

Status: design approved by the user on 2026-11-03; awaiting review of this written spec. Second of four reliability specs. It depends on the fork rebase in `2026-11-03-connection-resilience-design.md`.

## Intent and scope

When Spotify refuses a track's audio key, Bopify holds on that track, explains why, and lets the user try again. It does not skip, and it does not exclude the track for the rest of the session. The user chose this "hold and explain" behaviour over automatic retry and over skip-with-notice.

How refusals fail today, in the pinned fork:

1. `AudioKeyManager::request` makes one attempt with a 1.5 s timeout and discards Spotify's two-byte refusal code.
2. The loader continues without decryption and fails, and the player emits `Unavailable`.
3. Spirc marks the track unavailable and skips to the next one. Marked URIs are never cleared during the session.
4. A refused preload marks the following track and immediately preloads the one after it, so the queue can drain in the background.
5. bopify-core drops `Unavailable` and `Stopped`. Swift sees successive `.loading` and `queueChanged` events and stays on "Loading…" with no explanation, and Play does nothing.

Refusals never reach `SessionLost`, and that must stay true. An engine rebuild creates a new session, which resets any back-off and asks for the key again.

Spotify refuses keys in two patterns, per librespot#1649 (open; maintainers report no planned fix):

- some newer accounts are refused every time;
- older accounts see bursts that clear after roughly 30 s.

Out of scope:
- automatic retry;
- back-off ladders longer than #1844's;
- Spotify Soloist;
- a help page;
- librespot#1845 (Bopify's `spawn_loader` already cancels abandoned loads);
- librespot#1832 and #1846 (Bopify has no prefetch).

## Approaches

The recommended approach adopts the open upstream PRs #1844 and #1799 and adds a small Bopify hold state in Spirc. A Bopify-only implementation would diverge from the fix other librespot clients carry. Plain #1799 is not enough on its own: it stops playback, but Play cannot resume because Spirc is Stopped with no decoder. Keeping librespot's skip but surfacing a notice was rejected by the user, because bursts would still lose tracks.

## Fork

1. **#1844 as published.** Key requests are serialized and spaced at least 200 ms apart. After a refusal, the session backs off 3, 5 and 10 s, with three retries.
   - It applies cleanly; add tokio `test-util` to core's dev-dependencies for its tests.
   - Commit with an `Upstream: librespot-org/librespot#1844` trailer.
2. **#1799, adapted.** A refused current track emits `PlayerEvent::AudioKeyUnavailable` and stops instead of emitting `Unavailable`. A refused preload no longer marks or reports the next track.
   - Two hunks collide with Bopify's `spawn_loader` and `teardown_tests`. Resolve them by making `spawn_loader` carry `Result<PlayerLoadedTrackData, LoadError>`, where an abandoned or dropped load maps to `LoadError::Unavailable`.
   - Trailer: `Upstream: librespot-org/librespot#1799 (adapted)`.
3. **Keep the refusal code.** `AudioKeyError::AesKey(u16)` carries the two bytes Spotify sends. `AudioKeyUnavailable` exposes them. This commit is written to be upstreamable.
4. **Spirc hold** (Bopify layer):
   - **On `AudioKeyUnavailable`:**
     - do not call `mark_unavailable` or `handle_next`;
     - keep the current track and its position, and enter a `Refused { position_ms }` play status, published to Connect as paused.
   - **Play and play/pause** from `Refused` reload the current track at that position.
   - **Next, Prev and queue selection** behave as today.
   - **Catalogue-unavailable tracks** (genuine region or format `Unavailable`) are still marked and skipped. A preload's `Unavailable` must no longer trigger another preload within the same call, which bounds the background cascade.
   - **Startup restore:** a refusal during restore completes restoration, paused on the restored track, instead of timing out as "Playback couldn't be restored".

## bopify-core

- Translate `AudioKeyUnavailable` into a new wire event: `{"type":"trackRefused","trackURI":"spotify:track:…","retryable":bool}`.
- `retryable` is true for refusal code 2. That reading of the codes is inferred from librespot#1649 reports, so it only changes wording, never behaviour.
- The player's trailing `Stopped` stays dropped. A refusal never produces `sessionLost` or a recovery checkpoint change.

## Swift

- Add `PlaybackEvent.trackRefused(uri:retryable:)`. Decoding and Rust emission land in the same commit, because `EventBridge` drops unknown types.
- The model sets `phase = .paused` on the refused track. Its metadata comes from the current queue entry, because no `trackChanged` arrives.
- Add a sticky `playbackNotice`, separate from `commandNotice` (which `queueChanged` clears). It survives `queueChanged` and clears on `.playing`, `trackChanged` or a new load. Spec 4 reuses it.
- Localized copy, both with a **Try again** link action that sends Play, following the `PlaybackConnectionStatusView` action pattern:
  - retryable: "Spotify is limiting playback right now. Try again in a moment."
  - otherwise: "Spotify won't let Bopify play this track right now."

## Verification

Tests are written first:

- **Fork core:** #1844's paced back-off tests, and refusal-code parsing.
- **Fork playback:**
  - a load failing with a refused key emits `AudioKeyUnavailable` then `Stopped`, and no `Unavailable`;
  - a refused preload emits nothing;
  - `teardown_tests` still pass with `Result` loaders.
- **Fork connect (SpircTask harness):**
  - after a refusal, the current track and `next_tracks` are intact;
  - Play reloads at the held position;
  - Next works;
  - a catalogue-unavailable preload does not chain;
  - restore with a refusal ends paused.
- **bopify-core:** translation and JSON shape of `trackRefused`; a refusal never yields `sessionLost`.
- **Swift:**
  - `PlaybackEventTests` decoding;
  - `PlayerModelTests`: phase `.paused` with queue metadata; the notice survives `queueChanged` and clears on `.playing`; Try again sends Play.

Run `scripts/test-native.sh`, the Swift package tests, the app tests, clippy and a Release build. A live refusal cannot be forced, so its manual verification uses an account that reproduces #1649, if available. Otherwise, report it as unverified.

## Research

- [librespot#1649](https://github.com/librespot-org/librespot/issues/1649): "Audio key error". Open since 2025-11-21. Maintainers describe new accounts as refused outright and older accounts as refused in bursts. A 2026-10-31 report on #1844 shows refusals at t+0, 3, 8 and 18 s and recovery at t+28 s.
- [librespot#1844](https://github.com/librespot-org/librespot/pull/1844) and [#1799](https://github.com/librespot-org/librespot/pull/1799): open, with no maintainer review. This is a deliberate choice to carry unreviewed patches.
- Spotifast v0.16.0 ([crmne/spotifast@3767d53](https://github.com/crmne/spotifast/tree/3767d53)) shows a banner and troubleshooting text that distinguish the two refusal patterns.
