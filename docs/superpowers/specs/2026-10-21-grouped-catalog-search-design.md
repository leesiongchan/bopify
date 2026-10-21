# Grouped catalog search design

## Purpose and scope

Bopify search will find songs, albums, and artists in one query so listeners can
choose music and start playback without opening Spotify. Results appear in three
groups with subtle icons identifying each result type. Selecting any result
starts playback immediately.

The agreed scope includes grouped search, independent pagination, existing
keyboard controls, and retained search state. Playlists, collection detail views,
queue editing, and new playback engine operations are outside this change.

Success means a listener can search an album or artist by name, distinguish it
from a song with the same name, and play it by click or Return. Existing song
search, cancellation, authorization, and artwork behavior continue to work.

## Search presentation

Keep the popover 300 points wide, the existing search field, 32-point result rows,
and 22-point artwork. Cap the results viewport at 292 points, growing to fit its
contents below that cap and scrolling within it when necessary. The browser
mockup used CSS pixels to represent these native dimensions.

Show groups in the fixed order Songs, Albums, Artists. Preserve Spotify's result
order within each group. Initially request two results per type; do not combine
the three lists into a new relevance ranking. Hide groups with no displayable
results. Show the existing empty state if the complete response has no
displayable results.

Each group has a quiet heading and a More button when another page is available.
Each row shows artwork, a primary title, and a small trailing icon: a music note
for songs, a disc for albums, or a person for artists. Songs and albums show
artist names as secondary text; artists show their name without a redundant
subtitle. Artist artwork is circular; other artwork retains the current rounded
square shape. Keep text and icons in the existing primary and secondary styles.

More fetches the next page for only that group and appends results there. Use a
page size of ten after the initial two results. Keep the selected result and
search field focus stable while inserting rows, including when insertion shifts
a later group. Remove More when that group has no next page. Replace the current
automatic pagination on reaching the bottom with these explicit group controls.

## Keyboard and playback behavior

Flatten displayed result rows in group order for Up and Down navigation. Headings,
loading indicators, and More or Retry controls are not result selections. Keep
the existing initial selection behavior: no result is selected until navigation
or a row click; Down starts at the first row, Up at the last, and neither wraps.
Selected rows scroll into view. More and Retry remain reachable through normal
keyboard focus and have group-specific accessibility labels.

Clicking a row or pressing Return on a selected result creates a
`PlayRequest(contextURI:)` from that result's Spotify URI, passes it through the
existing player load path, and closes search. A song plays as a track context;
an album or artist uses its corresponding context. Selecting an artist does not
open a detail view or synthesize a new top-tracks queue.

Retain the existing signed-in and engine-readiness guards. Only results present
in the current search model can produce a playback request. Escape closes search.
Keep composition handling in `CatalogSearchField` so Return and arrows do not
interrupt input methods. Accessibility labels include result type, title, and
available artist names; the decorative icons are hidden from accessibility.

## Components and contracts

The change stays in the existing Swift modules and native app. No new dependency,
OAuth scope, or Rust playback operation is needed.

| Component | Responsibility |
| --- | --- |
| BopifyDomain | Define search kinds, typed results, pages, and the catalog search service contract. |
| SpotifyLibraryClient | Request and validate Spotify search pages, mapping songs, albums, and artists into domain results. |
| SearchModel | Own query lifecycle, grouped results, pagination, selection, cancellation, and retry state. |
| SearchView | Render groups and controls, preserve native input behavior, and forward selection. |
| AppEnvironment | Load the selected result's context through the existing player and dismiss search. |

Replace the track-only search contract and update its repository consumers
together. Use `CatalogSearchKind` with song, album, and artist cases, and a
`CatalogSearchResult` enum carrying `Track` for songs and `LibraryCollection` for
albums or artists. Derive presentation fields and URI from the result; validate
that the URI kind agrees with its case at the API boundary.

`CatalogSearchPage` contains results and the next offset for one kind.
`CatalogSearchService.search(query:kinds:offset:limit:)` returns pages keyed by
requested kind. Initial search requests all three kinds; More requests one.
Reuse existing track and collection metadata decoding, artwork validation, and
pagination checks rather than adding a second Spotify client.

Search previews, service fakes, app injection, and the unavailable-service fallback
must adopt the new contract. Existing Library services and collection playback
keep their current interfaces.

## Requests and retained state

Keep the existing 300 ms debounce and trimmed-query behavior. Empty input clears
all groups and makes no request. A new query clears prior results and selection,
cancels all pending search tasks, and advances the generation used to reject
late responses even if a service ignores cancellation.

Send the initial request to `/v1/search` with `type=track,album,artist`, offset
zero, and limit two. Keep each returned page's next offset separately. More sends
the same query with only the requested type and that group's offset. Derive
pagination progress from the raw response item count, before dropping malformed
items or duplicates, so filtering does not repeat pages.

Validate requested page shapes and advancing offsets using the existing client
rules, including the search offset ceiling of 1000. Skip malformed individual
items and deduplicate appended results by URI within a group. A structurally
invalid requested page fails that request rather than appearing as an empty
successful response.

Maintain initial loading and error state plus per-group loading, error, retry
time, and next offset. Prevent duplicate concurrent requests for the same group.
Independent group requests may complete in either order without replacing each
other's results or selection.

Closing search cancels pending requests but preserves the query, successfully
loaded groups, their next offsets, and selection in memory. Reopening restores
that state without refetching completed results. If initial loading was cancelled
before results arrived, reopening retries initial search. Cancelled More requests
leave their offsets available for another click. Clearing input, signing out, or
resetting library access clears all search state through existing lifecycle hooks.

## Loading and failures

Use the current search-field progress indicator during initial search. Initial
network or response failure uses the shared search error area and retry control.
Do not show an empty-result message while initial loading or retry is pending.

During More, show progress in the affected group and disable its More control.
Keep all loaded results playable. A failed page leaves the group's results,
selection, and next offset intact and presents a Retry control beside that group.
Retry requests the same failed offset. Other groups remain visible and usable.

Keep `LibraryError` handling, authorization recovery, and the client's shared
rate-limit cooldown. Rate or quota limits disable requests until the cooldown
expires; group errors do not bypass a cooldown shared by the client. Expired
authorization follows the existing setup flow.

Use `BopifyLog.library` for request starts, completion counts, cancellation,
failures, and playback dispatch, adding result kind and offset where useful.
Do not log query text, tokens, or credentials.

## Verification

Extend existing tests at the application's boundaries:

- Client fixtures verify initial multi-type query parameters, group-specific
  pagination parameters, mixed response decoding, empty groups, malformed items,
  invalid pages, URI-kind checks, safe artwork, and advancing offsets.
- Model tests verify fixed group order, the two-result initial request, independent
  More requests, deduplication, selection across groups, stable selection after
  insertion, retry at the failed offset, and shared cooldown behavior.
- Cancellation tests cover a new query, clear, close, sign-out, and late initial
  or pagination replies. Retained-state tests cover reopening both completed and
  interrupted searches.
- Playback tests verify that song, album, and artist selections each dispatch the
  correct context and close search, and reject results absent from the model.
- Native app tests cover group headings, icons and accessibility labels, input
  focus, keyboard movement across group boundaries, More and Retry controls, and
  the capped viewport. Update tests that assumed automatic song pagination.

Run `swift test --package-path Packages/BopifyCore` and the `BopifyAppTests`
Xcode scheme after implementation. Capture native search before and after with
deterministic fixtures, comparing grouping, subtle icons, row spacing, scrolling,
and empty or failed states. With an authenticated local session, smoke-test live
song, album, and artist search and playback; fixture tests alone cannot establish
live Spotify context behavior.

## Sources and design reference

[Spotify Search for Item](https://developer.spotify.com/documentation/web-api/reference/search),
checked 2026-10-21: supports multiple requested types, a per-type result limit of
up to ten, and offset pagination through 1000. This permits a combined initial
request and separate pagination requests for each result type.

The accepted browser study is stored locally under
`.superpowers/brainstorm/23419-1792544979/content/grouped-search.html`. It illustrates
grouping, type icons, two initial results per group, and More controls. Its sample
names, artwork, and simulated playback are design aids; the native app retains
its existing components and real Spotify data.
