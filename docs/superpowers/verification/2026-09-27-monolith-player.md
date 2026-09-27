# Monolith native verification

Date: 2026-09-27. Branch: `feat/monolith`. Baseline: `b49d6cb`.

The listening player now rests as a 118 pt vinyl record and reveals a single glass sleeve with a 182 pt record. Hover does not activate Bopify; clicking or keyboard focus retains the sleeve. Queue expansion preserves the record and transport positions. Playback, authentication, and the Rust bridge retain their existing boundaries.

Automated native checks are recorded below. Physical assistive-technology and display checks remain open; this report does not declare all acceptance criteria complete.

## Visual comparison

[Before: previous player](assets/glass-interactions/before.png) → [resting record](assets/monolith/player-resting.png), [focused sleeve](assets/monolith/player-focused.png), [queue](assets/monolith/player-queue.png).

The former vertical player and adjacent album covers are replaced by one record and a horizontal sleeve. The [approved study](../specs/assets/2026-09-26-monolith-study.html) supplies the proportions and choreography. Native differences are deliberate: system typography and slider rendering, native regular Liquid Glass, and 12 pt shadow allowance around the approximately 460 × 240 pt focused composition. The settled native frame is 484 × 264 pt, or 484 × 424 pt with the queue. Track artwork stays upright while the graphite reflection moves.

Additional captures: [light appearance](assets/monolith/player-light.png), [native high-contrast appearance request](assets/monolith/player-high-contrast.png), [320 × 480 available space with long metadata and missing artwork](assets/monolith/player-narrow-long-metadata.png), [queue rejection](assets/monolith/player-queue-rejected.png), [interrupted track transition](assets/monolith/record-interrupted.png), [Reduced Motion](assets/monolith/record-reduced-motion.png).

Captures use ScreenCaptureKit on the probe's own native window. Transparent pixels may appear black in image viewers; these are not full-desktop wallpaper composites. The fixture changes the backdrop and native appearance, but the resulting captures do not establish every wallpaper/material combination. The two-line queue notice fits after reducing stack spacing. Longer notices remain reachable by scrolling the controls region; they do not overlap transport controls.

## Commands and results

Run from the Monolith worktree. Probes compile production views/controllers into a separate app with a stub playback engine and library service; they never start Spotify.

```sh
swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-monolith-tests
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-monolith-build build
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-monolith-build --output /private/tmp/bopify-monolith-window-final --probe window
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-monolith-build --output /private/tmp/bopify-monolith-visual-final --probe visual
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-monolith-build --output /private/tmp/bopify-monolith-artwork-final --probe artwork
git diff --check
```

- Swift package suite: exit 0, 135 tests (71 playback, 12 library, 20 domain, 32 auth).
- App build: exit 0.
- Native window probe: exit 0, `MONOLITH WINDOW PASS`.
- Native visual probe: exit 0, `MONOLITH VISUAL PASS`.
- Artwork probe: exit 0, all assertions passed.

## Evidence

The window probe uses a separate controlled background process and actual WindowServer pointer events. It verifies inactive hover, no focus theft, native center-click focus, drag slop, drag release, persisted placement, background clicks through the resting corner, and tight bounds after collapse. It also verifies legacy midpoint migration, invalid saved-center fallback, stable spindle coordinates at transition allocation/settling, and rejection of 20 stale animation completions.

A native regression first failed when dragging interrupted queue recession: the envelope never tightened. Reapplying the last requested geometry after drag release fixes it, and the probe passes. Another regression first failed when the record's accessibility action synthesized focus without making the panel key. The action now asks the native controller to focus the panel; the native accessibility action and subsequent focus-loss/collapse assertion pass.

The integrated visual probe verifies paused startup restoration at 1545 ms, remote/error classification, and no playback command on reveal/focus/center click. It checks quick-ring-click suppression, one committed seek after the 250 ms hold, cancellation on capability loss/occurrence replacement/hide, exact queue occurrence confirmation, tight native bounds after queue closure, and protection against a late result closing a reopened queue. Native accessibility-tree inspection shows only the record button at rest and transport controls when revealed.

Artwork checks cover same-cover duplicate occurrences, missing/late artwork, interruption continuity, and 100 retargets with no more than two live artwork frames. Captures sample next/previous interruption and Reduced Motion. These establish state/geometry behavior and sampled appearance, not a frame-by-frame video assessment of every simultaneous input combination.

Temporary fixture-only instrumentation measures the production reflection TimelineView. Run with `--probe visual --measure-ambient`. After settling, a 300 ms sample produced 10 updates while playing and 0 while paused, hidden, or using Reduced Motion. The runner compiles a temporary instrumented copy and removes it; production rendering contains no per-frame logging/counter.

## Acceptance checks still requiring a live session

- VoiceOver spoken output and focus traversal across every control; native AX tree/action checks are narrower evidence.
- Full keyboard traversal and native slider arrow handling; favorite popover → queue → panel Escape ordering; volume drag outside the window and overlapping popover/seek holds. The pure attention tests cover independent holds and clearing on hide/reset, but do not prove every native control lifecycle.
- Sign-out during a native gesture, live keep-on-top behavior, and external-display disconnection. Negative-origin and constrained geometry are tested without disconnecting hardware.
- Live Reduce Transparency/Reduce Motion/Increase Contrast preference notifications and material appearance over multiple actual wallpapers. The Reduced Motion fixture injects the preference. Requesting a high-contrast NSAppearance did not visibly select the opaque SwiftUI fallback; that capture is not evidence that the system contrast setting works. SwiftUI's contrast environment value is read-only, so the attempted direct fixture injection could not compile and was removed.
- Continuous video inspection of concurrent reveal/recede, track replacement, and screen-edge relocation. Current evidence consists of native geometry assertions and sampled captures.

## Execution decisions

- Legacy artwork fixture callers retain default occurrence arguments. Cost: a caller that omits identity cannot demonstrate duplicate-occurrence animation.
- The Reduced Motion fixture supplies an explicit override because the native environment value is read-only. Cost: this does not verify live system-preference notification delivery.
- Superseded carousel/compact preview fixtures were removed with their production views. Historical glass probe sources and reports remain; `run-monolith-probe.py` is the current runner. Cost: old glass probe scripts require migration to run on this branch.
- The window controller accepts an optional visible-frame boundary for the constrained native fixture; production uses the current screen. Cost: injected bounds do not establish physical monitor-disconnection behavior.
