# Recents, Explore and Liked tabs above Cover Flow

Status: design for review, 2026-09-30. Approved section by section in brainstorming: Explore uses Spotify's own radio through librespot (option 2 after live spikes), seeds come from the user's top artists and tracks, Recents shows recent tracks, architecture A (stations resolved in Rust), layout A (text tabs and a chip row).

## Problem and outcome

The lower sleeve shows only liked songs. The user wants small tabs above Cover Flow for Recents, Explore and Liked. Spotify's Web API no longer serves discovery to Development Mode apps: Recommendations, Related Artists and featured, category, algorithmic and editorial playlists went in November 2024; New Releases, Browse Categories, artist top tracks and every batch fetch went in February 2026, and search now returns at most 10 items. Spikes on 2026-09-30 against the live API showed that artist objects no longer carry `genres` (0 of 12 checked) and that `genre:` search returns archival tracks with popularity 0, or the wrong genre once `year:` is added. The same spikes showed that librespot's internal endpoints still return Spotify's own radio for any seed track or artist, with full playlist contents and track popularity.

Outcome: three tabs share one Cover Flow. Recents lists recently played tracks. Explore offers up to ten station chips seeded from the user's top tracks and artists; each chip opens Spotify's radio mix for that seed, and choosing a cover plays the mix from that track. Liked is unchanged.

## Components and data flow

**Rust (`bopify-core`).** A new `radio.rs` is the only code that calls Spotify's internal endpoints.

- `request_radio(seed, request_id)` accepts a track or artist URI. An artist seed becomes that artist's first top track (librespot `Artist.top_tracks`, which is per country: use the session's country, else the first list present). The seed track goes to `SpClient::get_radio_for_track`, whose response names a `spotify:playlist:37i9…` mix. `SpClient::get_context` reads the mix; the first 50 tracks resolve to `WireTrack` through the metadata path `QueueMetadata` already uses.
- It emits `WireEvent::Radio { requestID, seedURI, contextURI, tracks }` or `WireEvent::RadioFailed { requestID, seedURI, reason }`, where `reason` is one of `noTopTrack`, `noMix`, `unavailable` or `network`.
- The FFI adds `bopify_request_radio(handle, seed_uri, request_id)`. It returns once the request is queued; the work runs on the engine's Tokio runtime and ends with the engine like its other tasks.
- The Spotify calls sit behind a small trait so the parsing and mapping are unit-testable without a network.

**Swift domain and playback.** `PlaybackEngine` gains `requestRadio(seed: SpotifyURI) async throws -> RadioMix`, where `RadioMix` holds `contextURI` and `tracks: [Track]`. The engine adapter matches events to requests by ID; only the newest request per seed is honoured, following the queue's generation rule.

**Swift library (`BopifyLibrary`).**

- `SpotifyLibraryClient` gains `recentlyPlayed()` (`GET /me/player/recently-played?limit=50`, scope `user-read-recently-played`) and `topItems(_:)` (`GET /me/top/{artists|tracks}?time_range=medium_term&limit=5`, scope `user-top-read`). Both pass through the shared `LibraryCooldown`.
- `SpotifyAuthService.authorizeLibraryScopes` accepts the two new scopes alongside `user-library-read` and `user-library-modify`, and requests them in a single consent.
- A `CoverFlowSource` protocol covers what Cover Flow needs: tracks, selected URI, loading, error, retry deadline, reveal/hide, select, retry, and a play request for a track. `LikedSongsModel` already has this shape and conforms.
- `RecentsModel` collapses repeated plays to the newest one per track. Its play request uses the context Spotify reports for that play, starting at the track; when there is none, it plays the track alone.
- `ExploreModel` builds chips from top tracks and top artists, interleaved and capped at ten, and keeps them for six hours. When Spotify has no top items, it uses the five newest liked songs. It keeps the selected chip and one `RadioMix` per chip for the session, with at most one station request in flight. Its play request is `PlayRequest(contextURI: mix, startTrackURI: track)`.

**App.** `AppEnvironment` owns the three sources and the playback engine's radio entry point. A new `LibraryShelf` view holds the tab bar, Explore's chip row and the Cover Flow, generalized from `LikedSongsCoverFlow` to take any `CoverFlowSource`. It takes the Cover Flow's current slot in `MonolithPlayerView`'s lower frame.

## Layout and interaction

The lower frame is about 332 × 140 pt. From the top:

1. A segmented control, "Recents · Explore · Liked", in text, centred.
2. On Explore only, a horizontally scrolling row of up to ten chips. Top tracks show ♪ and top artists show ●. The selected chip is filled and scrolls into view. The row accepts trackpad and smoothed-wheel scrolling.
3. Cover Flow, which shrinks through its existing height scaling (about 15% on Explore).
4. The selected track's title and artist.

Each tab keeps its own selection. The last tab persists in `UserDefaults` under `library.tab`, defaulting to Liked. Choosing a cover plays it through the tab's play request; the active-device, mirroring and play-here behaviour is the Liked tab's today. Tabs and chips are buttons with selected state for VoiceOver. Reduce Motion replaces the tab transition with a crossfade.

## Behavior, failures and limits

- **Consent.** Opening Recents or Explore without the new scopes shows the Liked tab's "Enable" empty state. One consent grants both scopes.
- **Refresh.** Recents reloads when its tab is shown, at most once per 60 s, and keeps the selection when that track is still present. Top items refresh at most every six hours. Stations are cached for the session.
- **Rate limits.** All Web API calls share `LibraryCooldown`; limited, quota and permission states reuse the Liked tab's UI and countdown. Stations make no Web API calls.
- **Station failure.** The failing chip shows a retry state; other chips keep working.
- **Internal endpoint breakage.** When Spotify changes or blocks the internal endpoints, Explore shows "Stations unavailable" and Rust logs the category once. Recents and Liked are unaffected.
- **No engine or signed out.** Explore shows the same unavailable state.
- **Logging.** Rust logs each station request's seed type, track count and failure category, without identifiers. Swift logs tab changes and cache hits and misses at debug level in `BopifyLog.library`.

## Risks

The radio endpoints (`/inspiredby-mix/v2/seed_to_playlist`, context resolve for `37i9…` mixes) are undocumented Spotify internals that the official clients use and librespot wraps at the pinned revision `939dc5e`. They can change without notice. Bopify already depends on librespot for playback, so this widens an existing dependency rather than adding a new kind, and the failure path above keeps the rest of the app working.

## Verification

- **Rust unit tests:** the radio response parsed to a mix URI, from a fixture captured from the 2026-09-30 spike with identifiers replaced; mix contents mapped to `WireTrack` with the 50-track cap; an artist seed resolved to its top track, including an artist with none; `Radio` and `RadioFailed` serialisation.
- **Swift package tests:**
  - `SpotifyLibraryClient`: decodes recently played and top items and requests the right scope for each, under the shared cooldown.
  - `RecentsModel`: collapses duplicates, chooses the context, keeps the selection, applies the 60 s gate.
  - `ExploreModel`: interleaves and caps chips, falls back to liked songs, applies the six-hour cache, requests once per chip, drops stale results, isolates a failing chip.
  - Engine adapter: correlates by request ID.
- **Live probe:** `docs/superpowers/verification/LibraryTabsLiveProbe.swift` makes one real station request and one recently-played request and prints pass or blocked categories only.
- **Manual:** the user runs the app to check each tab, several chips, playing from each tab, and the first consent. A `log stream` capture is used when behaviour is unclear.

Done means all three tabs play correctly, Explore adds no Web API cost beyond top items, and every failure state above is exercised once in tests or the live probe.

## Sources

- Spotify, "Introducing some changes to our Web API", 2024-11-27: https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api
- Spotify, "Web API Changelog – February 2026": https://developer.spotify.com/documentation/web-api/references/changes/february-2026
- Spotify, "February 2026 Web API Dev Mode Changes – Migration Guide": https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide
- librespot `core/src/spclient.rs` at `939dc5e`: `get_radio_for_track`, `get_apollo_station`, `get_context`
- Spike notes (throwaway, gitignored): `.superpowers/spikes/genre-probe`, `.superpowers/spikes/radio-probe`
