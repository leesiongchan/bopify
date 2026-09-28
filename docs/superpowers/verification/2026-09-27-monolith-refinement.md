# Monolith refinement verification

Status: implementation in progress; native acceptance is blocked. Not ready to merge.

Worktree: `.worktrees/monolith-refinement`, branch `feat/monolith-refinement`, base `728a09b`.

## Requests and evidence

| User request | Implementation | Verified | Remaining |
| --- | --- | --- | --- |
| Remove black outline | Surface isolation probe prepared; no speculative material change | Source inspected; own-window capture attempted | Diagnose and remove actual contour, inspect before/after light/dark captures |
| Focus panel backgrounds; drag app | Native key acquisition, background drag regions, rounded logical hit region, shared 360pt engaged geometry | Layout tests and app build | Actual background/interactive drag routing and exterior click-through |
| Bound volume requests | Independent latest-value worker, 150ms ordinary cadence, immediate final flush, optimistic draft | Nine controlled volume tests, transport independence, obsolete completion, external update and failure handling | Real slider outside bounds and observed Spotify final volume |
| Spin and scrub vinyl | Phase-preserving 12s rotation, fixed lighting/progress, relative 60s/revolution scrub, 12pt spindle dead zone, 4pt slop, one release seek | Six pure rotation/scrub tests; same-diameter spindle relocation routing regression | Native reveal-time drag, cancellation paths, motion capture and positive/zero ambient ticks |
| Icon with vertical volume | Shared favorite/volume popover owner, vertical NSSlider, begin/end/cancel lifecycle | Popover attention tests and app build | Native slider tracking, placement, keyboard/VoiceOver and Escape sequence |
| Liked-song Cover Flow | Fixed-origin paged saved-track client, session-owned library, bounded refresh preserving URI selection, native drag/wheel/keys, explicit selected-song play | API/model/consent tests; center hit regions and shortcut forwarding logic | Actual click/drag/trackpad/AX behavior, narrow/short appearance and live playback |

## Latest automated evidence (2026-09-28)

- `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-refinement-tests`: 178 tests pass (96 playback, 28 library, 22 domain, 32 auth). `/private/tmp/bopify-refinement-final-tests.log`.
- `xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-refinement-build build`: exit 0. `/private/tmp/bopify-refinement-final-build.log`.
- `run-monolith-probe.py --probe library`: production AppEnvironment with isolated services verifies read consent, shared consent guard, write-consent recovery, no playback, teardown, and fixture isolation. No live OAuth. `/private/tmp/bopify-refinement-library-final.log`.
- `run-monolith-probe.py --probe input-routing`: direct responder logic passes centered-artwork edges, carousel arrows/Return, transport forwarding, and moved-spindle geometry. `/private/tmp/bopify-refinement-routing-green.log`. This is deliberately **not** evidence of real WindowServer delivery.
- `git diff --check`: exit 0.

## Blocking evidence

An authorized `CGSessionCopyCurrentDictionary` query reports `sessionAvailable=true`, `CGSSessionScreenIsLocked=1`. Native CGEvents reach the Window Server lock-screen overlay, not the test window. Early focus/drag failures are therefore invalid as product RED/GREEN evidence. The native refinement fixture checks this condition and exits 77 before interaction.

ScreenCaptureKit own-window capture fails with `SCStreamErrorDomain -3811`; a full-scene attempt returned `-3801`. No before/after screenshot or native interaction success is claimed. Native window, visual, composition, artwork, mirror and refinement acceptance remains pending; rerun sequentially once unlocked.

A single live saved-track request via the existing auth service exits 77: existing session lacks `user-library-read`. The probe prints only the error category, never credentials or response bodies; it does not open OAuth or alter playback. Use the app's explicit **Enable Liked Songs** action for consent, then rerun. Actual selected-track playback, seek, and final volume remain unverified.

## Independent review

A fresh `gpt-6-astra` reviewer inspected the branch plus pending UI changes read-only. All six scoped code findings were fixed, including both minor findings:

- Interrupted prefix refresh retains old pages/selection until revealed again (behavioral RED→GREEN).
- All-filtered pages expose explicit continuation instead of falsely declaring an empty library; no unbounded scan.
- Carousel unhandled Space/Command-arrow keys forward to transport (routing RED→GREEN).
- Geometry identity includes screen-space spindle movement, not only diameter (routing RED→GREEN).
- Visible center-cover edges belong to the center song (routing RED→GREEN).
- Retry-After begins on response receipt with a controlled clock (behavioral RED→GREEN).

The reviewer declined to infer native/live acceptance from source. Those checks remain required. No scoped code finding was intentionally deferred.

## Resume checks

1. Unlock macOS and keep the desktop available; rerun `--probe refinement`, `window`, `visual`, `composition`, `artwork`, `mirror`, then `visual --measure-ambient` sequentially.
2. Run `--probe surface`, isolate native shadow versus glass contour, implement the demonstrated correction, and inspect captures before/after.
3. Exercise real VoiceOver and system motion/transparency/contrast settings, short/narrow layouts, cross-app focus and rounded exterior click-through.
4. Grant read consent through the explicit app action, rerun `--probe live-library`, and observe authorized live playback/seek/volume behavior.
5. Fix any failures, rerun final regressions, complete the task ledger, and only then consider branch integration. Main has not been modified by this refinement.
