# Player arrival, Explore availability, and removal of Reduce Motion

User explicitly requests: make the main player appear after setup, investigate/fix the still-failing Explore mechanic, and remove all app Reduce Motion code, tests and supporting logic. Preserve the approved visual design, Soloist-only audio and previous uncommitted work. Run only affected checks; no live playback, credential reads/resets or automatic app replacement.

- [x] Reproduce the post-handoff arrival independently of animation endpoints. Native RED `/tmp/bopify-player-arrival-red.log`: full player auto-collapses 280 ms after onboarding releases its attention while the browser is focused.
- [x] Keep the completed player visible until actual pointer/key engagement or dismissal, then restore ordinary attention behavior. Do not take keyboard focus or change the visual design. Verify post-completion visibility and release on pointer engagement/dismissal.
- [x] Remove Reduce Motion reads, alternate paths, arguments, override types, helper state, tests and unused branches across app/core source. Preserve contrast, transparency preferences, VoiceOver, focus and generic explicit animation/cadence controls. `PlayerWindowController.apply(animated:)` remains a generic initialization/geometry control; it is not an accessibility preference.
- [x] Repair Explore using genuine already-authorized library candidates when the native metadata/radio service is rate-limited, while retaining honest source labeling, radio enrichment and finite pagination. No new scopes or speculative endpoints. Independent owner: explore_recon.
- [ ] Run only affected app/core suites, source-search for remaining active Reduce Motion support, review the scoped diff, and create separately signed build 470 without launching it.

Owners: parent handles onboarding/window/presentation APIs and arrival behavior; lyrics_regression handles other UI/core motion removal, with controls_regressions covering independent Cover Flow/appearance code. Explore changes stay separate from playback/audio and onboarding changes.

Explore evidence: the pre-existing actual app diagnostic capture `/tmp/bopify-explore-current-failure.log` (not a fresh live request this turn) confirms streaming-profile429 blocks native metadata and radio requests; current feeds have no independent track candidates despite the authorized library fetch already receiving real Track metadata. A local fallback must be labeled as a library mix, not fabricated radio output.


## Verification and handoff

- Arrival regression failed before the fix and passed afterward: 33 tests across three related suites in `/tmp/bopify-player-arrival-green.log`. The final combined run also passed the unfocused arrival regression, including the 700 ms post-completion hold and release after pointer interaction.
- Explore: 59 related tests across three suites passed in `/tmp/bopify-explore-repair-green.log`. Cover Flow: 13 related tests passed in `/tmp/bopify-motion-removal-green.log`.
- The broader related native run executed 156 tests across 20 suites. Keyboard-focus assertions failed while the macOS frontmost application was `com.apple.loginwindow`; the isolated window suite reproduced the same failures. Do not weaken assertions. Pending: rerun OnboardingHandoffRenderingTests, PlayerLyricsTests and PlayerWindowControllerTests after the user unlocks the desktop. Logs: `/tmp/bopify-arrival-explore-motion-final-tests.log`, `/tmp/bopify-player-window-isolated.log`. An unlock request was sent; no response received at handoff.
- Active app/core/test/script source search found no Reduce Motion references. `git diff --check` passed. Read-only review found no blockers.
- Release build 470 (version 1.6.0) succeeded at `build/player-explore-repair-test-20261108/Build/Products/Release/Bopify.app`; `codesign --verify --deep --strict` passed. The app was not launched or installed over the running app.
- No live Spotify playback/API verification or credential access was performed. The library fallback is verified offline; service recovery and live radio availability remain unverified.


## Follow-up: completed player covered by the browser

The user reproduced the failure in signed build 470. Actual app logs show all three observed completion sequences reached `onboarding player handoff completed`; this was not another completion timer stall. The app subsequently quit normally. No credential access or live playback requests were made during investigation.

A stronger native arrival regression adds an overlapping normal-level browser-like window in front of the setup app. The original panel is floating during setup. Dropping it to normal level at handoff buries it below the covering window despite the panel remaining visible, expanded, and fully laid out. The WindowServer ordering assertion failed before the fix (`/tmp/bopify-arrival-browser-red.log`). `NSApp.orderedWindows` omits the nonactivating panel in this fixture, so the regression uses actual CG window ordering rather than that incomplete list.

The repair calls `orderFrontRegardless()` when the visible setup panel changes level during handoff, preserving browser keyboard focus and the user's normal always-on-top preference. Existing animation and design remain unchanged. The regression preserves the post-arrival attention hold and ordinary collapse/dismissal checks.

Verification: 21 tests in the three related native suites passed on the unlocked desktop (`/tmp/bopify-arrival-browser-green.log`), including the window/focus checks previously blocked by loginwindow. One selected completion rendering test also passed with external fixture-only captures (`/tmp/bopify-arrival-browser-capture-test.log`); completion, intermediate handoff, and final player PNGs were inspected at `build/test-artifacts/onboarding-composited/F1EF398F-877C-424B-B428-03A1F770E727/`. Test-fixture player resource localization is incomplete; signed app resources are included. The test was then hardened to set/restore always-on-top explicitly and assert normal window level plus retained non-key state; final focused rerun is recorded in `/tmp/bopify-arrival-browser-final.log`.

Signed Release 1.6.0 (471) built successfully and strict signature verification passed: `build/player-arrival-ordering-test-20261108/Build/Products/Release/Bopify.app`. No automatic launch or replacement. Real browser/full-screen Spotify end-to-end behavior remains for user testing; the native covering-window failure itself was reproduced and repaired.
