# Spotify lyric retrieval bridge

Status: approved by the user on October 17, 2026. This extends the completed native ribbon study with a typed lyric retrieval API. Implementation has not started.

## Purpose and verified starting point

Use Spotify as Bopify's lyric source by reusing the authenticated librespot session already owned by the playback engine. Return usable lyric data to Swift without another HTTP client, authentication flow or provider dependency.

The [live probe](../../spotify-lyrics-probe.md) retrieved two line-synced responses through the pinned `librespot_metadata::Lyrics::get` method. The existing parser accepted 60 and 59 lines, with all start timestamps valid. This removes the need for a custom response parser for the observed schema. The dependency remains pinned at `939dc5ee9d833e1980f9495241219d9d4868a061`. [librespot Lyrics API](https://docs.rs/librespot-metadata/0.8.0/librespot_metadata/lyrics/struct.Lyrics.html).

The chosen approach extends the existing radio request/reply flow. A separate provider would introduce matching and service integration work; calling the internal endpoint with a new client would duplicate the existing session/authentication machinery. Neither is needed for the verified responses.

## Scope

Deliver one async request from the Swift playback-engine interface through the existing C ABI and Rust runtime to librespot, returning validated lyric content or a typed failure.

The ribbon remains a Debug-only study during this increment. Live ribbon observation, a release UI entry point, explicit-seek tracking, disk caching, alternative providers, translation and AI features are separate work. Preserve the existing Liquid Glass surface, playback commands, credential handling and pinned librespot checkout.

## Proposed Swift contract

Add the following method to the existing `PlaybackEngine` protocol:

```swift
func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics
```

`TrackLyrics` is an immutable, `Hashable`, `Sendable` domain value with:

| Field | Meaning |
| --- | --- |
| `trackURI: SpotifyURI` | Canonical track URI echoed from the request |
| `synchronization: LyricSynchronization` | `.lineSynced` or `.unsynced` |
| `lines: [TrackLyricLine]` | Original response order, including repeated timestamps and empty lines |
| `provider: String` | Upstream provider identifier, without inventing a value if empty |
| `providerDisplayName: String` | Upstream attribution text |
| `language: String` | Upstream language metadata |
| `isRightToLeft: Bool` | Upstream RTL flag |

Each `TrackLyricLine` contains `text: String` and `startTimeMs: Int64?`. Line-synced lines require nonnegative start times. Unsynced lines use `nil`, so zero-valued upstream timestamps cannot accidentally imply synchronization. Do not infer line endings or instrumental status from absent or empty content.

Add `LyricFailure` with `.noLyrics`, `.network` and `.unavailable`. Existing engine/session failures continue to use `PlayerError.playbackSessionLost`; cancellation throws `CancellationError`. A lyric-service failure must not log the user out or interrupt audio playback.

## Rust request and normalization

Add a lyric module alongside `radio.rs`. Its session adapter calls `Lyrics::get` on the engine's existing `Session`; it does not create another session or modify the session-wide retry strategy.

Accept only canonical Spotify track URIs at the FFI boundary, following the radio seed-validation pattern. Album, artist, episode, local-file and malformed URIs are invalid arguments. Convert the accepted track identity to the existing librespot `SpotifyId` type.

Normalize the typed SDK result once:

- Preserve line order, duplicate start times, words and explicit empty lines.
- Parse each line-synced start as a nonnegative `Int64`; reject a malformed or overflowing timestamp as unavailable rather than silently dropping a line.
- Ignore upstream start values for unsynced text and emit `null` starts.
- Carry provider attribution, language and RTL metadata. Artwork colors, vocal-removal flags, syllables and unused provider navigation fields stay outside the domain contract.
- Bound the normalized result to 2,000 lines and 256 KiB of total UTF-8 lyric text before serialization. Reject larger content as unavailable. These are application limits for this reading surface, not claims about Spotify's catalog.
- Treat a response with no non-whitespace lyric text as `.noLyrics`, without claiming the track is instrumental.

Wrap retrieval and normalization in a 30-second outer deadline, matching the existing radio request bound. Map timeout, rate limiting and transient transport failures to `.network`; a missing lyric resource to `.noLyrics`; unsupported schema, forbidden access and other service failures to `.unavailable`. Preserve the playback engine's independent session-loss handling.

## Wire contract and request lifecycle

Add the C ABI command `bopify_request_lyrics(handle, track_uri, request_id)` following `bopify_request_radio`. The command validates and queues work, then returns immediately; it must not block Swift's main actor. Generate the header and XCFramework through the existing build script.

Replies use the existing callback channel, with these proposed JSON shapes:

```json
{
  "type": "lyrics",
  "requestID": 42,
  "trackURI": "spotify:track:11dFghVXANMlKmJXsNCbNl",
  "synchronization": "lineSynced",
  "lines": [{"startTimeMs": 1000, "text": "Original test words"}],
  "provider": "fixture",
  "providerDisplayName": "Fixture provider",
  "language": "en",
  "isRightToLeft": false
}
```

```json
{
  "type": "lyricsFailed",
  "requestID": 42,
  "trackURI": "spotify:track:11dFghVXANMlKmJXsNCbNl",
  "reason": "noLyrics"
}
```

`LyricReply` decodes these messages in the domain module; unknown failure reasons map to unavailable. Recognized replies with malformed content fail the matching request when their request ID is recoverable. Log only the failure category and request identity, without lyric bodies or credentials.

`EventBridge` maintains lyric waiters separately from radio waiters. Register the continuation before invoking the FFI command, resolve it at most once, and keep lyric replies out of `PlaybackEvent` streams. A successful result must match the requested track URI. Out-of-order replies must reach the correct caller; late and duplicate replies are dropped.

Give each Swift lyric request a 35-second watchdog so malformed or lost callback messages cannot strand a continuation after Rust's deadline. Cancel that watchdog on every completion path. Caller cancellation removes and resumes its waiter immediately. Rust work may continue until its 30-second bound, using the same cancellation contract as radio; there is no new Rust cancellation ABI in this increment.

Engine teardown or session loss fails all lyric waiters before callback context is released. Runtime-owned Rust tasks remain inside the existing joined engine lifetime. Do not add a second consumer to the playback event stream.

## Files and ownership

Extend `PlaybackEngine.swift`, `LibrespotEngine.swift`, `EventBridge.swift`, Rust `engine.rs`, `ffi.rs`, `event.rs` and `lib.rs`. Add the lyric domain types and Rust normalization module as focused files. Update existing conformers and test stubs explicitly; do not introduce a silent protocol default that conceals missing support.

Reuse current patterns for logging, FFI handle locking, session ownership and generated artifacts. Do not refactor radio or change its behavior as part of this addition. No new product dependencies or changes to authentication are required.

## Verification and acceptance

Write failing tests at the app-owned boundaries before implementation:

1. Rust normalization: timed and unsynced data, duplicate timestamps, empty lines, RTL/attribution, malformed/negative/overflowing starts, empty content and size limits.
2. Rust request handling: success, missing lyrics, forbidden/schema failure, transient failure and deadline expiry, using a controlled source adapter rather than making unit tests depend on Spotify.
3. Wire compatibility: exact request ID, track URI and field spelling on both sides; unknown failure reasons and malformed content fail predictably.
4. Swift continuation lifecycle: synchronous reply during send, concurrent out-of-order requests, rejected sends, mismatched track identity, duplicate/late replies, cancellation, watchdog expiry and engine teardown/session loss. Assert replies never enter the playback stream.
5. Existing regression suites: full Rust and Swift package tests, relevant lint/type checks, XCFramework generation, full native app tests and Debug/Release builds.
6. Perform one live smoke test through the implemented Swift API using the normal Bopify session. Report structural metadata only; the standalone probe is prerequisite evidence, not a replacement for testing the completed bridge.

Acceptance means the Swift API returns typed real Spotify lyric data with the specified failure/lifecycle behavior and leaves audio playback unchanged. It does not mean the ribbon is production-ready or that the internal endpoint is a stable public Spotify API.
