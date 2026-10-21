# Grouped Catalog Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Find and immediately play songs, albums, artists, and playlists from one compact search with grouped results and subtle type icons.

**Architecture:** Extend the existing Spotify client with a typed catalog search contract, then migrate `SearchModel` and the native popover to independently paginated groups. Playback continues through `PlayRequest(contextURI:)`; no Rust change is required. Keep the old track service only until the native consumers have migrated, then remove it.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Foundation URLSession, Swift Testing, existing Rust/librespot playback; macOS 26 on Apple Silicon.

**Spec:** [Grouped catalog search design](../specs/2026-10-21-grouped-catalog-search-design.md)

## Global Constraints

- Keep the popover 300 points wide, the existing search field, 32-point result rows, and 22-point artwork.
- Cap the results viewport at 292 points, growing to fit its contents below that cap and scrolling within it when necessary.
- Show groups in the fixed order Songs, Albums, Artists, Playlists.
- Initially request two results per type. Use a page size of ten after the initial two results.
- Keep the existing 300 ms debounce and trimmed-query behavior.
- More fetches the next page for only that group and appends results there.
- Selecting any result starts playback immediately.
- Closing search cancels pending requests but preserves the query, successfully loaded groups, their next offsets, and selection in memory.
- No new dependency, OAuth scope, or Rust playback operation is needed.
- Use `BopifyLog.library`; do not log query text, tokens, or credentials.
- Follow `AGENTS.md`. Commit locally as tasks pass; pushing publishes a release and is outside this implementation plan.

## Review Focus

1. Queries containing accents, emoji, `&`, and Spotify field filters must reach the API intact after trimming; Task 1 tests URL query round trips.
2. Null playlist owners or artwork and malformed neighboring items must not erase valid results or corrupt paging offsets; Task 1 tests these mixed pages.
3. Group replies arriving in reverse order, including after clear or close, must not overwrite newer results or selection; Task 2 tests held continuations independently.
4. A rate-limit response received later by another group must not restart an already established cooldown; Task 2 tests the absolute deadline with an injected clock.
5. Input-method composition and long result names must retain working text entry and full accessible labels; Task 3 tests marked text, keyboard focus, and labels across all four types.

## File Map and Task Boundaries

| Task | Files and responsibility |
| --- | --- |
| 1 | Create `Packages/BopifyCore/Sources/BopifyDomain/CatalogSearchService.swift`; extend `Packages/BopifyCore/Sources/BopifyLibrary/SpotifyLibraryClient.swift`; extend `Packages/BopifyCore/Tests/LibraryTests/SpotifyLibraryClientTests.swift`. Define the contract and validate external pages. |
| 2 | Modify `Packages/BopifyCore/Sources/BopifyLibrary/SearchModel.swift` and `Packages/BopifyCore/Tests/LibraryTests/SearchModelTests.swift`. Own grouped state, requests, selection, cancellation, and retry. |
| 3 | Modify `Bopify/Bopify/Views/SearchView.swift`, `Bopify/Bopify/AppEnvironment.swift`, `Bopify/Bopify/Views/PlayerPreviews.swift`, `Bopify/Bopify/Localizable.xcstrings`, `Bopify/BopifyAppTests/MusicBrowserTests.swift`, `Bopify/BopifyAppTests/PlayerShortcutTests.swift`, `Bopify/BopifyAppTests/AppEnvironmentAuthorizationTests.swift`, and `Bopify/BopifyAppTests/LiveLyricTestSupport.swift`. Integrate the UI, migrate every app consumer, and record playback requests in the existing test engine. Remove the obsolete `TrackSearchService.swift` and client compatibility method after migrating their remaining tests. |
| 4 | Update `README.md`, inspect native screenshots, and run final package and app checks. |

Tasks are sequential. Task 2 is independently testable through the Swift package;
its app consumers intentionally migrate together in Task 3 before the next app
build. Do not introduce permanent compatibility properties or a second search
model just to keep intermediate app builds compiling.

## Task 1: Typed Catalog Contract and Spotify Pages

**Interfaces produced:**

```swift
public enum CatalogSearchKind: String, CaseIterable, Hashable, Sendable {
    case song = "track", album, artist, playlist
}
public enum CatalogSearchResult: Equatable, Sendable {
    case song(Track), album(LibraryCollection), artist(LibraryCollection), playlist(LibraryCollection)
    public var kind: CatalogSearchKind { get }
    public var uri: SpotifyURI { get }
    public var title: String { get }
    public var subtitle: String { get }
    public var artwork: Artwork? { get }
}
public struct CatalogSearchPage: Equatable, Sendable {
    public let results: [CatalogSearchResult]
    public let nextOffset: Int?
    public init(results: [CatalogSearchResult], nextOffset: Int?)
}
public protocol CatalogSearchService: Sendable {
    func search(query: String, kinds: Set<CatalogSearchKind>, offset: Int, limit: Int)
        async throws -> [CatalogSearchKind: CatalogSearchPage]
}
```

The declarations above specify signatures, not complete implementation bodies.
Result subtitles come from track artist names or the existing collection subtitle.

- [x] **Step 1: Establish the baseline.**

Run `swift test --package-path Packages/BopifyCore` and
`xcodebuild -project Bopify/Bopify.xcodeproj -scheme BopifyAppTests -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test`.
Expected: zero failed tests and `TEST SUCCEEDED`. The local FFI artifact exists;
if missing or incompatible, build it using `./scripts/build-rust.sh` first.

- [x] **Step 2: Capture native search before changes.**

Build the existing Debug preview with
`xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/search-study CODE_SIGNING_ALLOWED=NO build`,
then launch with
`open -n build/search-study/Build/Products/Debug/Bopify.app --args --music-browser-preview --preview-search`.
Expected: the offline preview opens a song-only search for Mira.

Capture `/tmp/bopify-search-before.png` from that native search window. If window
capture tooling is unavailable, temporarily capture the `window.contentView` in
the existing `typingMultipleCharactersKeepsTheInsertionPointAndArrowKeysSelectResults`
test using `bitmapImageRepForCachingDisplay(in:)`, `cacheDisplay(in:to:)`, and
`NSBitmapImageRep.representation(using: .png, properties: [:])`. Use the same
capture method after implementation and remove temporary capture instrumentation
before committing. Inspect the image; the browser study is not the native baseline.

- [x] **Step 3: Add failing client boundary tests to `SpotifyLibraryClientTests.swift`.**

Reuse its serialized `LibraryProtocol` / `LibraryFixture`, `client(scopes:)`,
`LibraryClock`, `savedTrack(_:image:)`, and `query(_:)` helpers. Add private JSON
page fixtures for all four response keys, with matching offsets and limits.

| New test | Required assertions |
| --- | --- |
| `catalogSearchEncodesAllKindsAndUsesNoUserScopes` | Search `"  Björk 🎵 & year:2026  "` with all kinds, offset 0, limit 2. Assert decoded query items equal `q=Björk 🎵 & year:2026`, `type=track,album,artist,playlist`, `offset=0`, `limit=2`; scopes are empty and the existing bearer header is used. |
| `catalogSearchDecodesAllKindsAndPlaylistOwner` | Return one valid item per type; `#expect(Set(pages.keys) == Set(CatalogSearchKind.allCases))`; compare each decoded result to its complete expected payload; `#expect(pages[.playlist]?.results.first?.subtitle == "Mira Vale")`. |
| `catalogSearchSkipsMalformedRowsBeforeDerivingDisplayResults` | Parameterize null/wrong-kind rows, null owner, absent images, and unsafe artwork beside valid rows in correctly sized pages. `#expect(ownerless.subtitle == "")`, `#expect(artworkless.artwork == nil)`, and `#expect(pages[.song]?.nextOffset == 2)` for a valid row plus null raw row. |
| `catalogSearchPaginatesOnlyRequestedKinds` | Request `.playlist` at offset 2, limit 10; `#expect(Set(pages.keys) == [.playlist])`; compare all query items to the single-type request and `#expect(pages[.playlist]?.nextOffset == 12)` for ten raw items with more available. |
| `catalogSearchRejectsInvalidInputsAndRequestedPageShapes` | Parameterize blank query, empty kinds, offsets -1/1001, limits 0/11; `#expect(LibraryProtocol.fixture.requests.isEmpty)`. Use `await #expect(throws: LibraryError.invalidResponse)` for missing requested pages, mismatched offset/limit, negative total, oversized pages, and malformed pages. |
| `catalogSearchStopsAtOffsetCeilingAndKeepsSharedCooldown` | At offset 1000, `#expect(pages[.song]?.nextOffset == nil)` when another offset exceeds the ceiling. After a 429, use `await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: 12))` for the next Library call and `#expect(LibraryProtocol.fixture.requests.count == 1)`. |

Use Swift Testing assertions in these new tests, for example:

```swift
#expect(Set(pages.keys) == Set(CatalogSearchKind.allCases))
#expect(pages[.playlist]?.results.first?.subtitle == "Mira Vale")
#expect(pages[.song]?.nextOffset == 2) // One valid and one malformed raw row.
#expect(LibraryProtocol.fixture.requests.isEmpty) // Invalid inputs.
```

- [x] **Step 4: Run the new boundary tests and confirm failure.**

Run `swift test --package-path Packages/BopifyCore --filter SpotifyLibraryClientTests`.
Expected before implementation: missing catalog types or missing `search` API,
or an assertion demonstrating a required contract is absent. Resolve unrelated
baseline failures before proceeding.

- [x] **Step 5: Implement the contract and extend the existing client.**

Add the signatures above in `CatalogSearchService.swift`. Make
`SpotifyLibraryClient` conform to `CatalogSearchService`; keep its old conformance
temporarily for the existing model. Encode requested types in `allCases` order.
Decode only requested response keys using existing `APIPage`, `SavedTrack`,
`Lenient`, and `CollectionEntity.domain(_:)` machinery. Reject a missing or
invalid requested page; skip malformed individual items. Do not trust the host
or offset embedded in the API's `next` URL. Preserve existing pagination,
authorization, redirects, and cooldown handling.

Temporarily delegate `searchTracks(query:offset:limit:)` to the new search method
with `kinds: [.song]`, unwrapping song results into the old page. This adapter is
removed in Task 3. Keep request logging free of query text.

- [x] **Step 6: Run client tests.**

Run the Step 4 command. Expected: all client tests pass, including existing
Library and legacy song tests.

- [x] **Step 7: Commit the tested boundary.**

Run `git diff --check`, then commit only this task's files with
`feat: add typed catalog search for four music kinds`.

## Task 2: Grouped Search State and Independent Requests

**Consumes:** `CatalogSearchService` and its domain types from Task 1.

**Interfaces produced in `SearchModel.swift`:**

```swift
public struct CatalogSearchGroup: Equatable, Sendable {
    public let kind: CatalogSearchKind
    public var results: [CatalogSearchResult] { get }
    public var nextOffset: Int? { get }
    public var isLoading: Bool { get }
    public var error: LibraryError? { get }
    public var retryAfter: Date? { get }
    public var hasMore: Bool { get }
}
// Existing @MainActor @Observable SearchModel, with read-only public state:
public var groups: [CatalogSearchGroup] { get } // All four, in fixed order.
public var results: [CatalogSearchResult] { get } // Flattened group order.
public var hasSearched: Bool { get } // Successful initial response, including empty.
public var query: String { get }
public var selectedURI: SpotifyURI? { get }
public var isLoading: Bool { get } // Initial search only.
public var error: LibraryError? { get } // Initial request error.
public var retryAfter: Date? { get } // Shared request cooldown deadline.
public convenience init(service: any CatalogSearchService)
init(service: any CatalogSearchService,
     debounce: @escaping @Sendable () async throws -> Void,
     now: @escaping @Sendable () -> Date = Date.init)
public func updateQuery(_ value: String)
public func search() async
public func loadMore(_ kind: CatalogSearchKind) async
public func retry(at date: Date) async // Initial request.
public func retry(_ kind: CatalogSearchKind, at date: Date) async
public func select(_ uri: SpotifyURI)
public func moveSelection(by delta: Int)
public func playRequest(for result: CatalogSearchResult) -> PlayRequest?
public func cancel()
public func clear()
```

- [ ] **Step 1: Migrate `SearchFixture` and write failing model tests.**

Keep existing normalization, cancellation, selection, paging, and retry tests,
adapting them to the new service and per-kind pages. Change `SearchFixture` to
record `SearchRequest(query:kinds:offset:limit:)` values and configure replies,
failures, and held continuations separately for initial search and each kind.
Define `SearchRequest: Equatable, Sendable` privately in this test file, with
those four fields. Reuse `testTrack(_:)` for song payloads and add private
collection result fixtures with valid album, artist, or playlist URIs.

| New test | Required assertions |
| --- | --- |
| `initialSearchRequestsTwoPerKindAndPreservesGroupOrder` | `#expect(model.groups.map(\.kind) == [.song, .album, .artist, .playlist])`; assert the first request uses all kinds, offset 0, limit 2, no initial selection, and `hasSearched == true`. Empty successful search also sets `hasSearched`. |
| `moreRequestsOnlyOneGroupAndPreservesLaterSelection` | Select a playlist, then load more songs; assert last request uses only `.song`, offset 2, limit 10, playlist URI remains selected, and other group contents/offsets are unchanged. Repeated More during the same held request makes no second request. |
| `groupsCompleteIndependentlyAndDeduplicate` | Hold album and playlist pages, complete them in reverse order, and assert both append once without overwriting each other; overlapping URIs appear once and raw next offsets advance. |
| `newQueryClearAndCancelRejectEveryLateGroupReply` | Parameterize query replacement, clear, and cancel; finish held group replies after that action and assert they cannot alter current results, selection, offsets, loading, or errors. |
| `closeAndReopenRetainCompletedAndInterruptedState` | `cancel()` retains query/results/selection/offsets; interrupted initial search remains eligible to retry; successful empty search remains completed; cancelled More can be requested again at its original offset. |
| `groupFailureRetriesItsOffsetAndPreservesOtherGroups` | Fail album offset 2; songs and playlists remain playable, album error is local, and retry requests only albums at offset 2. Initial failure remains a shared error. |
| `sharedCooldownKeepsOriginalDeadlineAcrossGroupFailures` | Start two held group requests before either fails. Inject a clock starting at 1000. A 12-second cooldown sets deadline 1012; at 1011, the other held request's one-second remaining delay keeps deadline 1012. `#expect(model.retryAfter == Date(timeIntervalSince1970: 1012))`. More and Retry before expiry make no service call; at 1012 they can resume. |
| `selectionAndPlaybackWorkAcrossAllKinds` | Arrow navigation follows flattened order, starts at either edge, clamps, and excludes controls. For each current result, `#expect(model.playRequest(for: result)?.contextURI == result.uri)`; an absent result yields `nil`. |

- [ ] **Step 2: Run model tests and confirm the missing grouped behavior fails.**

Run `swift test --package-path Packages/BopifyCore --filter SearchModelTests`.
Expected: compile failure for the new model interface or a failing grouped-state
assertion. The native app is not built at this task boundary.

- [ ] **Step 3: Implement grouped state inside the existing model.**

Use initial and per-kind task handles, plus the existing generation guard. New
query and clear cancel every handle. Cancellation clears only pending loading
state; completed data survives `cancel()`. Initial success installs all four
pages and sets `hasSearched`; More and group Retry update only their group.
Guard duplicate requests and validate advancing offsets. Keep deduplication and
selection by URI; compute flattened results from fixed group order.

Use injected `now` for absolute cooldown deadlines and prevent requests during
the shared deadline. Preserve a longer established deadline when a later error
reports a shorter remaining delay. Ordinary group failures do not block other
groups. Keep the public initializer's 300 ms debounce. Add existing-style logs
at request boundaries, completion, cancellation, and failure, including kind and
offset without query text.

- [ ] **Step 4: Run package tests.**

Run `swift test --package-path Packages/BopifyCore`.
Expected: zero failures, including unchanged auth and playback suites.

- [ ] **Step 5: Commit the grouped model.**

Run `git diff --check`, then commit the model and tests with
`feat: manage independent catalog search groups`.

## Task 3: Native Grouped Results and Playback Integration

**Consumes:** Task 1 domain/service contracts and Task 2 `SearchModel` interfaces.

**Produces:** `AppEnvironment.playSearchResult(_ result: CatalogSearchResult)` and
a grouped `SearchView` using the approved presentation. Production and preview
injection take `any CatalogSearchService`.

- [ ] **Step 1: Migrate native test fakes and add failing integration tests.**

Update `BrowserServices`, `PagingSearchService`, and `AuthorizationLibrary` to
return pages for each requested kind. Preserve their authorization and Library
behavior. Use request/continuation controls rather than arbitrary sleeps.
Adapt retained-result assertions in `PlayerShortcutTests` to `search.results`.

In `MusicBrowserTests.swift`, replace the four automatic-pagination tests with
explicit More tests. Preserve existing typing, scrolling, reopening, Command-F,
playback-dismissal, and sign-out tests while accounting for section rows instead
of assuming `NSTableView.numberOfRows` equals result count.

| New test | Required assertions |
| --- | --- |
| `groupedResultsShowFourKindsAndCapTheirViewport` | All four section headings appear in order; popover content width is 300, result rows are 32, artwork is 22, and results viewport height is at most 292. Empty groups are hidden, an all-empty response shows “No results found.”, and cancelled initial search resumes on reopening. |
| `moreLoadsOnlyItsGroupAndRetainsEditorFocus` | Selecting a playlist then clicking More songs appends songs without changing selected URI or the original field editor. Scrolling alone makes no API request. A repeated click while loading does not duplicate the request. |
| `groupRetryAndLateReplyRespectDismissal` | Failed More retains all rows and exposes Retry for that group. Dismiss search with a held group request, release it, reopen, and assert old data and offsets survive without accepting the late reply. |
| `arrowKeysCrossGroupsAndReturnPlaysEachKind` | Arrow navigation skips headers/More/Retry. Parameterize song, album, artist, playlist; assert the injected engine receives the matching `PlayRequest`, search closes, and query/results remain. No Web API playlist-items call is introduced. |
| `compositionAndAccessibleLabelsWorkForAllKinds` | With marked text active, the `CatalogSearchField` delegate does not consume Return/arrows. A long Unicode title remains fully represented in accessibility/help text, with result type and artist/owner; icons are decorative. Tab can reach group More/Retry and Escape still dismisses. |

Use existing NSWindow/NSHostingView fixtures. In `LiveLyricTestSupport.swift`,
add `private(set) var loadRequests: [PlayRequest] = []` to the existing
`LiveLyricTestEngine` and append in its existing `load(_:)`, preserving command
recording. Inject it through `PlayerModel(engine:)`; await dispatch and assert
`#expect(engine.loadRequests.last == PlayRequest(contextURI: result.uri))`.
This reuses an existing test engine without adding production test hooks.

- [ ] **Step 2: Run native tests and confirm failure before wiring the UI.**

Run `xcodebuild -project Bopify/Bopify.xcodeproj -scheme BopifyAppTests -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test`.
Expected: track-only app consumers fail to compile or new grouped UI assertions
fail. Do not weaken these assertions to match the old five-row song list.

- [ ] **Step 3: Implement grouped rows, controls, and retained state.**

Keep `CatalogSearchField` and `SearchPopoverController` behavior; they already
route input and cancel on close. In `SearchView`, use model groups with native
List sections and only result URIs as selection tags. Render nonselectable
headings with More controls; group status shows progress or an inline error and
Retry. Keep the existing initial error area. Use `TimelineView` for cooldown
updates, applying the shared deadline to all request controls.

Keep 300-point width, 32-point rows, 22-point artwork, and a 292-point results
cap. Measure or calculate section/status content so shorter lists shrink and
errors do not clip. Keep selection visible after group insertion and reopening,
restore the search field editor after pointer-activated More/Retry, and allow
normal Tab focus on controls. Remove `isNearBottom`, the automatic scroll loader,
and the old five-row height calculation. Start initial search only when
`!model.hasSearched && model.error == nil`, so completed empty results also persist.

Use muted trailing system symbols for note, disc, person, and playlist list;
mark symbols and artwork decorative. Reuse artwork loading and fallback behavior.
Render full type/title/subtitle in accessibility labels and help text even when
the visible text truncates. Group and result labels use the string catalog.

- [ ] **Step 4: Migrate app playback, preview fixtures, and localization.**

Change `AppEnvironment` injection and `UnavailableMusicBrowser` to the new
service. Generalize `playSearchResult` to the declared result type while retaining
its auth, ready-engine, current-result, load, and close behavior. Update
`PreviewLibraryServices` to return deterministic fixtures for all requested kinds,
with at least three matches per group for the existing Mira preview query so
More can be exercised. Existing preview flags and library fixtures remain valid.

Change `search.placeholder` to “Search songs, albums, artists, playlists” and
`search.empty` to “No results found.” Add localized group titles, singular type
labels, “More”, and group-specific More/Retry accessibility labels. Reuse existing
retry, loading, and error copy. Follow the string catalog's existing formatting
and interpolation conventions rather than introducing a localization helper.

- [ ] **Step 5: Retire the old service and migrate its last tests.**

Delete `Packages/BopifyCore/Sources/BopifyDomain/TrackSearchService.swift`; remove
the client conformance and compatibility method. Update the three existing API
search tests to call `search(..., kinds: [.song], ...)` and inspect the song page,
preserving their encoding, scope, invalid-input, pagination, and cooldown assertions.

Run `rg -n 'TrackSearchService|TrackSearchPage|searchTracks|search\.tracks|loadMoreWhileVisible' Packages Bopify -g '*.swift'`.
Expected: no matches. Inspect every remaining search reference to ensure no
obsolete single-offset or automatic-pagination assumption survives.

- [ ] **Step 6: Run app and package checks.**

Run the native command in Step 2 and
`swift test --package-path Packages/BopifyCore`.
Expected: `TEST SUCCEEDED` and zero package failures.

- [ ] **Step 7: Commit the native integration.**

Run `git diff --check`, then commit the migrated UI, callers, localization, and tests with
`feat: show grouped catalog search in the native player`.

## Task 4: Native Visual Review and User Documentation

**Consumes:** Completed grouped search and existing offline preview.
**Produces:** Accurate README search instructions and evidence of native behavior.

- [ ] **Step 1: Capture and inspect the native result states.**

Rebuild and launch with the exact Debug preview commands from Task 1. Capture
`/tmp/bopify-search-after.png` using the same method as the baseline, plus a
scrolled view showing playlists. Compare the images: retained width/materials,
group ordering, muted type icons, circular artist artwork, readable subtitles,
and the capped scrolling region. Exercise More, click and Return, empty search,
and a fixture failure with Retry. Use the existing `.empty` / `.failing` preview
service behavior in test fixtures for those states; do not add product controls.
Remove temporary screenshot instrumentation before final verification.

- [ ] **Step 2: Update only README search instructions.**

Replace the song-only description and automatic-pagination sentence with search
across songs, albums, artists, and playlists; explain group More controls and
immediate playback. Preserve query retention and keyboard instructions. Keep
setup, release, lyrics, and unrelated documentation unchanged.

- [ ] **Step 3: Complete the live smoke check when a local session is available.**

Search and play one result of each kind, including a searchable playlist the
account does not own. Confirm observed playback and displayed context. If no
authenticated local session is available, record this check as unperformed in
the handoff; do not claim live playback was verified from fixture results.

- [ ] **Step 4: Finish verification.**

If visual fixes changed code, rerun the app/package checks from Task 3 after the
last fix. Otherwise, use their passing results without redundant full-suite runs.
Run `git diff --check` and inspect `git status --short` and the final diff against
the pre-implementation commit. Confirm every change implements this spec and
the compatibility adapter is gone.

- [ ] **Step 5: Commit documentation and verified visual adjustments.**

Commit the README and any verified visual
adjustments with `docs: describe grouped catalog search` or a subject describing
the actual code adjustment when there is one.

The final handoff links changed files, summarizes test results and native visual
differences, and identifies whether live Spotify playback was checked. Do not
push or publish as part of these tasks.
