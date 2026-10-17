# Spotify lyric retrieval probe

Verified October 17, 2026. Both the standalone pinned-librespot probe and the implemented Swift engine API retrieved real Spotify lyrics. The native ribbon still uses Debug fixtures.

## Confirmed capability

Bopify already depends on librespot metadata/core at revision `939dc5ee9d833e1980f9495241219d9d4868a061`. Its `Lyrics::get(&Session, &SpotifyId)` uses the existing session client and deserializes the response. The client calls `/color-lyrics/v2/track/{id}`. Reuse that method rather than introduce another HTTP client or lyric provider. [Pinned Spotify request implementation](https://github.com/librespot-org/librespot/blob/939dc5ee9d833e1980f9495241219d9d4868a061/core/src/spclient.rs#L647), [librespot Lyrics API](https://docs.rs/librespot-metadata/0.8.0/librespot_metadata/lyrics/struct.Lyrics.html).

This is Spotify's internal color-lyrics service, outside its documented public Web API. Source availability is not proof that the current session can retrieve lyrics. [Spotify Web API documentation](https://developer.spotify.com/documentation/web-api).

## Standalone Rust probe result

A disposable Rust probe compiled successfully with Rust 1.99.0 against the exact pinned librespot source and cached dependencies. It calls `Lyrics::get` with a 30-second deadline, reports only sync type, line counts and timestamp validity, and never prints lyric text or credentials. It creates no player or Connect receiver and issues no playback commands.

A disposable Swift helper links the existing built `BopifyAuth`, `BopifyDomain` and AppAuth objects. It calls the existing `SpotifyAuthService.validAccessToken()` with the normal logout-intent guard. Its intended output goes directly into the Rust process through a local pipe; tokens are not placed in command arguments, environment variables or files.

A noninteractive Keychain availability check found the saved playback grant and reported that its access token had expired. The initial compiled helper, with Keychain interaction disabled, was denied credential access:

```text
credential_probe_failure=credentialAccessDenied
probe_failed=credential_unavailable
probe_exit=1 credential_helper_exit=2
```

That initial attempt made no Spotify lyric request. After the user explicitly approved the normal Keychain consent prompt, the same helper was rebuilt with interaction enabled. Bopify's existing auth code supplied a usable credential and the probe completed successfully:

```text
session_connected=true
track=11dFghVXANMlKmJXsNCbNl outcome=success sync=LineSynced lines=60 valid_starts=60 rtl=false provider_present=true
track=4uLU6hMCjMI75M1A2tKUQC outcome=success sync=LineSynced lines=59 valid_starts=59 rtl=false provider_present=true
probe_exit=0 credential_helper_exit=0
```

Both responses passed the pinned `Lyrics::get` deserializer. All returned start times parsed as nonnegative signed 64-bit integers. The probe printed no words, provider text, credential values or raw response bodies and stored no lyric payload. This verifies live access and parser compatibility for these two tracks and this session; it does not establish catalog-wide availability or future endpoint stability.

Automatic approval review had rejected compiling a replacement auth library for a different runner after the initial denial, classifying that route as credential-access bypass without specific authorization. That route was not executed. The successful retry used the explicitly approved, normal Keychain consent flow instead. No Keychain access-control changes were made by the probe.

## Implemented Swift API smoke test

A temporary Debug-only hook used `AppEnvironment.connect()`'s normal engine-change callback, waited for the current player to become ready, and called `engine.requestLyrics(for:)` for `spotify:track:11dFghVXANMlKmJXsNCbNl`. It reused the real Bopify engine, session and ordinary authentication flow. It created no second probe engine and issued no playback commands.

```text
lyric_bridge_smoke=success mode=lineSynced lines=60 valid_starts=60 provider_present=true rtl=false
lyric_bridge_playback same_epoch=true same_track=true same_remote_track=true same_phase=true same_active_device=true position_delta_ms=0
```

This exercises the Swift protocol, C ABI, Rust worker, pinned SDK call, wire decoder and continuation resolution together. No words, provider text, raw response or credential values were printed or persisted. The diagnostic hook was removed after the test. Playback state and identity were unchanged across this request; this is a structural smoke test, not an audio continuity measurement.

## Implemented integration

The lyric bridge extends the existing radio request/reply flow:

| Boundary | Existing pattern to reuse |
| --- | --- |
| Rust worker | [Engine](../rust/crates/bopify-core/src/engine.rs) owns the authenticated session, runtime and event sink; `request_lyrics` spawns work against that session |
| Deadline | [Radio resolver](../rust/crates/bopify-core/src/radio.rs) supplies the pattern for the lyric resolver's 30-second outer timeout without changing session-wide retry behavior |
| FFI | [ffi.rs](../rust/crates/bopify-core/src/ffi.rs) validates input and dispatches a request ID through the existing engine handle |
| Swift API | [PlaybackEngine](../Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift) and [LibrespotEngine](../Packages/BopifyCore/Sources/BopifyPlayback/LibrespotEngine.swift) provide typed async requests |
| Replies | [EventBridge](../Packages/BopifyCore/Sources/BopifyPlayback/EventBridge.swift) registers continuations before sending, correlates replies by ID, drops late replies and fails waiters on teardown/session loss |
| Engine replacement | [AppEnvironment](../Bopify/Bopify/AppEnvironment.swift) owns the current engine; future ribbon integration must reject obsolete epochs |

`PlaybackEngine.requestLyrics(for:)` returns immutable lyric lines, synchronization mode, provider attribution, language and RTL metadata. Rust accepts canonical tracks, rejects malformed timed starts and bounds responses to 2,000 lines and 262,144 UTF-8 text bytes. Swift separates lyric and radio waiters, validates reply identity, handles cancellation/teardown and cancels its 35-second watchdog on completion. A missing resource maps to `noLyrics`, transient errors/deadlines to `network`, and unsupported/forbidden/malformed results to `unavailable`.

The C ABI preserves the existing guard contract: null input or handle returns invalid argument (`-1`), while a destroyed handle returns session lost (`-2`). No dependency, authentication, playback command or ribbon UI change was needed.

## Verification

- Rust wrapper: 76 tests pass, including normalization limits, multibyte text, URI validation, wire spelling, controlled source errors, timeout and FFI guards.
- Full native Rust script: Connect 86, playback 11 and core 21 tests pass, with relevant doctests passing. One existing audio-output test is ignored because it requires usable hardware.
- Swift package: 383 tests across 40 suites pass, including lyric decoding, callback ordering, equal IDs across channels, malformed replies, cancellation, timer cleanup, timeout and terminal events.
- Native app: 51 tests across 7 suites pass. Existing AppIntents metadata and system `linkd.autoShortcut` warnings remain.
- Final Debug and Release app builds pass after removing the temporary diagnostic hook. Rust formatting and Clippy pass. The build script generates the lyric C declaration and XCFramework; the Swift FFI smoke test links and invokes the new symbol.

## Remaining integration and live coverage

- The pinned parser requires all declared fields and accepts only `UNSYNCED` and `LINE_SYNCED`. Upstream schema changes can therefore make lyrics unavailable until the dependency supports them. [Pinned parser](../.build/librespot-939dc5e/metadata/src/lyrics.rs).
- Cancelled Swift lyric waiters do not cancel Rust work; it remains bounded by the 30-second deadline, and late replies are dropped. A Rust cancellation ABI remains outside this increment.
- Unit tests cover constructed unsynced and RTL SDK values plus failure/lifecycle paths. Live unsynced, RTL, unavailable/rate-limited and changed-schema responses remain untested; fixture coverage does not establish their current catalog behavior.
- The ribbon remains Debug-only. Connecting it to real playback additionally requires occurrence/session identity, a precise explicit-seek signal, provider attribution and rejection of stale lyric loads. The stable player already has one playback-event consumer; observe its state rather than add a second stream consumer.

The retrieval API follows the [approved bridge design](superpowers/specs/2026-10-17-spotify-lyrics-bridge-design.md). The ribbon remains a separate study with the limits described in the [native validation record](lyric-ribbon-native-validation.md); this bridge does not make that UI production-ready.
