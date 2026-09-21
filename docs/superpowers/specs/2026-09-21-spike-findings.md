# Spike findings (Task 2)

Date: 2026-09-21
librespot revision: `939dc5ee9d833e1980f9495241219d9d4868a061`
Platform: macOS 27 (Darwin 27.0.0), arm64

Everything below was observed from a real run against a real Spotify
account. Nothing here is inferred from types alone except where labelled.

## Q0 (unplanned, and the most consequential) — which client ID works?

**A third-party Spotify Developer Dashboard client ID cannot be used for
playback.** Established over three runs:

| Run | OAuth client ID | Session client ID | Result |
|---|---|---|---|
| 1 | dashboard app | KEYMASTER (default) | `FaultyRequest(INVALID_CREDENTIALS)` |
| 2 | dashboard app | dashboard app (forced to match) | `InvalidArgument, StatusCode(400)` |
| 3 | KEYMASTER | KEYMASTER | **works** |

Run 2 is the decisive one: with both sides self-consistent, `login5`
returns a raw HTTP 400 — it will not process a login presenting that
client ID at all. So the ID is inadmissible to the access point, not
merely mismatched with the token.

Working configuration, matching librespot's own `examples/play_connect.rs`:

- Client ID: `65b708073fc0480ea92a077233ca87bd` (`KEYMASTER_CLIENT_ID`,
  `core/src/config.rs`; `SessionConfig`'s default on macOS)
- Redirect URI: `http://127.0.0.1:<port>/login` — note the path is
  **`/login`**, not `/callback`
- Scope: `streaming` alone is sufficient

**Consequence:** design doc §2.12 specifies Swift auth using our own
client ID. That cannot work for the streaming path and must be amended.
The Swift PKCE / loopback / token-exchange machinery is structurally
correct and reusable; what changes is the client ID and the callback
path. `SpotifyAuthService` hardcodes `/callback` and must become
`/login`. The registered dashboard app is retained only in case a future
version needs Web API calls, which this slice does not.

## Q5 — Does a token-authenticated device appear for Connect handoff?

**Yes, and audio is audible.** `Bopify Spike` appeared in the Spotify
device picker, playback transferred to it from another client, and the
user confirmed hearing the track out of the Mac. The event trace alone
would only prove the pipeline reached the sink; audible output is
confirmed separately by a human, because no event can establish it. Connect handoff is the
content-selection path for the MVP; the `bopify_load` fallback in §10 is
not needed for this slice.

## Q1 — Does the track-changed event carry metadata?

**Yes, in full. No Web API call is required.** Observed verbatim:

```
TrackChanged { audio_item: AudioItem {
  uri: "spotify:track:5Ohxk2dO5COHF1krpoPigN",
  name: "Sign of the Times",
  duration_ms: 340706,
  covers: [
    CoverImage { url: "https://i.scdn.co/image/ab67616d0000b273...", size: LARGE,   width: 640, height: 640 },
    CoverImage { url: "https://i.scdn.co/image/ab67616d00001e02...", size: DEFAULT, width: 300, height: 300 },
    CoverImage { url: "https://i.scdn.co/image/ab67616d00004851...", size: SMALL,   width:  64, height:  64 } ],
  is_explicit: false,
  unique_fields: Track {
    artists: ArtistsWithRole([ArtistWithRole { name: "Harry Styles", role: ARTIST_ROLE_MAIN_ARTIST }]),
    album: "Harry Styles", popularity: 94, number: 2, disc_number: 1 } } }
```

Maps onto our `Track` with no gaps: `uri`→`uri`, `name`→`title`,
`unique_fields.artists[].name`→`artists`, `album`→`albumTitle`,
`covers[].url`→`artwork`, `duration_ms`→`durationMs`.

`covers` arrived sorted **widest-first** (640, 300, 64), so `covers[0]`
is the largest. Do not rely on that ordering without checking `width` —
it is an observation from one run, not a documented guarantee.

## Q4 — Do any Spirc commands block?

`spirc.activate()` returned immediately and is synchronous (`-> Result`,
not `async`). `Spirc::new(...).await` performs the network login and is
where all connection latency and failure surfaces.

Not fully answered: transport commands (`play`/`pause`/`next`) were
driven from the remote Spotify client during this run, not called
directly on `Spirc`, so their blocking behaviour is untested. Task 4
must not assume they are cheap.

## Volume scale — resolved

`VolumeChanged { volume: 32767 }` at the default. `MAX_VOLUME = u16::MAX`
(65535, `playback/src/config.rs:173`) and `initial_volume = MAX_VOLUME / 2`
(`connect/src/state.rs`), so 32767 is 50%.

**Our existing normalisation `raw / Double(UInt16.max)` is correct**, now
confirmed against a real device event rather than by argument.

## Events observed that our wire format does not model

`SessionConnected`, `SessionClientChanged`, `AutoPlayChanged`,
`FilterExplicitContentChanged`, `ShuffleChanged`, `RepeatChanged`,
`PlayRequestIdChanged`.

None are needed for this slice (the PRD scopes shuffle/repeat to v1+).
Task 4's `translate()` must drop them **explicitly**, so that a genuinely
unhandled variant stays distinguishable from a deliberately ignored one.

## Other notes

- Event ordering on handoff: `PlayRequestIdChanged` → `Loading` →
  `TrackChanged` → `Playing`. Metadata therefore arrives *before*
  `Playing`, which matches what `PlayerModel` already assumes.
- `SessionConnected` carries `user_name`, the numeric Spotify user ID.
  Treat it as personal data: it must never be logged at `.public`.
- The consent screen displays **Spotify**, not the app's own name, since
  it is Spotify's client ID. Expected, and worth stating in any README so
  it does not read as a phishing screen to a future user.
