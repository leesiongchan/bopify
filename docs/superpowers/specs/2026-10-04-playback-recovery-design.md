# Automatic playback session recovery

Status: written spec for review, 2026-10-04. The user approved the recovery behavior in chat and explicitly selected automatic resume when music was playing on this Mac, provided another Spotify device has not taken over. Implementation has not started.

## Intent and success criteria

Recover from a lost playback session without requiring sign-out, restarting the app, or losing the familiar player surface. Reconnect automatically, restore the available Spotify session, and resume previously playing local music near the interruption position. Previously paused music stays paused. Another active Spotify device takes precedence over automatic local restoration.

Success means one recovery operation at a time, truthful playback state throughout an interruption, usable retry and reauthorization actions, and no stale engine work affecting a replacement or resurrecting a signed-out session. Network outages and provider failures can still interrupt audio; this design promises recovery behavior rather than continuous connectivity or a fixed recovery duration.

## Confirmed implementation gaps

- `PlayerModel.apply(.failed(.playbackSessionLost))` freezes the position and marks Bopify inactive, but starts no recovery. Command failures become a generic notice even when they report a dead session.
- `AppEnvironment.connect()` constructs an engine only during sign-in or restore. Its existing lifecycle serialization and explicit shutdown are useful foundations, but it does not supervise connection health.
- `Engine::new` starts the Spirc task without observing its completion. The player-event forwarder is supervised; normal Spirc termination and panic need equivalent observation.
- `SessionConfig::default()` generates a fresh device ID for every engine. Replacement therefore appears as another Spotify device.
- Patched startup restores paused and can load Liked Songs as fallback. An active ID equal to Bopify's own ID, or a foreign active device without track metadata, currently reaches fallback. Recovery must bypass both cases explicitly.
- Engine creation blocks through login without an overall deadline. Swift cancellation does not interrupt that C call.

These findings establish the missing recovery path, not the exact cause of the user's particular disconnect. Terminal notifications need diagnostic reasons so subsequent failures can be attributed.

## Architecture

Recovery is coordinated in Swift; Rust continues to own each individual librespot engine. Reconnecting inside Rust instead would keep a single FFI handle, but would duplicate the app's authentication and lifecycle decisions. No new package or service client is needed: Swift tasks and clocks, Apple's Network framework, and the existing Tokio runtime provide the required primitives. The recovery policy itself is specific to Bopify.

**`BopifyPlayback`: recovery coordinator.** Add a main-actor coordinator owning the current managed engine, attempt task, lifecycle generation, device identity, and observable connection status. Inject an asynchronous engine factory, an access-token provider, and the clock/delay source for deterministic tests. Add a small managed-engine protocol extending `PlaybackEngine` with `shutdown()`; do not add shutdown requirements to unrelated playback implementations.

**`PlayerModel`: stable presentation and event consumer.** Keep the same model across recovery. Add an explicit engine replacement boundary and a terminal-failure callback to its owner. The model remains the sole consumer of each engine's playback stream. Capture the local playback intent and freeze the displayed position before applying the terminal event. Before detaching an engine, cancel queued commands and volume editing, invalidate outstanding command generations and queue selection, and reject further commands until the replacement is ready. Every event consumer and command completion checks the engine generation so buffered old events cannot affect the new session.

**`AppEnvironment`: composition and lifecycle.** Own the coordinator, wire its token provider to playback `SpotifyAuthService`, and route Explore's radio requests to the current engine. Keep `serialize` for sign-in, sign-out, restore, and quit. These operations start or stop the coordinator; they must not hold the lifecycle chain while awaiting an indefinite retry loop. Sign-out and quit invalidate recovery immediately before waiting for teardown. Preserve artwork, library models, library authorization, the player model, and window presentation during a recoverable restart. The existing `connect()` cleanup of library state is not reused for recovery.

**Rust engine and patched Spirc.** Supervise Spirc and the player forwarder. Provide recovery-specific startup options, use the owner-supplied device ID, bound initial login, and gate automatic restoration on current cluster ownership. Keep normal cold-launch restoration paused. The bootstrap and restore decision belong inside the Spirc loop so delayed UI observations cannot authorize playback.

Proposed new types and seams in this spec are design decisions, not APIs that already exist.

## Connection state and lifecycle

Connection status is separate from authentication and playback phase:

| Status | Meaning and next action |
|---|---|
| Connecting | Initial connection or replacement creation is in progress. |
| Restoring | Login succeeded; waiting for authoritative startup and playback state. |
| Ready | Local playback, paused local playback, or a connected inactive device is confirmed. |
| Reconnecting | Recoverable failure; waiting for the next scheduled attempt. |
| Offline | No usable network path; wait for connectivity and offer Retry now. |
| Needs reauthentication | Credentials cannot recover; stop automatic attempts and offer Reconnect Spotify. |
| Failed | A nonretryable capability or internal connection failure; offer the applicable action. |
| Stopped | Sign-out or quit invalidated the session. |

On the first terminal failure, capture whether Bopify was active, its last playing/paused intent, current track identity, interpolated position at detection, volume, shuffle, and repeat. Extend the Rust event boundary with recovery identity (track URI, native track UID, and context URI), updated when the local track/context changes; the current Swift display queue does not carry sufficient native identity. Compare the restored track URI and every nonempty captured UID/context field before applying automatic seek or resume. Preserve that snapshot across retries; an intermediate loading or error state must not erase the original resume intent. During loading or buffering, use the last confirmed intent. An ended track, idle device, or remote mirror does not authorize automatic local playback.

Detach the event consumer and stop commands, shut down the old engine, obtain valid credentials, and create the replacement with the same device ID. Start its consumer and await bootstrap resolution. Do not create another engine before the previous engine or failed attempt has fully torn down. A replacement that completes after sign-out, quit, or generation invalidation is destroyed and never attached.

Generate the device UUID once for the coordinator's authenticated session and retain it through all retries. A later cold launch may use a new ID under the existing startup policy; this slice adds no preference migration or cross-launch playback persistence.

Initial sign-in and saved-session restore also use the coordinator for recoverable connection failures. Until the first ready engine, use cold-launch startup options and no automatic-resume snapshot. A user who has credentials but is offline can retry connecting without repeating browser authorization. Switching from connection failure to reauthorization requires an actual credential rejection.

## Terminal failure detection

Observe explicit session-loss events, unexpected playback-stream termination, session-loss command errors (including volume and radio), and unexpected Spirc completion or panic. Spirc termination is terminal even if the player event channel remains open. A small shared Rust terminal-report guard prevents duplicate notifications; Swift's generation and in-flight guard also coalesce reports.

Set intentional teardown state before shutting down the runtime, so cancellation and teardown-related channel closures do not trigger recovery. Once an engine has reported terminal failure, do not forward later ordinary playback events that could make the UI appear healthy again.

Dealer WebSocket reconnects already handled by librespot, a normal track-loading failure, and another device becoming active do not by themselves replace the engine. An online network path or waking Mac is a retry hint, not proof of either health or failure. Do not introduce polling or periodic engine restarts.

## Recovery bootstrap and automatic resume

Add an explicit recovery startup mode to the existing Spirc patch. Its first cluster decision has four outcomes:

1. **Foreign active device:** remain inactive even if its track or device name is missing. Mirror its playback when available. Do not restore local content, activate, apply local settings to that device, or load Liked Songs. Connectivity is ready once the device is registered and this outcome is confirmed.
2. **No active device, usable transfer state:** use the existing transfer restoration path, initially paused. Keep Spotify's current track, context, and queue. Apply the captured position only when the restored current track matches the interrupted track. If Spotify's latest session differs, keep the server's session paused rather than replaying stale local intent.
3. **Own stable ID remains active:** restore from the cluster's native `PlayerState`, which carries context, index, current/previous/next provided tracks, options, restrictions, and position. Add a focused internal adapter that reuses the existing context loading and queue-setting machinery. Preserve provided-track UIDs, providers, duplicates, and raw queue entries. Load paused, apply local volume before playback, and publish a fresh queue. Do not approximate this using the Swift display queue or convert it blindly to `TransferState`, whose queue semantics differ.
4. **No usable session:** keep the connection ready but playback unavailable, retain the last known UI as stale, and offer Retry restoration or an explicit Play action. Do not automatically substitute Liked Songs or another track.

Automatic restoration must not call `playHere()` or `spclient.transfer(own, own, None)`. Those paths intentionally take playback over and can transfer from whichever device is active when the server processes the request. Immediately before activation and resume, check the latest cluster ownership in the Spirc loop; any observed foreign takeover abandons automatic local restoration. A foreign takeover observed after resume returns the app to its normal inactive/mirroring behavior. Spotify offers no atomic guarantee against an unobserved simultaneous ownership change, so tests must cover both event orderings without claiming such a guarantee.

Resume once only when the captured intent was local playing, the restored session still matches the interrupted content, and no foreign ownership has been observed. A paused snapshot restores paused. A volume of zero remains zero. Prefer authoritative server shuffle/repeat options when supplied; use captured values only when the server omitted those options and the content matches. Inactive or remote snapshots never authorize restoring local options onto another session.

Freeze position through the interruption rather than adding outage duration. Clamp the recovery seek to the track duration. If ownership or restored content differs, discard the seek and resume request. Recovery is confirmed by playback events and a fresh queue when queue data exists, not by a successful command enqueue or the existing early `startupResolved(.restored)` notification.

Retained queue rows are display-only until the replacement publishes its queue. Give queue selections an engine epoch as well as the existing structural generation so generation counters restarting at one cannot make an old selection valid. Spotify may provide only part of a context; exact unloaded pages and shuffle history cannot be guaranteed. Preserve the available authoritative queue and expose restoration failure instead of silently claiming full preservation.

## Retry, timeouts, and authentication

Attempt recovery immediately. Subsequent retry delays use equal jitter: choose a delay between half and all of a nominal 1, 2, 4, 8, 16, then 30 seconds, with 30 seconds as the cap. Measure delays monotonically. Continue capped retries for recoverable network/session failures while signed in; retries remain available without user interaction. A flapping connection resets its retry count only after 60 seconds of confirmed readiness.

When the network path is unsatisfied, suspend attempts and display Offline. A transition back to a satisfied path, wake, or Retry now cancels a pending delay and starts one attempt promptly, but cannot overlap an attempt already creating, restoring, or destroying an engine. Retry now does not bypass permanent credential or capability failures. Network path status does not establish that Spotify is reachable. Suspend scheduled retries during system sleep; on wake, retry an interrupted recovery, while a healthy existing engine is left to its own connection handling.

Use a 30-second Tokio deadline around the complete asynchronous login/`Spirc::new` setup inside `Engine::new`. On expiry, drop the unfinished operation and runtime before returning the existing network error code. After login, allow 20 seconds for startup readiness/restoration; expire an unresponsive bootstrap into another recoverable attempt. These are initial policy constants, covered with virtual time in tests. They bound asynchronous network waits, not runtime/audio teardown or a future that blocks without yielding.

Keep explicit blocking shutdown off the main actor. Preserve the existing invariant that destruction joins every runtime worker and the audio thread before Swift releases the callback context. Do not use `shutdown_timeout` or `shutdown_background` to make teardown appear faster.

Use playback `SpotifyAuthService.validAccessToken()` before creation; its existing refresh sharing and keychain storage remain authoritative. Add an explicit forced-refresh entry point that reuses those safeguards. If creation rejects a nominally valid access token, allow one forced refresh and one creation retry for that token generation. A repeated rejection, unavailable refresh credential, or token endpoint `invalid_grant` ends automatic recovery and offers Reconnect Spotify. Network/temporary service failures remain retryable; Premium-required and invalid-argument failures do not. Use typed error categories where available so a connection error mentioning authentication cannot by itself become a permanent credential failure. Preserve preferences and the separate library authorization when playback needs reauthorization.

Do not rebuild a healthy engine on a one-hour timer. The pinned librespot source converts the initial access-token login into stored credentials and renews its own login5 tokens; initial OAuth expiry is not evidence of live-session failure. Historical foundation text claiming hourly expiry necessarily kills Spirc is superseded by this source inspection.

## UI and system controls

Keep the current artwork, metadata, compact/expanded/queue mode, and window geometry during recovery. Stop the record animation and progress clock at the captured position. Show a small localized Reconnecting… or You're offline status within the existing player surface, with Retry now accessible in each mode. Disable transport, seek, queue selection, and playback-dependent volume controls until ready. Do not open the panel, browser, or an alert during automatic recovery.

If credentials require attention, retain known track information and offer Reconnect Spotify in the player instead of stranding the user behind a generic error. Open browser authorization only after that action. A successful authorization uses the existing recovery snapshot and ownership rules; sign-out clears it. Library consent remains independent.

Release Now Playing and media-key ownership while the local engine is unavailable; reclaim it only after confirmed local playback or paused local readiness. The existing controller can remain attached to the stable player model. Retain the artwork cache and library content during recovery. Error text, retry actions, focus behavior, VoiceOver labels, and reduced motion must work in all three player modes.

## Interface and resource constraints

Carry device identity and explicit launch/recovery options across Swift, C, and Rust. Keep credential material out of domain recovery snapshots and UI state. Update the generated header through `rust/cbindgen.toml` and the existing generation/build scripts, never by editing the generated header. Existing error-code values remain stable. Any added wire event or bootstrap readiness field must be decoded and tested on both sides.

Expected implementation boundaries are the domain playback/queue event types, the new coordinator and managed-engine seam in `BopifyPlayback`, `PlayerModel`, `LibrespotEngine`/`EventBridge`, the playback auth refresh seam, `AppEnvironment`, the existing player status surfaces/localizations, Rust engine/FFI/event handling, and the existing librespot patch. Network and wake adapters live in the app; package tests inject their signals. The implementation plan will map these boundaries to individual files and tests.

The C handle shell is intentionally never freed. Each successful replacement retains another small shell; failed creation returns before allocating one. Runtime, player, audio thread, event bridge, and callback context must all be reclaimed. This slice preserves the current late-call safety contract and acknowledges linear shell growth with successful rebuilds; a handle-lifetime redesign is separate work. A repeated-recovery probe should verify resource release and distinguish these shells from a leaked runtime.

## Logging

Use existing `BopifyLog.playback`/`BopifyLog.auth` and Rust `log` boundaries. Record safe terminal reason categories, lifecycle generation, attempt number, scheduled delay, elapsed creation/restoration/teardown time, ownership decision, recovery outcome, and cancellation reason. Log transitions, not every playback tick. Do not log tokens, reusable credentials, login response bodies, raw transfer/player state, or public track/account identifiers.

## Verification and acceptance

Package and Rust tests use fake engines, a controlled token provider, virtual time, and native cluster/queue fixtures. Test Bopify's policy and adapters rather than Network, Tokio, OAuth, or librespot internals themselves.

| Scenario | Required evidence |
|---|---|
| Terminal event, stream end, Spirc completion/panic, or command loss | Exactly one recovery; diagnostic reason retained. |
| Duplicate reports or late old-engine events | No parallel creation, false readiness, or stale state mutation. |
| Dealer reconnect, remote takeover, malformed metadata, ordinary command rejection | No unnecessary engine replacement. |
| Repeated network failure and flapping readiness | Deterministic delay bounds, 30-second cap, readiness reset rule. |
| Offline, network return, sleep/wake, Retry now | Suspended delay wakes promptly; at most one attempt. |
| Sign-out/quit during delay, token refresh, create, or restore | Generation invalidates first; late created engine destroyed; no session resurrection. |
| Creation/bootstrap stalls | Deadlines trigger recovery and preserve callback teardown ordering. |
| Same-ID stale ownership and usable no-active transfer | Restore current native content and available queue; no Liked Songs fallback. |
| Foreign active device with and without metadata; takeover during restore | Stay inactive or abandon automatic resume; no automatic transfer endpoint call. |
| Local playing, paused, buffering, ended, idle, or mirroring | Preserve prior intent; resume once only for matching local playing content. |
| Track mismatch, zero volume, shuffle/repeat, duplicate/raw queue entries | No stale seek/resume or settings applied to a different session; native queue order preserved. |
| Queue selection from before replacement | Rejected even when the structural generation number repeats. |
| Expired token, rejected nominally valid token, invalid refresh grant, Premium | Refresh where recoverable; otherwise stop retries and expose the correct action. |
| Repeated successful replacement | One live runtime/audio session; released callbacks; only documented handle shells retained. |

Run the existing package and Rust suites plus app Debug and Release builds after implementation. Verify UI with before/after screenshots and a scripted recovery probe for compact, expanded, and queue modes, offline state, retry, and reauthorization. Exercise a live Spotify session with forced transport loss, network loss/return, sleep/wake, and another device taking over during recovery. Log and report actual recovery latency; do not claim gapless playback. A session lasting beyond initial OAuth expiry should demonstrate that the new policy does not force periodic rebuilds.

## Scope and sources

This slice changes recovery behavior and the startup branches it requires. Ordinary launch remains paused, explicit Play here retains its takeover semantics, and library features do not gain additional authorization or retry policies. The pre-existing foreign-trackless cold-start fallback is documented above but is not silently redesigned; the new strict ownership gate applies to recovery.

Research checked 2026-10-04; local implementation findings use pinned librespot revision `939dc5ee9d833e1980f9495241219d9d4868a061`, not an assumed latest API.

- librespot-core 0.8.0, Session cannot be reused after invalidation: [Session documentation](https://docs.rs/librespot-core/latest/librespot_core/session/struct.Session.html). Confirmed independently in the pinned `core/src/session.rs`.
- Spotify, access-token refresh and terminal `invalid_grant` handling: [Refreshing tokens](https://developer.spotify.com/documentation/web-api/tutorials/refreshing-tokens). Its six-month refresh-token lifetime statement applies to Developer Dashboard apps; it is not assumed for Bopify's separate playback client ID.
- AWS, retry classification and backoff: [Retry with backoff pattern](https://docs.aws.amazon.com/prescriptive-guidance/latest/cloud-design-patterns/retry-backoff.html). Exact delays above are Bopify policy choices.
- Apple, network path observation: [NWPathMonitor](https://developer.apple.com/documentation/network/nwpathmonitor).
- Tokio 1.53.2 documentation, asynchronous timeout and cancellation limits: [tokio::time::timeout](https://docs.rs/tokio/latest/tokio/time/fn.timeout.html). This reference does not require upgrading the project's pinned Tokio dependency.
- Existing repository evidence: `rust/crates/bopify-core/src/{engine,ffi}.rs`, `rust/cbindgen.toml`, `rust/patches/librespot-queue-selection.patch`, `Packages/BopifyCore/Sources/BopifyPlayback/{PlayerModel,LibrespotEngine,EventBridge}.swift`, `Packages/BopifyCore/Sources/BopifyAuth/SpotifyAuthService.swift`, `Bopify/Bopify/AppEnvironment.swift`, and the pinned source's `core/src/{session,login5,config}.rs` and `connect/src/{spirc,startup,state/transfer}.rs`.
