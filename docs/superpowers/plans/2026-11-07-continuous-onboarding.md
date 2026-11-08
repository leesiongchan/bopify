# Continuous Onboarding Implementation Plan

**Goal:** Apply the user-approved continuous onboarding demo, including safe automatic discovery recovery and the completion-to-player handoff.

**Spec:** `docs/superpowers/specs/2026-11-07-continuous-onboarding-proposal.md`, approved by “perfect”. Visual reference: `build/onboarding-continuous-demo/index.html`.

**Architecture:** Keep actual playback/auth ownership unchanged. Presentation-only state coordinates library confirmation, completion and handoff. Keep the startup record outside the native scrolling form. Initialize the existing window animation from the visible startup record, and retain the outgoing surface at its original size and screen position during the fade. Discovery monitoring retries failed browsers and reports recovery opportunities; AppEnvironment can retry only failed discovery setup, with bounded attempts and a stable controller-owned device name.

## Constraints

- Preserve original Aurora/record/centered layout and the current player design; implement the approved copy/controls/palette.
- No form-sized tint rectangle, no unmasked corners, no extra completion click, no unsolicited playback.
- Remove routine Cancel setup / Library access / Retry discovery and the duplicate visual key label. Keep accessibility names and lifecycle cancellation.
- Reuse saved key/grants; keep account/device proof, generation guards and joined shutdowns.
- Do not restart healthy Soloist on network or activation notifications.
- Respect Reduce Motion, Reduce Transparency and Increase Contrast.
- Run only directly related suites/methods. No full app/package/Rust suites or repeated live installation checks.

## Task 1 — approved surface and controls

Owner files: StartupInput, SignInView, LibraryAuthorizationSetupView, PlaybackOnboardingView, Localizable, and SoloistSetupRenderingTests. Root owns StartupView/StartupStep/PlayerRootView and their transition integration.

- [x] Add a corner-alpha regression against existing StartupSurface; observe failure before fixing its clipping.
- [x] Apply one full-viewport clipped Aurora with subtle continuous depth; remove form-relative tint; add semantic color hierarchy and regular glass actions.
- [x] Apply approved concise copy, progressive registration help, and native secure field without a duplicate visual label. Remove routine controls, preserve accessible purpose/Return/Tab/focus and saved setup reuse.
- [x] Playback subphase transitions use stable scene identity (no identity changes for download fractions or entry errors). Remove view-owned immediate onboarding dismissal.
- [x] Handle `LibrarySetupStatus.connected` as brief acknowledgement; completion content is root-owned. Integrate `discovery.start(onRecovery:)` while pairing or failed discovery; callback calls `environment.resumeSoloistDiscovery()`.

## Task 2 — automatic discovery lifecycle

Owner files: SoloistDiscovery, SoloistPlaybackController, SoloistDiscoveryTests and SoloistSetupTests. No AppEnvironment or view edits by this owner.

- [x] Add meaningful failed-browser/backoff/stop/late-callback and stable-name regressions; observe failures first.
- [x] Preserve status classification. Retry failed transient browser instances with bounded backoff, without relaunching Soloist; stop retries/monitors on stop and ignore stale generations.
- [x] Expose `start(onRecovery: @escaping @MainActor () -> Void = {})`; report browser recovery, network restoration and app activation opportunities. Do not repeatedly prompt denied permission; return from Settings is a recovery opportunity.
- [x] Add stable `name: String` to SoloistLaunchRequest, generated once per controller lifetime; production start uses it for every owned relaunch. Existing injected start closures remain compatible.
- [x] Run only the related discovery/setup suites after coordination with root's Xcode tests.

## Task 3 — presentation and handoff (root)

Owner files: new OnboardingPresentation + tests, AppEnvironment, StartupView, SignInRecordView, PlayerRootView, RecordPlayerView, StatusItemController and targeted window tests.

- [x] Add presentation-state regressions for library acknowledgement, readiness-only completion, coalescing, interruption, cancellation and generation guards.
- [x] `OnboardingPresentation` owns inactive/libraryConnected/completing/handoff phases, armed only by actual initial setup/repair. Library confirmation serializes with pending completion; returning launches do not replay celebration.
- [x] Add `LibrarySetupStatus.connected` and `StartupStep.completion`. Root supplies Ready to play content and a brief check. Root exclusively requests/finishes presentation; playback view no longer dismisses itself.
- [x] Move native scrolling to form content, keep header/record in the root SwiftUI hierarchy, and coordinate record geometry into the existing player. Preserve small-window scroll and native AX.
- [x] Prevent first-player initialization from snapping to the menu-bar-sized frame during an actual onboarding handoff; use the existing animated window controller. Reduced motion uses fades/instant geometry, not spinning or spatial morphs.
- [x] Add bounded `resumeSoloistDiscovery()` for actual failed-discovery phases only; recovery events never stop healthy audio. Remove unused old manual pairing-retry UI API when consumers are gone. Cancel presentation/recovery work on sign-out/quit/superseding actions.
- [x] Run only affected presentation/auth/window/native rendering/discovery/setup suites. Inspect native composited captures if available; record any capture permission limitation honestly.

## Integration and final verification

- [x] One fresh focused final review and one material fix pass if necessary.
- [x] Signed arm64 Release build in a new artifact directory, then strict signature verification. No automatic relaunch or real Spotify playback.
- [x] Record actual results/live limits and commit only this task's files locally.

Interfaces: UI consumes connected/completion enum cases supplied by root; discovery exposes the callback API consumed by UI; root handles that callback and presentation state. Independent owners do not edit one another's files. Coordinate Xcode runs so failure diagnosis is not polluted by incomplete integration.

Ruling: Keep the persistent record outside the native form scroll host and use one owner for the handoff geometry: PlayerWindowController. Shared matched geometry competed with the source scale/tilt/lift and the native window animation, producing an offset duplicate in the first composited capture. Seed the existing player offset/diameter from the source instead. Small-window forms scroll beneath the fixed record/header, as shown in the approved demo.

Progress/results are recorded below as work completes.

## Implementation results — 2026-11-07

- Implemented the approved surface, copy, controls, library acknowledgement and readiness-driven automatic handoff. No new dependencies or playback commands.
- Native field cells did not inherit SwiftUI accessibility names/identifiers. A scoped metadata-only AppKit bridge names the existing editable field and cell; secure entry, Tab, Return and focus remain native. Registration disclosure metadata no longer overrides its expanded children.
- Failed browsers retry with bounded backoff. Recovery preserves the controller-owned pairing name, and only failed discovery setup can relaunch an owned child. Initial actual browser readiness is separately observable; healthy pairing is never restarted for it.
- The final focused run passed **78 tests in 9 related suites**, including presentation cancellation/reduced motion, discovery lifecycle, failed setup recovery, authorization cancellation, corner clipping, native input/accessibility and window anchoring. No full app/package/Rust suite ran.
- Two native handoff tests passed again with capture moved to the fade midpoint. Same panel/window number and idle playback are retained; final record anchor stays within 2 pt of the settled source.
- Composited captures: `build/test-artifacts/onboarding-composited/296D2AB4-A25E-4C3B-9EAC-EFBE880498D0/{completion,handoff,player}.png`; key entry: `FCAC8472-53D9-4826-AD1E-6A4875775BFD/key-entry.png`. Both startup captures have alpha 0 at all four outer corners.
- Signed arm64 Release artifact: `build/continuous-onboarding-release-20261107/Build/Products/Release/Bopify.app`. Strict signature verification passed with hardened runtime and team `6RS6K2N242`.
- Native fixtures are offline and use fake providers/keys. They establish UI/lifecycle behavior, not live Spotify account/device proof. The test host lacks the app's default Metal shader library; the signed app includes `Resources/default.metallib`. Real account pairing and listening remain a user test. No running player was relaunched.

Evidence logs: `/tmp/bopify-continuous-final.log`, `/tmp/bopify-continuous-midpoint.log`, `/tmp/bopify-continuous-release-final.log`.
