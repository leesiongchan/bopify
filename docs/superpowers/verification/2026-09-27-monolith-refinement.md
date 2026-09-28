# Monolith refinement verification

Status: all six refinements implemented; automated package, build, and native interaction checks pass. Live Spotify and manual accessibility acceptance remain incomplete. Not merged.

Worktree: `.worktrees/monolith-refinement`, branch `feat/monolith-refinement`, base `728a09b`.

## Requests and evidence

| User request | Implementation | Observed verification |
| --- | --- | --- |
| Remove black outline | Disable Monolith's native window shadow; restore it for the startup shell. Keep native glass and the record's soft shadow. | Native shadow produced the dark contour and extra record halo. Actual light/dark backdrop comparisons isolate it; no-shadow window regression passes. |
| Focus panel backgrounds; drag app | Native key acquisition, background drag regions including queue scroll content, rounded hit region, shared 360pt engaged geometry | Real background clicks retain focus; control/queue backgrounds move the window; 4pt slop, drag interruption, spindle stability, exterior click-through and cross-app hover pass. |
| Bound volume requests | Independent latest-value worker, 150ms ordinary cadence, immediate final flush, optimistic draft | Nine controlled volume tests; native 40-sample drag sends two commands ending at 1.0, including pointer movement outside popover bounds. |
| Spin and scrub vinyl | Phase-preserving 12s rotation; relative 60s/revolution scrub; dead zone, drag slop, geometry rebasing and one release seek | Pure math tests and native quarter-turn seek pass; clicks and cancellation send no seek. Animation measures 10 ticks/300ms playing and zero paused, inactive, hidden, or with fixture Reduce Motion. |
| Icon with vertical volume | Speaker opens native vertical NSSlider; shared favorite/volume popover owner | Native vertical orientation, outside-bound drag, stable window position, retained reveal, and Escape-before-queue behavior pass. |
| Liked-song Cover Flow | Fixed-origin saved-track paging, session-owned library, URI selection, bounded refresh, perspective artwork/reflections, explicit selected-song play | Native side click, center drag, horizontal wheel, arrows and Return pass. Browsing sends no playback; page offsets are exactly 0 and 50; Return loads the selected song once. |

## Captures

App-owned fixtures only; no account content is captured. The Cover Flow screenshot includes deliberately missing/shared artwork and a long title.

- [Cover Flow](assets/monolith-refinement/cover-flow.png)
- Light backdrop: [before](assets/monolith-refinement/outline-before-light.png), [after](assets/monolith-refinement/outline-after-light.png)
- Dark backdrop: [before](assets/monolith-refinement/outline-before-dark.png), [after](assets/monolith-refinement/outline-after-dark.png)

The outline comparison captures a controlled backdrop window with the player as its child, including actual compositor shadows. A transparent window PNG alone did not reliably expose the contour. The material is unchanged; disabling the native shadow removes the hard outer ring while retaining the glass highlight.

[Apple: SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter), consulted 2026-09-28: desktop-independent window filtering isolates app-owned content.

[Apple: SCStreamConfiguration.includeChildWindows](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/includechildwindows), consulted 2026-09-28: include the attached player in the controlled backdrop capture.

## Latest automated evidence (2026-09-28)

Run from the refinement worktree:

```sh
swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-refinement-tests
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-refinement-build build
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-refinement-build --output /private/tmp/bopify-refinement-visual-final --probe visual --measure-ambient
```

- Full package suite: **178 pass** (96 playback, 28 library, 22 domain, 32 auth). Log: `/private/tmp/bopify-refinement-native-final-tests.log`.
- macOS build: **exit 0**. Log: `/private/tmp/bopify-refinement-native-final-build.log`.
- Native probes run sequentially with the same runner/derived-data arguments, changing `--probe` and `--output`. All exit 0: `window`, `composition`, `artwork`, `mirror`, `refinement`, and `visual --measure-ambient`.
- Logs: `/private/tmp/bopify-refinement-{window,composition,artwork,mirror}.log`, `/private/tmp/bopify-refinement-native.log`, `/private/tmp/bopify-refinement-visual-final.log`.
- Surface comparison: `MONOLITH_CAPTURE_SCENE=1` with `--probe surface`; exit 0. `/private/tmp/bopify-refinement-surface-scene.log`.
- Input-routing regression: empty library, center-cover edges, shortcut forwarding and moved spindle pass. `/private/tmp/bopify-refinement-empty-routing-green.log`. These direct responder calls supplement the separate native event probes.
- Library composition: production AppEnvironment with isolated services verifies read consent, shared consent ownership, write-consent recovery, no playback, teardown and fixture isolation. `/private/tmp/bopify-refinement-library-final.log`.
- Window probe also covers twenty interrupted transitions, saved-position migration, screen-bottom viewport reservation and unchanged lower-mode geometry. Mirror/Play Here and artwork interruption regressions pass.
- Visual captures cover resting/focused/queue/loading/empty/error, light/high-contrast appearance, narrow width and long metadata. Accessibility labels/actions are inspected; this is not a real VoiceOver traversal.

## Findings fixed

A fresh `gpt-6-astra` reviewer inspected the implementation read-only. All six scoped findings were fixed, including both minor findings:

- Interrupted prefix refresh retains old pages/selection until reveal (behavioral RED→GREEN).
- All-filtered pages expose explicit continuation instead of falsely declaring an empty library; no unbounded scan.
- Carousel unhandled Space/Command-arrow keys forward to transport (routing RED→GREEN).
- Geometry identity includes screen-space spindle movement, not only diameter (routing RED→GREEN).
- Visible center-cover edges belong to the center song (routing RED→GREEN).
- Retry-After begins on response receipt with a controlled clock (behavioral RED→GREEN).

After the desktop became available, actual native checks found and fixed three further issues:

- Native window shadow creates the reported hard outline: new no-shadow regression fails before the fix and passes after it; light/dark captures confirm the result.
- Queue ScrollView consumes empty-background drags: install the native drag region inside its content, with a viewport-sized minimum height. Actual composition drag now passes.
- Cleared Cover Flow can form an invalid closed range during teardown: empty-library regression reproduces the crash; guard empty state and retain URI-identified track values for view children. Logic and native quit/clear checks pass.

The carousel header and queue top spacing now avoid record overlap. Cover reflections use the actual artwork. No scoped code finding was intentionally deferred.

## Remaining acceptance limits

The earlier locked-desktop blocker is resolved. Native tests above ran against the unlocked WindowServer. Earlier lock-screen failures remain invalid product evidence.

A live saved-track request via the existing auth service exits 77 because the session lacks `user-library-read`. It logs only the error category and never credentials or response bodies. The user has been asked whether to open the existing authorization flow; no OAuth flow is opened without that answer. After consent, rerun `--probe live-library`. Actual selected-track playback, seek and final audible volume remain unverified; fixture command assertions are not live Spotify results.

Real VoiceOver traversal, real system accessibility preference notifications, physical display removal and the full hide/sign-out-during-every-gesture matrix remain unverified. Injected appearance/motion settings and layout assertions do not establish those manual results. Task 7 remains incomplete until its required acceptance evidence is supplied or scope is explicitly revised.

Main has not been modified or merged by this refinement.
