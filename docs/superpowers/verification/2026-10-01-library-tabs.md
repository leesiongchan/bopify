# Library tabs verification

Checked 2026-10-01–02 on macOS 27 / Xcode 27. Branch: `library-tabs`. Spec: `docs/superpowers/specs/2026-09-30-library-tabs-design.md`. Plan: `docs/superpowers/plans/2026-10-01-library-tabs.md`.

## Result

Recents, Explore and Liked play correctly from the running app, and Explore's stations resolve from both track and artist seeds through librespot. Automated tests, the live probe and the user's hands-on checks pass. The station picker and the tab bar changed from the spec's layout during the hands-on pass; see "Layout changes".

## Automated

- Rust `bopify-core`: 44 tests pass, including the radio response parsed from the fixture, the 50-track cap, artist seeds with and without a top track, `Radio`/`RadioFailed` serialisation, the 30 s bound on a request that never answers, and 404/429 classification.
- Swift package: all suites pass (118 + 56 + 24 + 45 tests), covering recently played and top items decoding and scopes, `RecentsModel` collapse, context, selection and 60 s gate, `ExploreModel` interleave, cap, liked-songs fallback, six-hour cache, one request per chip, stale results and failure isolation, the reveal counter, request-ID correlation in the engine adapter, and Cover Flow's fade reaching the strip's edge.
- The radio fixture (`rust/crates/bopify-core/src/fixtures/inspiredby_mix.json`) was captured from the live endpoint during Task 1, with its identifiers replaced by a placeholder playlist URI.
- The app builds with `xcodebuild` for macOS arm64.

## Live

`HistoryCheck`, a throwaway script run against the consented session:

```
PASS: recently played count=50
PASS: top tracks count=5
PASS: top artists count=5
```

`LibraryTabsLiveProbe.swift` (commit 694fdf0):

```
PASS: recently played count=50 withContext=49
PASS: top items tracks=5 artists=5
PASS: station seedKind=track contextKind=playlist tracks=50
```

A debug `log stream` capture of the app during the hands-on pass showed 10 stations opened, 5 from artist chips and 5 from track chips, each with 50 tracks and none failed. Chips, stations and Recents were each fetched once and then served from memory.

## Manual

The user checked each item in the running app:

- Each tab shows its covers; playing from Liked, Recents and Explore works, and Recents continues in the context the track was played from.
- Switching stations loads the new mix; covers on Explore are the same size as on Liked.
- The last tab is restored after relaunch.
- Reduce Motion switches tabs with a crossfade.
- The loading spinner does not overlap the station button or covers.
- The mouse wheel scrolled the earlier chip row in both directions (a Logi Options+ wheel sends phase-less precise scrolls); that row was later replaced.

## Layout changes

The spec's chip row above Cover Flow shrank the covers by about 15%, which the user rejected. A floating glass chip row over the covers kept their size but blocked too much artwork. Of three alternatives (a station pill beside the tabs, a "from station" button in the track line, a corner pill that unfolds on hover), the user tried the first and chose the second.

- Explore's station is a glass "from ♪ station" button after the artist name, opening a native menu of up to ten stations. It also appears under a loading or failed station, so switching never waits on one. Artist stations use a person symbol rather than ●, which reads as a radio button in a menu.
- The tabs are a glass capsule with a sliding highlight instead of a segmented picker, centred on the controls column and placed just under the controls. The status line keeps its height while empty so the tabs don't move as tracks load.
- Cover Flow runs out to the sleeve's glass edges and shows as many covers as fit, fading them out at the edge instead of after two per side.
