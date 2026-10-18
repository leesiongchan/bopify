# Catalog search and collection covers

Implement the user's approved search design, then a fourth Library tab that shows
saved playlist/album covers and plays a collection directly. Keep all existing
Recent, Explore and Liked refresh behavior. Work directly on main as AGENTS.md
requires; preserve existing playback and authorization boundaries.

## Search

A magnifier beside the player controls and Command-F open one retained native
search window. The window searches Spotify songs, with a 300 ms typing delay,
10-result pages, cancellation and generation checks after awaits. A new query
immediately invalidates older results. Up/Down select rows, Return plays the
selection, Escape closes, Command-F refocuses. Rows display artwork, title,
artists and duration; a Load More action preserves selection. Show distinct
initial, loading, empty, authorization, unavailable and cooldown states.

Use the existing SpotifyLibraryClient, fixed API origin, bearer handling,
redirect refusal and shared cooldown. Catalog search needs no user scopes;
allow explicit no-scope library consent and preserve that pending request when
the user first needs Client ID setup. Never use the playback grant for Web API.
Do not log query text. On close cancel outstanding work; on sign-out, client
change or quit clear the model and close the window. Playback uses the current
environment's ready player and a track from the current result set.

## Library

Append Library to the existing three tabs. A compact Playlists/Albums menu
chooses the collection kind. Reuse Cover Flow with a typed item contract for
URI, title, subtitle and artwork; retain Track-based model APIs and behavior.
The saved collection model pages 50 items at a time, preserves selection while
appending, and rejects results from a previous kind or cleared session.
Clicking the selected cover or Return plays its album/playlist context URI;
there is no detail browser and no playlist contents Web API request.

Saved albums require user-library-read; playlists require playlist-read-private
and playlist-read-collaborative. Request these only when enabling Library.
Use the existing setup, consent and retry patterns. Missing artwork gets the
existing fallback; invalid collection identifiers/items are skipped, without
changing pagination offsets. New Library data loads on reveal and is invalidated
by successful consent and session/client teardown.

## Validation

Test actual request inputs and decoding, no-scope consent/setup continuation,
malformed and skipped items, safe pagination, cooldown, debounce/late responses,
kind changes, teardown and context playback. Run the full Swift package and
native/app checks, build the app, and inspect real rendered before/after UI.
Live Spotify availability and audio require an authorized account; fixtures
must not be described as a live service test.

## Research

- [Apple, Design intuitive search experiences (WWDC26)](https://developer.apple.com/videos/play/wwdc2026/292/): visible search, explicit scope, native keyboard behavior.
- [Spotify, Search for Item](https://developer.spotify.com/documentation/web-api/reference/search): catalog song search and 10-result pages.
- [Spotify, Current User's Playlists](https://developer.spotify.com/documentation/web-api/reference/get-a-list-of-current-users-playlists): enumerate collection metadata, independent of contents.
- [Spotify, Saved Albums](https://developer.spotify.com/documentation/web-api/reference/get-users-saved-albums): paginated saved album metadata.
- [Spotify, Rate Limits](https://developer.spotify.com/documentation/web-api/concepts/rate-limits): lazy loading and Retry-After.
