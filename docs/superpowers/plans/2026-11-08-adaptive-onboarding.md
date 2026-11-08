# Adaptive onboarding implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the independent sizing and motion units; root integrates the view measurement and verifies the final native flow.

**Goal:** Apply the approved content-sized windows and physical vinyl motion through one shared setup presentation, reusing saved setup for returning users.

**Architecture:** Measure the natural form inside its existing native hosting boundary. StartupWindowLayout owns the target height, stable screen-constrained artwork scale and deferred contraction; StatusItemController alone applies startup native geometry. PlayerWindowController retains the final player handoff. Decorative motion stays outside form sizing.

**Tech Stack:** SwiftUI, AppKit, Observation, existing native Swift Testing fixtures. No new dependencies.

**Spec:** docs/superpowers/specs/2026-11-08-adaptive-onboarding-proposal.md (approved by “follow recommendation”).

## Global constraints

- Preserve Aurora, original artwork, centered composition, native glass/keyboard/accessibility and no-scroll forms.
- Keep normal returning launches direct to the player. Share setup visuals for first-time, repair and reopened setup; do not repeat valid grants/key entry or initiate browser consent on launch.
- No actual keys/tokens read, live playback/transfer commands or automatic relaunch interrupting current music.
- Run only affected tests; no full app/package/Rust suites.
- Root owns AppEnvironment’s startupWindow property, PlayerRootView and StartupView. Sizing owner owns new StartupWindowLayout + tests and StatusItemController. Motion owner owns SignInRecordView + motion helper/tests. Coordinate Xcode runs.

## Review focus

- A shorter step must change native window height without changing artwork size or moving its top edge.
- Old geometry callbacks, outgoing fades and cancelled contractions must never resize the next step or player handoff.
- Errors, registration help, short screens and native editor focus must remain fully visible without scrolling.
- Decorative motion must pause while hidden, honor Reduce Motion, preserve angle continuity and not change layout measurements.
- Returning restoration must reuse valid setup without extra consent or completion on ordinary launches; actual readiness still governs setup handoff.

## Task 1 — startup sizing

- [x] Add focused red tests for growth, deferred shrink/cancellation, invalid measurements, stable screen-based scale, screen clamping and native same-mode height changes.
- [x] Add StartupWindowLayout with isManaged, recordScale and height; useScreen(height:), measure(contentHeight:reduceMotion:) and cancelPendingResize(). Include existing chrome/record metrics, finite-value guards and a narrow injected sleep for deterministic contraction tests.
- [x] Grow immediately, defer contraction until outgoing content fades (330ms normal/180ms reduced), and reject superseded timers. Keep artwork scale independent of step height.
- [x] Remove mode-only/fixed680 geometry restrictions; StatusItemController observes startup layout and applies content height around the existing top edge. Re-evaluate screen constraints on screen changes. Keep player attachment/anchor logic intact.

## Task 2 — record motion

- [x] Add meaningful continuity/spin-up/settle/visibility/reduced-motion tests where motion math is introduced; prove regression before implementation.
- [x] Apply the approved subtle groove reflection, shallow pointer lean/idle poise, progressive work spin and upright settle. Keep art and frame stable; do not add controls or change visual assets.
- [x] Pause decorative updates when hidden/reduced motion. Retain side flip, sleeve masking, failure pose and actual record-frame callback.

## Task 3 — root integration and shared journey

- [x] Add the startupWindow model to AppEnvironment; measure vertically natural content before filling frame inside the existing NSHostingView boundary.
- [x] Reject callbacks for old step/scene identities and during player handoff. Hide expanding content until its target viewport has room, then reveal gently. Cancel pending size work when leaving setup.
- [x] Pass managed screen-constrained record scale to StartupView; retain responsive standalone previews. Remove the fixed readable-form reservation from managed sizing only.
- [x] Verify first-time/repair/reopened setup uses shared components and saved state; retain no-browser-on-launch and automatic actual-ready completion coverage. Do not alter auth/account proof semantics.
- [ ] Finish unlocked-screen native layout, keyboard/accessibility and composited capture checks. Model/motion/geometry/presentation/auth checks and the focused review are complete.
- [x] Build a separate signed arm64 Release app and verify its signature. Keep it unlaunched; final native verification still requires the unlocked Mac.

## Checkpoint — implementation built, native screen verification blocked

Approved policy: shared first-time/repair/reopened setup with saved inputs reused; valid normal launches go directly to the player. No auth semantics or playback commands changed. All application changes are still uncommitted pending the final native verification.

Implemented:

- StartupWindowLayout owns screen-based artwork scale, measured-content height, 330/180ms deferred contraction and cancellation/generation guards. Native targets round upward to whole points, and fractional screen limits round downward, matching AppKit geometry.
- StatusItemController responds to height changes even in the same presentation mode, preserving width/top edge and screen clamping. PlayerWindowController keeps ownership of the final handoff.
- Root measures the real vertically natural form before its filling frame. Primitive sendable measurement values carry a frozen step/scene tag; stale/handed-off/quit callbacks are rejected. New scenes reveal when there is room; existing input stays visible during inline validation growth. Brief library/completion acknowledgements coalesce sizing work.
- Managed artwork size is independent of step height; standalone previews remain responsive. The approved groove reflection, shallow lean/poise, spin-up and 200 ms upright completion settle retain fixed layout frames and pause for hidden/reduced motion.
- A focused reviewer found one delayed-measurement visibility race. It was fixed by reading the latest viewport state and deriving visibility from current room; the reviewer confirmed the fix. No other material findings.

Verification:

- Sizing RED: 10 tests / 15 expected issues in `/tmp/bopify-adaptive-sizing-red.log`.
- Motion RED: 5 tests / 10 expected issues in `/tmp/bopify-adaptive-motion-red.log`.
- Initial affected run: 61 tests, 8 issues in `/tmp/bopify-adaptive-green.log`. Five issues were native capture/key focus blocked by macOS screen-lock shield 2001; one test still assumed a fixed minimum 560 pt and now checks the dynamic target; two native geometry assertions exposed a 0.88 pt AppKit rounding mismatch, fixed and strengthened to exact equality.
- Final independent run: **42 tests in 8 suites passed**, `/tmp/bopify-adaptive-logic-final.log`. Includes 9 sizing regressions, 5 motion cases, actual hidden-window sizing, presentation/cancellation, original record layout, automatic setup completion, saved restoration/no-launch-consent and player anchoring. No full suites ran.
- Build-for-testing succeeded: `/tmp/bopify-adaptive-final-build.log`.
- Signed arm64 Release build succeeded and strict deep signature verification passed: `build/onboarding-adaptive-release-20261108/Build/Products/Release/Bopify.app`, `/tmp/bopify-adaptive-release.log`. It was not launched or used to replace any running build.

Remaining work:

1. The Mac was confirmed locked through the read-only CGSession flag. The user has been asked to unlock it. Do not disable/bypass the lock, raise fixtures above its shield, or weaken focus/capture assertions.
2. Once unlocked, start `swift scripts/capture-native-onboarding.swift <new UUID> 7` , then run the already-built selected native suites with matching `BOPIFY_NATIVE_CAPTURE_TOKEN` and `TEST_RUNNER_BOPIFY_NATIVE_CAPTURE_TOKEN`: OnboardingHandoffRenderingTests, SoloistSetupRenderingTests and StartupShellTests. No need to repeat the 42 passing independent checks unless source changes.
3. Inspect library/help growth, fixed vinyl geometry, shrinking, focus/draft persistence, expansion reveal and completion handoff. The first locked capture attempt produced no valid screenshots; do not treat it as visual verification.
4. Resolve any actual native issues, rerun only affected checks, update this note, review final diff and make the local Conventional Commit. Reveal the existing signed artifact if unchanged; rebuild/reverify if application source changes.
