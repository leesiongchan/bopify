# Catalog Search and Library Implementation Plan

**Goal:** Find and play Spotify songs and play saved playlists/albums from covers.
**Architecture:** Extend the current library client with typed search/collection
services and observable models. Reuse the current shelf for collections and
add one native results window for search.
**Tech Stack:** Existing Swift 6, SwiftUI/AppKit and Spotify Web API; no dependencies.
**Spec:** ../specs/2026-10-18-search-library-design.md

## Constraints

- Keep existing refresh behavior and work directly on main.
- Preserve the separate library grant, fixed origin and shared cooldown.
- Catalog search: 300 ms debounce, 10-item pages. Collections: 50-item pages.
- No query logging, playlist detail browser, library indexing or new dependencies.

## Tasks

1. Add request-contract tests for search and collection metadata, plus no-scope
   consent and collection scope coverage. Run to demonstrate missing behavior;
   add domain types/services and minimal client/auth changes; rerun tests.
2. Test search debouncing, pagination, late replies, reset and error/cooldown
   behavior. Implement SearchModel and verify the model suite.
3. Test saved collection paging, switching kind, selection and album/playlist
   PlayRequest context URIs. Add SavedCollectionsModel and typed CoverFlowItem
   adapters; verify existing source tests retain their behavior.
4. Wire models and consent/reset into AppEnvironment, build SearchView and its
   retained window, and add Command-F/button entry points. Add Library shelf
   branch, category menu and localized copy. Verify app lifecycle/keyboard tests.
5. Render before/after native previews, inspect layout, run full package/native
   and app checks, review the complete diff, fix material findings, then commit
   only task changes and push main.

## Review focus

- An older response must never replace a newer query or collection kind.
- Empty-scope search authorization must resume after initial Client ID setup.
- Pagination must count raw server items even when invalid items are skipped.
- Search close and session teardown must invalidate pending work and playback.
- Four tabs and the category menu must fit without changing the player frame.

## Execution

Implement inline. The user explicitly requested both features after research;
the Library cover-only correction supersedes the earlier browsing proposal.
Baseline: initial sandboxed Swift test could not write compiler cache; rerun
with approved cache access passed. No source changes existed at task start.

## Validation record

- Request/model tests were added before implementation and failed for the
  missing interfaces. Search pagination cancellation and narrow-control reach
  each had an observed failing assertion before the fix and a passing rerun.
- Complete Swift package: 422 tests passed. Native regression script passed
  with `RUSTUP_TOOLCHAIN=1.99.0`; the shell selected 1.98.0 without the override.
- Debug and Release app builds passed. Native typing, arrows, Escape, Command-F,
  scope-less setup continuation and teardown checks passed.
- The full app suite passed 125 tests before the final cancellation/layout
  adjustments. A later 126-test run encountered a locked display: WindowServer
  returned `Display 3 Shield` at level 2147483646 for hit targeting. Four existing
  focus/window-target tests failed: `windowServerTargetsTheWholeSurfaceAfterLyricsLoad`,
  `sharedDragDefaultsKeepMainPlayerFocusAndCallbacks`,
  `keyboardReaderSurvivesSongChangesAndTabsToConditionalSync`, and
  `menuBarClickRaisesTheVisiblePlayerAfterAnotherWindowTakesFocus`.
- Final app run excluding exactly those four display-blocked tests: 122 tests
  passed. The excluded tests still need an unlocked display; they were not
  changed or reported as passing.
- Visual comparison: the compact player retains its frame, adds the magnifier
  and fourth Library tab, and shows playable playlist covers with an Albums/
  Playlists menu. A populated search snapshot shows artwork, song/artist labels,
  durations, search-field focus and selected result. Fixtures use original sample
  artwork and songs; live Spotify playback was not exercised.
