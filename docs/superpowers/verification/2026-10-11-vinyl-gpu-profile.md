# Optimized vinyl GPU profiling follow-up

Date: 2026-10-11. Verification follows the local feature merge into main.

Three matched optimized before/after pairs were recorded natively. App-to-frame correlation now identifies GPU intervals for shared compositor frames containing the player's updates. **This resolves the earlier lack of frame correlation, but does not isolate record or shader GPU cost. Hitches occurred in both variants; there is no general no-regression verdict.**

## Conditions and build

Mac mini M4 Pro, 16 GPU cores, 48 GB; macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Apple Swift 6.4. Before: `9a1ba22b2a848173acc415be866ba568e3ae6859`, with the completed motor before the pressing/sheens change. After: merged `9bb79967ddbff26037a6e4a78df0fcc1673bb14f`, including the reviewed opaque backing. Package sources do not differ between those revisions.

Both fixture binaries compile with `swiftc -O -g -D DEBUG`. They link identical Swift package objects built with `SWIFT_OPTIMIZATION_LEVEL=-O` and `SWIFT_COMPILATION_MODE=wholemodule`; compiler invocations were inspected for `-O` and `DEBUG`. Debug retains the native preview event entry point omitted from Release packages. This is **optimized Debug fixture evidence**, not a production Release session. The separate Release app build also passed, but it was not the measured executable.

The production expanded scene uses a 182 pt record over PlayerSurface/Liquid Glass, dark appearance, 2× scale, sample `spotify:track:preview1`, and steady playback. Every readiness log confirms window frame `(80,80,484,360)`, physical display ID 3 (3840×2160), and nominal thermal state at startup. [Before scene](assets/vinyl-gpu-2026-10-11/before-scene.png) and [after scene](assets/vinyl-gpu-2026-10-11/after-scene.png) were captured and inspected. The label, player/library content and geometry match; the flat record/reflection becomes coloured marble with the fixed sheen. Artwork is supplied by the preview environment; no Spotify session runs.

Capture order: after 1, before 1, after 2, before 2, after 3, before 3. Each Animation Hitches recording targets all processes for 12 seconds. Each export finishes before the next recording starts. Analysis uses interval starts in `[2,12)` seconds. There is no ambient counter, `MONOLITH_MEASURE` or per-frame logging. Other desktop work remains present, including an unrelated probe that was left untouched.

## Attribution and results

Resolve each XML reference, select `hitches-updates` with the launched PID and `containment-level == 0`, deduplicate `(display, swap-id, surface-id)`, and join top-level `hitches-gpu`/`hitches-renders` on that key. Both update and joined interval starts must lie in the analysis window. Display metadata maps the fixture's physical ID 3 to `Display 3` in every capture. The comparison below uses that display only. Secondary-display intervals are retained as diagnostics in the per-run JSON; mixing both displays would distort the comparison.

| Pair | Variant | Linked GPU frames | Mean ms | Median ms | p95 ms | Max ms | Reported app hitches |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | Before | 596 | 2.347 | 2.190 | 2.894 | 3.917 | 0 |
| 1 | After | 598 | 2.443 | 2.305 | 2.962 | 3.051 | 0 |
| 2 | Before | 417 | 2.093 | 2.170 | 3.117 | 3.429 | 52 |
| 2 | After | 161 | 2.277 | 2.348 | 3.063 | 3.621 | 137 |
| 3 | Before | 431 | 2.638 | 2.492 | 3.251 | 3.964 | 37 |
| 3 | After | 478 | 2.735 | 2.577 | 3.389 | 3.935 | 11 |

Paired shared-frame mean differences, after minus before: **+0.096 ms, +0.184 ms, +0.096 ms**. These are measured scene-level differences, not shader self-time. Unequal linked-frame counts and the variation between repeats prevent a stable performance-parity claim. The observed GPU duration alone does not establish the cause of a hitch or include every possible queueing delay.

The first pair has zero reported app hitches. Pair 2 has 52 before and 137 after; their total hitch durations are 866.714 ms and 2283.459 ms. All measured app hitches are on Display 3. Instruments labels nine baseline and seven after hitches in pair 2 as potentially expensive app updates; the rest have no narrative cause. These labels do not identify the pressing shader as a cause. Hitch causes remain unresolved. No capture was discarded for having hitches.

[Machine-readable summary](assets/vinyl-gpu-2026-10-11/summary.json) includes controls, source revisions, binary/package hashes, per-pair differences and limits. Per-run JSON retains individual joined GPU/render intervals, display mappings, unmatched-key counts, hitch distributions and export hashes: [before 1](assets/vinyl-gpu-2026-10-11/before-1.json), [after 1](assets/vinyl-gpu-2026-10-11/after-1.json), [before 2](assets/vinyl-gpu-2026-10-11/before-2.json), [after 2](assets/vinyl-gpu-2026-10-11/after-2.json), [before 3](assets/vinyl-gpu-2026-10-11/before-3.json), [after 3](assets/vinyl-gpu-2026-10-11/after-3.json).

## Verification and remaining boundary

The optimized app/package build and both optimized fixture compilations exited 0. Six recordings/exports completed successfully. The saved capture helper was exercised in pairs 2 and 3. Synthetic analyzer checks passed reference resolution, top-level filtering, a one-frame join, an absent PID producing no attribution, and duplicate top-level GPU rejection. Both reproduction patches apply to pinned sources. An independent review recomputed every GPU/render frame and hitch count in all six captures, checked the summary differences and report figures, and found exact matches, with no Important/Critical defect in the helpers, evidence or protocol.

Apple describes rendering work performed outside the app process on its behalf in [Demystify and eliminate hitches in the render phase](https://developer.apple.com/videos/play/tech-talks/10857/), checked 2026-10-11. The exported tables establish an association with the app's update frames, but have no window or individual shader provenance. Shared compositor GPU duration includes other desktop composition. A static colour effect may also be cached, so steady playback does not measure first shader rendering or transition cost. **Record-only GPU timing remains unverified.**

A distinct instrumentation harness or further Instruments analysis would be needed to isolate that cost and diagnose the repeated hitches. There is no evidence here requiring an AppKit/SwiftUI architecture change. Production rendering and playback code were not edited during this follow-up. Live Spotify buffering/recovery remains outside this capture.

[Reproduction commands and temporary source patches](assets/vinyl-gpu-2026-10-11/reproduce.md), [capture helper](run-vinyl-gpu-capture.py), [analyzer](analyze-vinyl-gpu-trace.py). Raw traces and exported XML remain under `/private/tmp/bopify-vinyl-gpu-20261011`; raw trace process environments are excluded from the checked-in evidence.
