# Native mini-player verification

Checked 2026-09-24–26 on macOS 27 / Xcode 27, deployment target macOS 14. Worktree: `feat/liquid-glass-player`.

## Result

The replacement is implemented and builds. Automated boundary tests and native fixture checks pass. **Full live Spotify acceptance is not established.** The existing running app could not be controlled because System Events returned `osascript is not allowed assistive access (-1728)`. No extra permissions, credentials, or broader Spotify scopes were applied automatically.

## Verified

- Rust adapter: 28 tests pass, including bounded/cancellable metadata work, immediate transport delivery, null/destroyed FFI handles and queue wire data.
- Patched librespot connect: 16 tests and 1 documentation test pass. Exact occurrence selection preserves suffix/history, rejects stale targets, and invokes one audio load; duplicate identity and forward/backward continuity are tested.
- Swift package: all 101 tests passed (39 Playback, 12 Library, 18 Domain, 32 Auth), including domain decoding, command ordering, screen clamping, auth scope preservation/consent failure/concurrent refresh/sign-out, exact library request/error contracts, and favorite stale-response/rollback/reconciliation/cancellation cases.
- Command-line native app build passes. The only build warning is skipped App Intents metadata extraction; the Rust dependency retains an existing unfulfilled deprecated-lint expectation.
- Native StatusPanel probe passed: normal window level, movable, remains visible when a second native window gains focus; Space, plain-arrow seek and command-arrow skip callbacks; editor exclusion; Escape dismisses queue before hiding.
- Standalone `ArtworkCacheProbe.swift`: 10 concurrent consumers issue one fetch; one palette/image publication; 640 px downsampling; HTTP/decode failures remain cached; 112-entry eviction; clear/reload.
- Native previews inspected at expanded widths 390/410/430 and compact 340/380/420, long metadata, missing artwork/loading, playback error, empty and 80-entry queue, increased contrast, an increased Dynamic Type environment, and a 320×480 sign-in window. Fixed point-size macOS fonts retain their specified sizes; this is not proof of system-wide text scaling.
- Native transition frames captured at 200 ms next, another next after 200 ms, then previous and settlement; queue/expanded handoff at 250 ms and settlement. The first capture exposed duplicate artwork and an off-panel outgoing image. Replaced matched-image rendering with anchor placeholders and one persistent image overlay. The repeated capture has one moving current image, correct final artwork, and no off-panel current image.
- Improved the queue footer's opaque backing after native capture showed list text refracting through its glass. Current queue row is static accessible content, not an inert button. Short displays scroll expanded content.

## Final review and fix pass

The fresh whole-branch review found no critical or minor issues and three important findings. One fix pass addressed them:

- Progress rewind: a regression first failed for active-device loss, loading, and playback failure (display fell from about 1054 ms to the 1000 ms engine anchor). It now freezes the interpolated display position without changing authoritative engine state, then accepts subsequent position/playing events. All three cases pass.
- Stale repeat-one after explicit skip: `ConnectState` clears repeat-one during next/queue selection. The event loop now observes both repeat flags and publishes changes, including implicit clears. A publication-boundary regression first failed because that boundary was missing; it now verifies next and exact selection, retained context repeat, and no repeated unchanged notification. This is not a live Spotify observation.
- Queue scrolling: removed the redundant outer scroll wrapper in queue mode. The review's inherited-disable failure did not reproduce in two macOS 27 environment probes, so no failing-then-passing claim is made. The final native 80-row probe finds exactly one scroll container and a wheel event moves its offset from 0 to 4946 pt; row 80 is fully visible above the footer. Older macOS compatibility remains unverified.

Additional native probes passed: radial click commits one 25000 ms seek on a 100000 ms track; dragging across twelve clamps to 100000/0, and a center drag is ignored. Playback clock schedules produce one entry when hidden/stopped, 1 Hz with reduced motion, and 30 Hz for visible playback. These own-process probes do not establish accessibility or live playback acceptance.

Rust release library/header/xcframework rebuilt after the repeat fix. Final command-line `xcodebuild` exited 0 with `BUILD SUCCEEDED`; log `/private/tmp/bopify-build-favorites.log`. Header generation retained its existing unresolved `BopifyError` warnings without changing the generated header; packaging succeeded. No second review was dispatched.

## Evidence

Before: [dark audit](../specs/assets/2026-09-24-mini-player-current-dark.png), [light audit](../specs/assets/2026-09-24-mini-player-current-light.png).

After: [expanded](assets/expanded-final.png), [compact 340](assets/compact-340.png), [compact 420](assets/compact-420.png), [queue](assets/queue-final.png), [queue scrolled to row 80](assets/queue-scrolled-final.png), [missing artwork](assets/missing-artwork.png), [increased contrast](assets/increased-contrast.png), [small display](assets/small-display.png).

Motion: [handoff defect before](assets/queue-handoff-before.png), [next at 200 ms](assets/motion-01-next-200ms.png), [interrupted next](assets/motion-02-next-next-200ms.png), [settled previous](assets/motion-03-previous-settled.png), [queue midpoint after](assets/motion-04-queue-midpoint.png), [reverse midpoint after](assets/motion-06-expand-midpoint.png).

Preview title bars belong to Xcode's preview host; the production panel is borderless. Artwork is original vector fixture art, never a fallback for missing live images. `MotionProbe.swift` runs in the `PlayerPreviews.swift` Xcode snippet context. Its native view bitmap captures verify geometry but omit composited glass, so material appearance is assessed from RenderPreview captures instead.

## Remaining live/manual acceptance

- Real queue with two occurrences of one song: second-occurrence selection, suffix retention, no intermediate song, external queue changes, autoplay/end-of-track, stale clicks, shuffle/repeat preservation.
- Explicit Spotify library consent with the current first-party client, followed by contains and a user-driven save/remove round trip restoring the initial saved state. The unified endpoint's client/account compatibility and sufficiency of the two narrow library scopes remain unverified. A 403 remains an honest unavailable state.
- Live pointer scrub cancellation on track change and VoiceOver adjustment; drag across physical displays/Spaces, disconnect/restore a display, native menu focus; playback continuity while hiding.
- Reduce Motion / Reduce Transparency through actual system settings. These SwiftUI environment values are read-only in the installed SDK, so attempted preview injection was removed. Source has short-fade/opaque fallbacks and a one-second reduced-motion clock; no full native setting matrix is claimed.
- Sustained real-playback CPU/energy profiling and a normal-speed screen recording. The inspected frames prove selected transition states, not every frame or live performance.
- Increased system text settings and bright/dark desktop wallpaper behavior beyond native preview fixtures.

## Implementation rulings

1. Basic event folds moved from main Task 3 to Task 2 so Swift exhaustive switches stayed buildable. Cost: possible adjustment during command integration.
2. Visual/motion/accessibility checks for Tasks 4–8 were consolidated after composition. Cost: regressions found later; the handoff defect above demonstrates that risk.
3. Carousel interruption samples explicit curved positions using a transition clock and damped timing. Cost: custom timing needs native interruption checks.
4. Native handoff evidence required replacing matched-geometry rendering with one image and anchor geometry. Cost: preference interpolation must be checked during mode changes.
5. Treat the non-reproduced nested-scroll finding as compatibility hardening, remove the redundant wrapper, and validate native scrolling without claiming a RED result. Cost: older macOS scrolling remains unverified.
6. Accept the reviewer's inability to judge live duplicate selection/autoplay/library grants as an explicit acceptance gap, not proof of correctness; local contracts remain tested and unavailable errors visible. Cost: account/provider incompatibilities may still emerge in live use.
7. Leave VoiceOver, physical display removal, actual system accessibility settings, and sustained energy profiling for manual acceptance because current automation lacks access. Cost: native accessibility, display, and performance regressions may remain.
8. Leave the pre-existing absence of in-app reactivation after another device takes playback unchanged; this redesign does not introduce it. Cost: users must transfer playback back through Spotify before controls resume.

Deferred minor findings: none. The branch is implemented and locally verified; the original brief is not declared fully accepted until the live/manual checks above are completed.

Auth concurrent-refresh/sign-out regressions were added after the auth implementation and passed immediately; they are regression coverage, not an observed failing-then-passing test sequence. Scope/consent, HTTP boundary, favorite model and frame-math tests were observed failing before implementation.

## Sources checked

- [Apple — performDrag(with:)](https://developer.apple.com/documentation/appkit/nswindow/performdrag%28with%3A%29): native window drag handoff.
- [Apple — matchedGeometryEffect](https://developer.apple.com/documentation/swiftui/view/matchedgeometryeffect%28id%3Ain%3Aproperties%3Aanchor%3Aissource%3A%29): geometry matching does not coordinate rendering of both views.
- [Spotify — Check User's Saved Items](https://developer.spotify.com/documentation/web-api/reference/check-library-contains), [Save Items](https://developer.spotify.com/documentation/web-api/reference/save-library-items), [Remove Items](https://developer.spotify.com/documentation/web-api/reference/remove-library-items): URI query, Boolean-array read, empty successful mutations; checked 2026-09-25.
