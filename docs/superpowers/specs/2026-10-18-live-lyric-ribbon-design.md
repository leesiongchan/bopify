# Live lyric ribbon for local playback

Status: Debug implementation completed October 18, 2026, following the approved [implementation plan](../plans/2026-10-18-live-lyric-ribbon.md). Automated checks and native fixture checks pass; live repeat-boundary and hide/reopen checks now pass; full live acceptance still needs reconnect verification, with spoken VoiceOver coverage also open; the user confirmed full-screen Escape/reopen. See the [validation record](../../live-lyric-ribbon-validation.md). Execution remains native, with commits and pushes directly to `main`.

## Purpose and scope

Connect the existing quiet lyric ribbon to music playing through Bopify on this Mac. A listener can follow the current words, hold a passage, and return to the current cue without changing playback. Preserve the clean retro Liquid Glass surface, native panel behavior and original fixture preview.

This increment is a Debug-only live integration. It adds development menu actions to show, hide and explicitly focus the ribbon during normal Bopify playback. It does not open automatically, follow other Spotify devices, expose a Release command, add a provider, cache lyrics to disk, process audio, translate text or add AI features.

Retrieval uses the completed [Spotify lyric bridge](2026-10-17-spotify-lyrics-bridge-design.md), including its existing session, normalized domain values, limits, deadlines and cancellation contract. The [native ribbon design](2026-10-17-lyric-ribbon-design.md) remains the authority for appearance, focus and reading interaction. The [verification record](../../spotify-lyrics-probe.md) establishes live retrieval, not permission to release synchronized lyrics. Spotify lists lyric synchronization among disallowed uses; Debug compilation does not establish an exception. [Spotify Compliance Tips](https://developer.spotify.com/compliance-tips).

## Architecture and alternatives

Add one app-owned `LiveLyricRibbonSession` beside the fixture preview session. It adapts the existing observable player state to `LyricPlaybackSnapshot`, owns lyric-loading and display-clock tasks, and presents the existing model and window controller. `AppEnvironment` owns its lifecycle and provides access to the current engine through the recovery coordinator.

Observe `PlayerModel` using the existing `withObservationTracking` pattern used by `NowPlayingController` and `StatusItemController`. Reschedule observation onto the main actor after a change, read a coherent current snapshot there, and guard queued callbacks with a stopped/session generation. Observation must never issue an engine command from a Rust callback. Apple supplies both this callback API and the newer transactional `Observations` async sequence; the callback pattern fits the existing app without introducing a second observation style. [Apple withObservationTracking](https://developer.apple.com/documentation/observation/withobservationtracking(_:onchange:)), [Swift transactional observation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0475-observed.md).

An alternative is to drive loading from a SwiftUI view task, but that couples network and playback observation to view replacement and visibility. Another is to broadcast engine events to a second consumer, which changes the established single-consumer contract. Neither is needed: `PlayerModel` remains the only consumer of `engine.events`, and the live session reads its folded state.

Remote playback is a later increment. Its current snapshot lacks occurrence identity and explicit seek cause, so a URI and clock jump cannot reliably identify repeated plays or seeks. This local-first choice requires no Rust event schema, C ABI, dependency or authentication change.

## Playback identity and eligibility

Add two observable, read-only revisions to `PlayerModel`:

| Signal | Advances on | Does not advance on |
| --- | --- | --- |
| `playbackRevision` | Every applied `.trackChanged`, including the same URI | Queue metadata hydration, pause/resume, ordinary timing correction |
| `seekRevision` | Applied `.seeked` | `.positionCorrection` or a rejected seek command |

The pinned player's `start_playback` emits `TrackChanged` for repeat-one, same-track reload and preloaded playback. Its fast paths can skip `Loading`, so a counter attached only to `Loading` is insufficient. These revisions describe confirmed input transitions, not commands or guessed position thresholds. A seek while loading can restart the load without `Seeked`; loading already clears the held passage and the subsequent `TrackChanged` supplies a new playback revision. [Pinned player implementation](../../../.build/librespot-939dc5e/playback/src/player.rs).

An eligible local input requires a ready current engine, local ownership, no live or stale remote mirror, and a supported track URI. Swift checks the track kind; canonical URI validation remains in the existing Rust boundary. When a queue current entry exists, its URI must match `state.currentTrack.uri` before combining its occurrence ID with the audio metadata. Until they agree, display loading rather than words under an incorrect title. The supported settled phases are playing, paused and ended. Loading, idle and error states do not reuse a previous passage.

The input identity contains the engine epoch, playback revision, queue current entry ID when available, and track URI. The playback revision distinguishes same-URI playthroughs even when the queue entry does not change. When no queue entry is available, the epoch, playback revision and track URI still identify the confirmed local input; do not invent a queue occurrence or rely on a stale recovery identity. Duration and position come from the current player, not a second clock reconstructed from engine messages.

Map the engine epoch to the ribbon session identity and the playback revision plus available queue entry to its occurrence identity. Preserve the track URI separately as the recording identity. Any identity change clears Hold text and invalidates earlier loads before new content can appear.

## Loading and stale result protection

The live session starts a request only when visible and eligible. Its injected request closure accepts a track URI and expected engine epoch. The app checks that epoch, current engine and readiness immediately before forwarding to `requestLyrics(for:)`; it creates no additional engine or session.

Before requesting, clear prior document metadata and call the ribbon model's `beginLoad`. Capture the returned token, complete input identity and the session's own generation. On completion, recheck visibility, readiness, local ownership, matching track and queue identity, epoch, playback revision and generation. Apply only a matching result. Cancellation is an optimization; these comparisons are the stale-result guarantee.

Cancel and invalidate pending work on hide, new input, loading, ownership loss, detachment, sign-out and shutdown. An obsolete task's `defer` must not clear the task handle belonging to a newer request. Late results and cancellation errors are ignored. Rust work can continue to its existing 30-second deadline after a Swift waiter is cancelled.

Use one request for each visible eligible input. Do not refetch on display ticks, pause/resume, a routine timing correction or seeking within the same input. Do not automatically retry service failures in a loop. Hiding and showing again starts a fresh request from current player state; it does not restore a held passage or briefly flash retained words.

An actual `PlayerError.playbackSessionLost` from the current engine follows the app's existing coordinator reporting path, guarded by the dispatched epoch. A lyric failure never reports playback loss, changes authentication or issues transport commands.

## Content and attribution

Adapt `TrackLyrics` into the existing ribbon content model at one boundary:

| Result or player condition | Ribbon presentation |
| --- | --- |
| Eligible request pending | Loading lyrics |
| Line-synced lyrics | Existing timed document and current/previous cue projection |
| Unsynced lyrics | Plain text in original line order with normal scrolling; no Live label or Hold text control |
| `LyricFailure.noLyrics` | No lyrics found |
| Network or unavailable failure | Lyrics unavailable |
| Local track loading or queue/audio metadata mismatch | Loading track, with the previous passage cleared and no lyric request yet |
| No current local item | A neutral prompt to play music on this Mac |
| Mirrored playback or local ownership lost | A neutral message that this ribbon follows playback on this Mac |
| Engine disconnected or reconnecting | Connection status with the previous passage cleared |
| Episode, local file or other unsupported item | Lyrics unavailable for this item, without sending a lyric request |

Represent ineligible conditions as typed idle reasons rather than overloading the no-lyrics outcome or embedding arbitrary UI strings in the session. The existing instrumental state remains a fixture outcome; absence of lyrics does not establish that a recording is instrumental.

Create cue occurrence IDs from source line indices, preserving repeated words, simultaneous timestamps and explicit empty lines. Reuse `LyricDocument`'s stable timestamp grouping and projection; do not add another parser or timing algorithm. Join unsynced lines with newline separators, including empty lines.

Carry provider identity, provider display name, language and RTL metadata alongside the applied content. Update and clear that metadata atomically with the document. Show upstream provider display name in a small dedicated attribution caption; fall back to the provider identifier if the display name is empty, and omit the caption when both are empty. Do not invent attribution. This caption uses the existing subdued typography and reserves its measured height for the document so cue changes do not move the panel.

Honor the RTL flag in the lyric passage's writing direction while keeping native controls and track metadata in their normal layout. Preserve text order and selectable TextKit rendering. The new ribbon/session logs identify lifecycle transitions and outcome categories only. They omit lyric text, raw responses, provider text, credentials and listening-history data. Lyric content is not written to disk.

## Clock and reading behavior

Use `PlayerModel.displayPositionMs(at:)`, `displayDurationMs` and `isPositionAdvancing` as the authoritative display inputs. A cancellable display task samples them every 100 milliseconds only while visible, eligible and advancing. It uses the existing player interpolation; it does not advance a separately accumulated playback position.

Pause stops the display task after projecting the authoritative paused position. Loading, disconnect, ownership loss, hide and shutdown cancel it. Every scheduled wake checks cancellation and the current clock generation before reading or updating the model. Showing or resuming first reprojects the current position, then starts at most one task. Reduce Motion does not reduce cue timing accuracy; the ribbon adds no cue animation.

Preserve the native study's reading rules:

- Hold text fixes the passage and scroll position while the elapsed timestamp follows playback.
- Pause/resume and routine position corrections retain a held passage.
- Confirmed seeks and new playthroughs clear hold and reset to the current cue.
- Before the first cue, explicit blank intervals and playback end use the existing neutral states. A held passage remains readable at end until the listener returns to live or another invalidating transition occurs.
- Hold, scroll, Back to live, focus and hide issue no playback commands.

## App and window lifecycle

Create the live session through `AppEnvironment` for its stable player and current recovery coordinator. Keep all live ribbon types, ownership and menu actions behind `#if DEBUG`; retain the existing standalone fixture launch unchanged.

In the normal app's right-click status menu, add Show or Hide Lyrics and, while visible, Focus Lyrics. Mark the development actions as Debug-only in their labels. Showing the panel preserves the front application's keyboard focus. Focus Lyrics deliberately enters the existing keyboard interaction mode; Tab, Space/Return and Escape keep their existing behavior. The ribbon remains independent of the record player's visibility.

Sign-out and app quit stop the session, hide its panel and release its observation/request/clock tasks. Engine replacement clears live content while the panel can remain visible in a reconnecting state; readiness starts a request for the new eligible input. A hidden panel remains hidden through reconnect. Keep the existing saved ribbon frame and accessibility fallbacks without a frame-key migration.

Add any new strings surgically during implementation. Preserve the localization changes already present in the working tree; do not regenerate or commit unrelated catalog changes.

## Verification and acceptance

Tests exercise app-owned behavior with controlled player events, lyric results and a cancellation-aware clock:

1. `PlayerModel` revisions distinguish same-URI `TrackChanged`, confirmed seek and ordinary correction. Repeat-one coverage must omit `Loading` to reproduce the pinned player's fast path. Loading-seek restart clears held text without pretending a rejected command succeeded.
2. Visible eligible local playback makes one lyric request with the current URI and epoch. Queue/audio mismatch, unsupported items, remote playback, hidden state and not-ready engines make none.
3. Reversed and late results across rapid skips, same-URI repeat, hide/reopen and engine replacement cannot apply to a newer input. An old task's completion cannot cancel or erase newer work.
4. Pause, seek, correction, repeat, loading, playback end and reconnect produce the specified reading and clock behavior. Hidden/stopped sessions leave no pending display delay, and stale wakes do nothing.
5. Timed and unsynced conversion preserve line order, blanks, repeats, attribution, language and RTL. No-lyrics and service failures use distinct presentations; neither changes playback or authentication.
6. Reading and window actions record no transport commands. Existing fixture, focus, geometry and lyric retrieval regression tests continue to pass.
7. Run full Swift package and app tests, final Debug/Release builds and relevant formatting checks. Verify Release contains no live ribbon entry point and the fixture preview still runs independently.
8. Visually compare the native ribbon before and after using deterministic fixtures. Check attribution wrapping, long passages, RTL, plain text, neutral/error states and opaque accessibility fallback; cue transitions must keep the panel geometry stable.
9. Exercise the normal Debug app with real local playback: show, hold, pause/resume, seek, skip, repeat-one, hide/reopen and reconnect. Use normal authentication and a controlled local test track. This manual protocol operates playback controls; run it as an explicit live verification step, preserve the prior repeat setting, and report cases that were not exercised. Record structural outcomes without saving lyric text or credentials.

Acceptance is a live, local-only Debug ribbon with correct reading, identity and task lifetimes. Public release, remote-repeat correctness, audible continuity measurements and broader accessibility/Spaces checks remain separate from that claim.
