# Turntable motion prototype

**Goal:** Replace the rejected cartoon feedback with mechanical engagement and a selected-cover flight into the vinyl.

**Design:** The user selected the mechanical direction, correcting playback to trigger only from the selected middle cover. Side clicks continue to center. The button depresses slightly; confirmed playback changes sweep a directional reflection across the grooves while the existing motor accelerates/brakes. A middle-cover activation lifts its displayed artwork, arcs toward the spindle, rounds into a label, and reveals the vinyl over about 650 ms. Actual playback commands dispatch immediately, and the flight never permanently replaces confirmed metadata.

**Approaches:** Mechanical materials reuse Bopify's existing pressing, sheen, and motor. Optical/glass motion was considered but has a less direct relationship to the current record. The previous squash and note burst are removed.

**Architecture:** Carry source artwork and local geometry with the Cover Flow play callback. Own a single cancellable flight in RecordPlayerView above the clipping mask. Use SwiftUI animation/timeline rendering and existing vinyl materials. No new dependencies or engine changes.

**Sources:** [Apple: Designing Fluid Interfaces](https://developer.apple.com/videos/play/wwdc2018/803/), [Apple: Custom Visual Effects](https://developer.apple.com/videos/play/wwdc2024/10151/), [Google: Material Motion](https://developer.android.com/codelabs/material-motion-android).

- [x] Extend the existing native Cover Flow click test: side click selects only; centered click emits one load and one valid source payload.
- [x] Replace the burst visual test with mechanical reflection and flight frames, including reduced-motion/rest states.
- [x] Remove colored notes and squash; add the groove reflection to VinylRecordView without interfering with rotation or scrubbing.
- [x] Wire source geometry/artwork through LibraryShelf and render the flight above RecordPlayerView's mask. Cancel on hide, mode/layout/session changes and failed commands; cancel old completion on replacement. Skip travel when source artwork is unavailable.
- [x] Run targeted checks, capture/review motion frames, run the app suite, build, and request a final review. Full suite: 191 tests passed. Final targeted checks: 5 tests passed. Signed app build and diff checks passed; review found no blocking issues.

**Constraints:** Preserve the earlier menu/window/Recents changes. No audio effects, forced autoplay, artificial delay to commands, or persistent fake artwork. Reduced Motion bypasses the flight and added light motion. This is a reviewable motion prototype; final feel must be judged in motion, not only in still images.

## Staging correction

The user requires the cover to remain its source size while traveling left/up to the exact spindle, then the surrounding vinyl expands slowly. Use the real record's rotating layer for expansion, retain its rotation anchor during active loading, and remove the independent flight disc/kick. Replace the groove sweep with a separate button-contained shutter/depth transition. Keep the selected card opaque under its dimming, flatten tilted covers, and apply zIndex after all geometry/accessibility modifiers. Verify both overlapping edges at rest and during activation, fixed arrival size/position, expansion staging, native motion frames, and app tests.

Verified staged revision: 195 macOS app tests pass, signed local build and diff checks pass. The overlap regression was checked against old and corrected rendering. RecordLoadTiming holds arrival until confirmed track artwork; the selected-cover phase uses the existing rotation anchor and preserves drive across loading from active playback. Play/Pause has its own button-contained shutter animation.

## Genie-inspired continuity revision

The user now requires the complete old vinyl and old cover to remain visible behind the incoming selection. Capture appearance data before loading, keep its live rotation, and reveal the new pressing over it only after the incoming cover reaches the spindle and metadata is ready. Replace rigid translation with a brief zoom and a curved, progressively narrowing funnel. Use one small native Metal layer shader for the source-rectangle-to-spindle mapping; Inferno's fixed-corner Genie was considered but does not match this geometry. Keep playback feedback independent, center-only activation, session cancellation, and reduced motion behavior.

- [x] Verify the outgoing disc remains visible during arrival.
- [x] Implement and inspect the incoming funnel and expanding overlay over the old appearance.
- [x] Verify shader bundle/function, timing, rendering, app tests and signed build. Final verification: 196 app tests passed, signed app build/signature and diff checks passed, and native window capture confirmed the full old vinyl and old label remain beneath the incoming curved funnel.

Standalone funnel verified: the native shader compiles, explicit app/test bundle lookup succeeds, six component tests pass, and an actual window-server capture shows the curved narrowing deformation. The outgoing-appearance integration was restored after file ownership was resolved; retained artwork is released on completion, cancellation, or session reset.

## Production hardening

**Goal:** Preserve the approved visuals while fixing asynchronous playback feedback, replacement loads, visual clocks and excessive rendering updates.

**Architecture:** Keep SwiftUI keyframes, springs, TimelineView and the existing Metal shaders. Confirm state from engine events, correlate collections through the existing playback identity, and use suspending-clock instants for visual progress and completion. Keep the readiness watchdog on continuous time only while waiting.

**Constraints:** Continue the existing user-authorized workspace without disturbing earlier changes. No new dependency, Rust/FFI protocol change or visual redesign. Local commit on main was authorized after verification; publication remains outside scope. Playback state remains authoritative; artwork session resets and hidden views release transition state.

**Review focus:** Repeated input before confirmation; repeated identical failures; replacing a partially revealed song; late or unrelated metadata; timer cancellation/recovery; resizing and rotation continuity; steady waiting and hidden rendering cost.

1. [x] Playback: add failing delayed-confirmation and repeated-toggle tests in PlayerModelTests/native transport tests. Separate confirmed icon keyframes from immediate press feedback and coalesce pending playback intent. Verify package playback tests and native transport frames.
2. [x] Clock: migrate RecordLoadTiming and ArtworkMorphState plus their callers to SuspendingClock.Instant/Duration; use matching sleep clocks and scope the readiness timeout to unconfirmed loads. Verify pure timing boundaries, late readiness and existing morph/feedback tests.
3. [x] Handoff: add failing A→B→C, repeated-failure and collection-identity native tests. Select a current displayed baseline on replacement, observe failure occurrences rather than message text, and require matching post-launch playback identity for collections. Verify native old/new artwork samples and stale-event cancellation.
4. [x] Rendering: compare stable-content rotation against the current timeline scope in the same native harness. Narrow invalidation only where measurements support it, stop invisible incoming work, and keep playback controls outside the transition clock. Verify bitmap continuity, native GPU appearance and before/after CPU measurements.
5. [x] Integration: run the complete package/app suites, signed app build, signature/diff checks and fresh code review; reopen the verified test app. Record performance limits explicitly, including optimized-build follow-up if it cannot be measured.

**Decisions:** Replacement launches settle the already-revealed current record as their baseline; covers abandoned before arrival keep the prior record. Collection confirmation uses a fresh playback revision plus existing matching context/track identity, avoiding a Rust/FFI protocol change. Exact command IDs are unavailable in the existing wire contract.

**Progress:** Investigation evidence is archived in `/tmp/bopify-deep-audit`; implementation starts with playback regression tests. Existing baseline: 199 app tests passed before hardening. The prior 22 characterization tests confirm current defects rather than their correction.

Hardening verification so far: PlayerModelTests 38 passed (three new failures reproduced before correction); 16 native tests in five suites passed after confirmed-state feedback, replacement/error/context ownership and suspending-clock changes. The late-readiness timer now cancels on readiness. SwiftUI rendering and lifecycle expressions are separated to satisfy type checking. First rotation-wrapper experiment did not improve CPU; no such optimization has been shipped.

Review: fresh review found a late session-loss error hidden by obsolete intent ownership; a gated regression reproduced it, and session-loss errors now reach the existing epoch/generation recovery fence. Full package suite: 460 passed. The readiness task also guards readiness before sleeping. Native suite: 206 passed before that final recovery correction. Rendering experiments showed minimal native square rotation incurs the same high XCTest CPU cost as vinyl, so those percentages cannot establish Bopify-specific shipping cost; standalone validation is in progress.

Final review correction verified: the gated late-session-loss test failed before correction; the engine-session error now propagates regardless of obsolete UI intent while epoch/generation ownership remains intact. Full package suite now 460 tests passed. Optimized XCTest controls showed a plain rotating square at the same CPU level as the full vinyl; those numbers are unsuitable as shipping performance claims. No wrapper, artwork-timeline removal or rasterization experiment was adopted.

Standalone optimized renderer results (M4 Pro,2x): steady vinyl0.37–2.10% of one core; repeated handoff4.48%; waiting3.30%; square control1.33–1.36%. These short component measurements replace the misleading XCTest CPU attribution and are not whole-app power guarantees. The approved renderer/shaders remain; only duplicate incoming updates and outgoing/control placement changed. Temporary probes were archived outside the repository. Final native regression/build/signature checks are pending.

Final signed Debug app build and strict signature verification passed. Final full native run executed206 tests but had24 issues in desktop focus/accessibility checks after macOS locked (confirmed screenLocked=1 and loginwindow shield at level2001); final window capture also blocked. Earlier full206 tests passed before lock; latest core460 tests pass. Waiting for user to unlock to repeat full native focus/capture checks and reopen the build.

Checkpoint: latest 16 motion-specific native tests passed after the reviewed fixes, even while the screen was locked. Signed test app ready at `/tmp/bopify-genie-build/Build/Products/Debug/Bopify.app`; strict codesign verification passed. Remaining work depends only on an unlocked desktop: repeat full206 native focus/accessibility checks, capture the native GPU handoff, and reopen the verified app. User has been asked asynchronously to unlock; no permission or design approval is otherwise pending.

Completed after desktop unlock: full native suite206/206 passed in29 suites (66.183s), including all previously blocked focus/accessibility checks. Native window-server capture verified the approved colored vinyl and retained old artwork beneath the Genie. Strict signature verification and diff checks passed. Temporary investigation harnesses and the standalone benchmark were removed; permanent regression tests and evidence logs remain. No commit or publication performed.

Verified test app opened after final checks (pid34695); it was already current, so no running instance was restarted. The one-off reopening script was removed. Workspace changes remain uncommitted, including unrelated user-owned edits that must be excluded from any future commit.

Integration authorization: the user requested merging into main and committing. The workspace is already on main, so the tested changes will be committed directly; the unrelated user-owned AGENTS.md edit and output image/preview artifacts remain unstaged.
