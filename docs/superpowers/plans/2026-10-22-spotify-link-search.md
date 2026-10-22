# Spotify Link Search Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` or `superpowers:subagent-driven-development` when implementation is requested. Track the steps with the checkboxes below.

**Goal:** Paste a Spotify music link into search, see the exact item, and play it through the existing result selection flow.

**Architecture:** Classify user input separately from the internal `SpotifyURI` type. Branch inside the existing `SpotifyLibraryClient.search` implementation: text uses catalog search; a resource link uses a direct metadata lookup and returns an exhausted singleton search page. Keep the existing service interface, cancellation, authorization, result rows, and context playback.

**Tech stack:** Swift 6, Foundation URLComponents/URLSession, SwiftUI/AppKit, existing Spotify Web API client and Swift Testing.

**Spec:** The design brief in this document. Canonical-link search was approved and implemented on 2026-10-22; short-link resolution remains a proposed follow-up.

**Implementation verification:** 451 package tests and 170 native app tests passed; the app build passed. The implementation includes a regression fix for URL text inside ordinary queries and horizontal scrolling for long pasted links. Live-account smoke checks below have not been performed.

## Global constraints

- macOS 26+, Apple Silicon; use the existing package and app boundaries.
- No new dependency, OAuth scope, playback command, or collection detail view.
- Preserve ordinary text search: 300 ms debounce, ten initial results per type, mixed fuzzy ranking, automatic pagination, retained state, and keyboard composition handling.
- Preserve `SpotifyURI.init` and internal synthetic IDs; validate external input in the new parser.
- Log input category, result kind, request status, and cancellation/failure boundaries; do not log pasted URLs, sharing parameters, tokens, or private playlist identifiers.
- Documentation from 2026-10-21 describes an earlier grouped UI. Current code and README are the baseline.

## Review focus

- Editing, clearing, closing, or signing out during lookup must reject late results (Task 3).
- A URL resembling Spotify must never trigger a request to an arbitrary host (Tasks 1 and 4).
- Regionally relinked tracks can return a different playable URI (Task 2).
- Public playlist metadata can exist without playlist contents (Task 2).
- Pasting must not interrupt currently playing music; only selection starts playback (Task 3).

## Findings and proposed design

Verified repository behavior:

| File | Current behavior |
| --- | --- |
| `Packages/BopifyCore/Sources/BopifyDomain/SpotifyURI.swift` | Parses three colon-separated components; rejects URLs, accepts nonempty IDs and unknown kinds. |
| `Packages/BopifyCore/Sources/BopifyLibrary/SearchModel.swift` | Debounces, cancels requests, rejects stale generations, ranks results, and manages pagination. |
| `Packages/BopifyCore/Sources/BopifyLibrary/SpotifyLibraryClient.swift` | Always sends search input to `/v1/search`; already has reusable metadata DTOs and shared API cooldown. |
| `Bopify/Bopify/Views/CatalogSearchField.swift` | Native paste and input-method support; Return dispatches the selected result. |
| `Bopify/Bopify/AppEnvironment.swift` | Validates result membership, loads its context URI, and dismisses search. |

Spotify documents resource URLs and URIs, with base62 resource IDs. Use the URL's resource type and ID rather than searching for the entire URL. [Spotify URIs and IDs](https://developer.spotify.com/documentation/web-api/concepts/spotify-uris-ids), checked 2026-10-22.

Exact metadata endpoints exist for each supported music type. Fetch metadata only; the existing librespot context loader handles playback. [Get Track](https://developer.spotify.com/documentation/web-api/reference/get-track), [Get Album](https://developer.spotify.com/documentation/web-api/reference/get-an-album), [Get Artist](https://developer.spotify.com/documentation/web-api/reference/get-an-artist), [Get Playlist](https://developer.spotify.com/documentation/web-api/reference/get-playlist), checked 2026-10-22.

Development-mode playlist contents are restricted to owned/collaborative playlists, while other playlist metadata can still be returned. Do not enumerate tracks or require an `items`/`tracks` field for link lookup. [February 2026 migration guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide), checked 2026-10-22.

Spotify can substitute a playable regional version of a requested track. Accept the validated playable track URI returned by the authenticated endpoint without depending on `linked_from`. [Track Relinking](https://developer.spotify.com/documentation/web-api/concepts/track-relinking), checked 2026-10-22.

Preserve the client's existing distinction between ordinary rate limiting and account quota exhaustion. [July 2026 Web API changelog](https://developer.spotify.com/documentation/web-api/references/changes/july-2026), checked 2026-10-22.

### User behavior

Approved first-phase behavior: pasting resolves an item without starting playback. Show its real title, subtitle, artwork, and existing type icon. Automatically select this single resolved result so Return plays it; clicking also plays it. Ordinary text searches retain their current initial selection behavior.

Support tracks, albums, artists, and playlists. Accept surrounding whitespace, `http`/`https` canonical URLs, optional `intl-XX` prefixes, one trailing slash, sharing queries such as `si`, and fragments. Parse canonical URLs locally and send only a normalized URI to metadata lookup; never request the pasted canonical web URL. The localized prefix is a compatibility choice supported by an existing client implementation, not a documented Spotify contract. [Spotipy URL parser](https://github.com/spotipy-dev/spotipy/blob/master/spotipy/client.py), checked 2026-10-22.

Accept `spotify:{track|album|artist|playlist}:{base62-id}`. Require nonempty ASCII base62 IDs; do not invent a fixed ID length absent an API guarantee. Reject URL userinfo, explicit ports, encoded path separators, extra path segments, and host suffix tricks. Scheme and host are case-insensitive; resource paths and IDs remain case-sensitive. A non-Spotify URL is invalid search input rather than a URL to fetch. Ordinary non-URL text remains text search.

Recognized Spotify types outside the four music kinds, embed links, legacy user-playlist URIs, and opaque paths receive an explicit unsupported-link message. They must not silently become name searches. Podcast support and application-wide deep-link registration are outside this feature.

Canonical-link support is independently shippable. Short links require a separate network-resolution step. Spotify has acknowledged `spotify.link`, but the available staff explanation is from 2024 and is not a current redirect contract. Obtain current copied-link fixtures before enabling opaque-link support; do not assume `spoti.fi` or `/s/...` has the same contract. [Spotify staff explanation of spotify.link](https://community.spotify.com/forum/en/discussion/5956616/how-can-i-create-a-shorter-spotify-link-instead-of-open-spotify-com), dated March 24, 2024.

### Alternatives

| Approach | Tradeoff |
| --- | --- |
| Branch in existing search client — recommended | Smallest change; preserves model request lifecycle and all service conformers. |
| Add a separate `resolve(uri:)` service | More explicit separation, but adds injection/contracts and another request path for four simple endpoints. |
| Play parsed URI immediately | Avoids metadata lookup, but changes paste behavior, interrupts music, and bypasses the existing visible-result selection flow. |

## Task 1: Classify external search input

**Files:** Create `Packages/BopifyCore/Sources/BopifyDomain/SpotifySearchInput.swift` and `Packages/BopifyCore/Tests/DomainTests/SpotifySearchInputTests.swift`.

**Interface:** `public enum SpotifySearchInput: Equatable, Sendable` with cases `text(String)`, `resource(SpotifyURI)`, `invalidLink`, `unsupportedLink`; `public init(_ raw: String)` trims and classifies the input.

- [ ] Write parser tests for all four music kinds in URL/URI form, localized prefixes, whitespace, sharing queries, fragments, trailing slash, HTTP canonicalization, and unchanged text.
- [ ] Add rejection tests for empty IDs, non-ASCII/base62 IDs, URL userinfo/ports, deceptive hosts, encoded separators, extra segments, unsupported kinds, and multiple pasted links. Empty input remains empty text.
- [ ] Run `swift test --package-path Packages/BopifyCore --filter SpotifySearchInputTests`; confirm the new tests fail before implementation.
- [ ] Implement the parser with Foundation `URLComponents` and explicit path checks; leave `SpotifyURI.init` unchanged.
- [ ] Rerun the focused suite; require all cases to pass. Commit as `feat: recognize Spotify music links in search input`.

## Task 2: Resolve canonical links through the existing client

**Files:** Modify `Packages/BopifyCore/Sources/BopifyLibrary/SpotifyLibraryClient.swift`, `Packages/BopifyCore/Sources/BopifyDomain/LibraryService.swift`, `Packages/BopifyCore/Tests/LibraryTests/SpotifyLibraryClientTests.swift`, and the exhaustive error switch in `Bopify/Bopify/Views/FavoriteButton.swift`.

**Interfaces:** Keep `CatalogSearchService.search(query:kinds:offset:limit:)` unchanged. Add `LibraryError.invalidLink`, `.unsupportedLink`, and `.notFound`. Add a private `lookup(_ uri: SpotifyURI) async throws -> CatalogSearchResult` inside the existing client.

- [ ] Write URLProtocol fixture tests proving the four direct paths `/v1/tracks/{id}`, `/v1/albums/{id}`, `/v1/artists/{id}`, `/v1/playlists/{id}`; no `/v1/search` request occurs for links. Normal text still uses `/v1/search`.
- [ ] Test singleton/exhausted pages for requested kinds, empty exhausted pages for all other requested kinds, and no metadata request for excluded kinds or nonzero offsets. Preserve existing argument validation.
- [ ] Test wrong response kind, mismatched collection ID, malformed metadata, missing artwork/playlist owner, playlists without contents, unplayable/local tracks, and a track relink returning a different valid playable URI.
- [ ] Test 401, 403, 404, both 429 variants and Retry-After, transport errors, cancellation, and shared cooldown. Invalid/unsupported input must make no network request.
- [ ] Run `swift test --package-path Packages/BopifyCore --filter SpotifyLibraryClientTests`; confirm the new cases fail.
- [ ] Branch on `SpotifySearchInput` before ordinary search, reuse `SavedTrack`/`CollectionEntity` decoding and the authenticated request helper, and return existing page types. Use existing playlist read scopes for playlist lookup and no additional scopes for public catalog types.
- [ ] Map HTTP 404 to `.notFound`; keep other existing status handling. Add the three new cases to FavoriteButton's generic unavailable presentation solely to maintain exhaustive compilation.
- [ ] Rerun the focused suite; require all cases to pass. Commit as `feat: resolve Spotify links to exact catalog results`.

## Task 3: Complete selection, error presentation, and native verification

**Files:** Modify `Packages/BopifyCore/Sources/BopifyLibrary/SearchModel.swift`, `Packages/BopifyCore/Tests/LibraryTests/SearchModelTests.swift`, `Bopify/Bopify/Views/SearchView.swift`, `Bopify/Bopify/Localizable.xcstrings`, `Bopify/BopifyAppTests/MusicBrowserTests.swift`, and `README.md`.

**Interfaces:** Preserve all existing model methods and `AppEnvironment.playSearchResult`. Link-mode success sets the singleton result's URI as selected; ordinary text success does not select a result automatically.

- [ ] Add model tests for singleton selection, exhausted pagination, no playback on lookup, Return's resulting PlayRequest, and transitions between link/text/empty input. Test a delayed service that ignores cancellation after edit, clear, close, and sign-out.
- [ ] Test retained link results on reopen, retry after transient failures and cooldown, and absence of retry for invalid/unsupported/not-found links. Keep 401 in the existing reauthorization flow.
- [ ] Run `swift test --package-path Packages/BopifyCore --filter SearchModelTests`; confirm the new cases fail.
- [ ] Implement singleton selection using the parsed input category and current generation guard. Add localized error copy: “This Spotify link is invalid.”, “This Spotify link type isn’t supported.”, and “This Spotify item is unavailable.” Hide retry and guard `SearchModel.retry` for these deterministic failures; retain retry for transient errors.
- [ ] Add native tests that paste through the real field, verify no engine load on paste, and verify click/Return loads the resolved URI and dismisses search. Cover authorization/readiness guards and input-method behavior.
- [ ] Run the full package suite and native app suite using the commands below. Capture before/after screenshots for an ordinary query, a resolved song, a playlist without artwork, and an invalid link; verify the 300-point search layout remains usable.
- [ ] Document supported link types and the canonical/short-link distinction in README. Commit as `feat: support Spotify link results in native search`.

## Task 4: Optional follow-up — resolve short links

Do this after canonical lookup works and current real-world fixtures establish the redirect behavior. This task is a separate scope decision; canonical support must not claim to support every Spotify sharing format.

**Files:** Create `Packages/BopifyCore/Sources/BopifyLibrary/SpotifyLinkResolver.swift` and `Packages/BopifyCore/Tests/LibraryTests/SpotifyLinkResolverTests.swift`; extend the parser/client/model and their existing tests for short-link classification and singleton selection.

**Interface:** `SpotifyLinkResolver.resolve(_ url: URL) async throws -> SpotifyURI`. Use a separate unauthenticated ephemeral URLSession; preserve the authenticated client's redirect rejection policy.

- [ ] Capture links freshly copied from Spotify desktop and mobile; record whether GET redirects end at a canonical resource. If a format needs JavaScript, cookies, or HTML scraping, leave it unsupported and show “Copy the song, album, artist, or playlist URL from Spotify’s web player.”
- [ ] Write local redirect fixture tests for success, relative Location, loops, timeout, cancellation, unapproved hosts, non-HTTPS redirects, and a canonical destination of an unsupported type.
- [ ] Enforce exact initial/redirect hosts established by the fixtures, at most five redirects and a ten-second total deadline. Use GET, cancel before reading the final HTML body, disable cookie storage, and send no bearer token. Do not allow arbitrary URL unwrapping.
- [ ] Reparse the terminal canonical URL through Task 1 before authenticated metadata lookup. Reject every unexpected destination before following it.
- [ ] Verify the redirect fixtures and repeat Task 3's stale-response/native tests for the two-stage request. Document the tested formats and date in README.

## Verification commands and acceptance

If `artifacts/BopifyCoreFFI.xcframework` is absent, run `./scripts/build-rust.sh` before configuring SwiftPM. These are execution checks, not results claimed by this planning document.

```sh
swift test --package-path Packages/BopifyCore
xcodebuild -project Bopify/Bopify.xcodeproj -scheme BopifyAppTests \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```

Acceptance: each supported canonical link resolves the exact music item, paste alone leaves playback unchanged, click/Return plays its context, failures are actionable, ordinary search remains unchanged, and stale lookups never replace current results. Authenticated smoke checks must include one track, album, artist, accessible private playlist, and a public playlist not owned by the user.
