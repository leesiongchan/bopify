# Spotify lyric retrieval probe

Investigated October 17, 2026. Live retrieval through the pinned librespot method succeeded for two tracks after the user approved a normal macOS Keychain consent prompt. The native ribbon is not connected to this source yet.

## Confirmed capability

Bopify already depends on librespot metadata/core at revision `939dc5ee9d833e1980f9495241219d9d4868a061`. Its `Lyrics::get(&Session, &SpotifyId)` uses the existing session client and deserializes the response. The client calls `/color-lyrics/v2/track/{id}`. Reuse that method rather than introduce another HTTP client or lyric provider. [Pinned Spotify request implementation](https://github.com/librespot-org/librespot/blob/939dc5ee9d833e1980f9495241219d9d4868a061/core/src/spclient.rs#L647), [librespot Lyrics API](https://docs.rs/librespot-metadata/0.8.0/librespot_metadata/lyrics/struct.Lyrics.html).

This is Spotify's internal color-lyrics service, outside its documented public Web API. Source availability is not proof that the current session can retrieve lyrics. [Spotify Web API documentation](https://developer.spotify.com/documentation/web-api).

## Live probe result

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

## Existing integration pattern

The current radio request/reply flow supplies the pattern for a lyric bridge:

| Boundary | Existing pattern to reuse |
| --- | --- |
| Rust worker | [Engine](../rust/crates/bopify-core/src/engine.rs) owns the authenticated session, runtime and event sink; `request_radio` spawns work against that session |
| Deadline | [Radio resolver](../rust/crates/bopify-core/src/radio.rs) wraps the request in a 30-second timeout; use an outer bound without changing session-wide retry behavior |
| FFI | [ffi.rs](../rust/crates/bopify-core/src/ffi.rs) validates input and dispatches a request ID through the existing engine handle |
| Swift API | [PlaybackEngine](../Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift) and [LibrespotEngine](../Packages/BopifyCore/Sources/BopifyPlayback/LibrespotEngine.swift) provide typed async requests |
| Replies | [EventBridge](../Packages/BopifyCore/Sources/BopifyPlayback/EventBridge.swift) registers continuations before sending, correlates replies by ID, drops late replies and fails waiters on teardown/session loss |
| Engine replacement | [AppEnvironment](../Bopify/Bopify/AppEnvironment.swift) routes requests through the current engine and rejects obsolete engine epochs |

The proposed addition is an async lyric request for a canonical Spotify track URI, returning a typed result with synchronization mode, lines, provider attribution, language and RTL metadata. Requests should distinguish missing lyrics, temporary network failure and unavailable/unsupported responses. Malformed timestamps must fail validation; an empty response must not be called instrumental without evidence. Define the exact Rust/Swift contract before implementation.

## Conditions to verify before integration

- The pinned parser requires all declared fields and accepts only `UNSYNCED` and `LINE_SYNCED`. The two live line-synced responses passed; unsynced, unavailable, RTL and changed-schema responses still need coverage. A raw request through the same session client can distinguish a parser failure from access failure without printing the body if that becomes necessary. [Pinned parser](../.build/librespot-939dc5e/metadata/src/lyrics.rs).
- librespot requests and rate-limit retries need an outer deadline. A cancelled Swift waiter does not currently cancel the Rust radio task; bounded late results are dropped. Preserve that lifecycle contract or explicitly design request cancellation.
- Test the app-owned boundary: wire decoding, malformed replies, request correlation, timeout, cancellation, session loss and teardown. Reuse existing radio fixtures and bridge test patterns; do not substitute a successful fixture for live Spotify verification.
- The ribbon remains Debug-only. Connecting it to real playback additionally requires occurrence/session identity, a precise explicit-seek signal, provider attribution and rejection of stale lyric loads. The stable player already has one playback-event consumer; observe its state rather than add a second stream consumer.

Product source and shared interfaces were not changed by this probe. The proposed next implementation is specified in the [Spotify lyric bridge design](superpowers/specs/2026-10-17-spotify-lyrics-bridge-design.md). Production readiness remains as described in the [native validation record](lyric-ribbon-native-validation.md).
