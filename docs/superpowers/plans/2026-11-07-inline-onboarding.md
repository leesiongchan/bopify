# Unified Onboarding Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement the following tasks. The user authorized implementation of this redesign on 2026-11-07; no further design approval is pending.

**Goal:** Make sign-in, library registration/consent, and automatic Soloist setup one continuous main-window experience.

**Architecture:** Reuse StartupView, the animated record, and the existing authorization/controller lifecycle. A shared AppEnvironment onboarding route controls content and window geometry; completed steps are skipped, and Setup reopens the same surface for editing. Soloist is the required default, with an explicit per-session librespot recovery action.

**Tech Stack:** SwiftUI, AppKit, Swift Testing; existing Spotify OAuth and Soloist controller.

**Spec:** [Approved unified onboarding design](../specs/2026-11-07-unified-onboarding-design.md). Remove separate Playback Engine and Library Access windows, integrate both into onboarding, preserve seamless default Soloist installation and recovery.

## Global Constraints

- Preserve credentials, generation guards, cancellation, appearance and record animations.
- Never expose keys in logs or screenshots; secure entry remains secure.
- Limited Spotify companion services must not block local Soloist playback.
- Keep form identity stable during progress updates; use one shared geometry predicate.
- This UI task leaves shared playback process changes to the companion startup-recovery work described in the spec.

## Review Focus

- Existing playback must survive opening and cancelling Setup.
- Missing Client ID stays inline and invalid values cannot submit.
- Saved key skips entry and starts Soloist automatically.
- Failed startup remains actionable even if fallback retains track metadata.
- Explicit session fallback completes onboarding without changing the next-launch default.

## Tasks and progress

- [x] Inspect authoritative auth lifecycle, setup windows, startup animation, menu and tests.
- [x] Add regression coverage for the third stage and shared setup geometry.
- [x] Observe regression failure, then implement shared route and inline forms.
- [x] Remove obsolete controllers/views/menu entries and update native presentation coverage.
- [x] Run focused app tests, app build, accessibility rendering checks, and final diff review.

No live credentials or audio are needed for fixture-based UI checks. Real Soloist startup verification is handled by the parallel process-lifecycle task.

## Implementation evidence

The shared route now drives PlayerRootView, player mode, and native panel geometry. Missing keys wait inline before audio starts; saved keys resume automatically, and explicit session fallback preserves next-launch Soloist preference. Completed setup can reopen and close without stopping playback. Both standalone setup windows and their old views/menu entries were removed.

Native regression tests isolated missing semantic controls to SwiftUI ScrollView: direct startup content, glass surface, Aurora, and drag header all exposed controls, while scroll children/contents/navigation attributes did not. The startup surface now uses a native transparent NSScrollView with one stable NSHostingView, intrinsic content height, viewport-pinned width, and complete environment forwarding. Full-root secure-key editing, library validation, focus preservation, panel expansion/return, and same-surface navigation pass. Small-window registration verifies actual document overflow and scrolling to the final action.

An initial complete run executed 285 tests and failed only the root accessibility regression; that regression passes after the native scroll correction. Final complete suite passed **286 tests in 42 suites** in 61.828 seconds, Xcode exit 0 (`/tmp/bopify-onboarding-final-all.log`). A final focused native run passed both full-root tests after changing key submission to the field editor’s Return command (`insertNewline`), Xcode exit 0 (`/tmp/bopify-onboarding-return.log`). Both diff whitespace validation and localization JSON duplicate-key validation pass. Root integration owns the final signed Release build and runtime diagnostic evidence.

Native bitmap captures omit GPU blur/transforms and use the test runner as Bundle.main; they establish content placement and controls but do not reproduce final composited appearance. Live Spotify account authorization, pairing, and audible playback are not verified by fixture tests.

## Startup recovery and signed build evidence

- Reproduced the startup blocker from process metadata and the available session lock: Soloist was orphaned under PID 1. Recovery now checks the installed and running publisher, current user, process birth identity, exact private session arguments, and installation location before requesting termination under the application lock. Busy or unproven processes remain untouched. Startup errors now distinguish storage, occupied session, launch, exit status, and endpoint timeout.
- Full shared Swift suite passed **474 tests**: Playback 246, Auth 105, Domain 36, Library 87 (`/tmp/bopify-inline-core.log`). This run enabled the real Spotify-signed CLI integration: a disposable synthetic-key session reproduced an orphan, refused termination for a different session, recovered its own orphan, and restarted twice. No personal credentials were used.
- The signed Release build passed `scripts/verify-desktop-app.sh` on its final production sources. The check downloaded official **Soloist 1.3.10.51**, verified publisher/version and cache reuse, started and restarted the daemon, received real local WebSocket responses, removed temporary files, and verified arm64, hardened runtime, and absence of App Sandbox capabilities (`/tmp/bopify-onboarding-signed-check.log`).
- Artifact: `build/unified-onboarding-test-20261107/Build/Products/Release/Bopify.app`.
- Read-only code review found no critical or important issues; final native scrolling correction was also inspected during integration. `git diff --check` passed. The Release compiler still reports an existing actor-isolation warning in unchanged `CoverFlowView.swift`.
- Interactive personal-key pairing and audible playback remain the account acceptance step. Download/version checks alone are no longer reported as playback verification.

## Pairing discovery follow-up

A live first-pairing report showed the playback device missing from Spotify. Root integration owns local-network/Bonjour metadata, the discovery browser and retry lifecycle. The inline playback step now distinguishes entry, preparation, pairing and ready headings; pairing starts/stops discovery with the active pairing name, opens the installed Spotify desktop app (official download fallback), and offers Local Network Settings plus saved-key discovery retry after policy denial. Idle setup does not start browsing.

UI regression coverage exercises phase headings and idle/browsing/denied/unavailable guidance without live network access; existing full-root secure Return submission and small-window library registration remain covered. Initial missing-UI-symbol red was observed before implementation. Combined focused verification passed **17 tests across 3 suites** (`SoloistDiscoveryTests`, `SoloistSetupTests`, and `SoloistSetupRenderingTests`), Xcode exit 0 (`/tmp/bopify-pairing-focused-green.log`). Final focused verification also passed **17 tests across 3 suites** after correcting pending-permission wording and the failure heading, Xcode exit 0 (`/tmp/bopify-pairing-final-focused.log`). Native denied-policy guidance was captured and inspected; all copy and actions fit the constrained fixture. As with earlier bitmap captures, native/GPU button rendering is not represented faithfully.

The follow-up complete app suite executed **293 tests across 43 suites**, exit 65, with **24 issues across nine unchanged focus-sensitive tests** (`/tmp/bopify-pairing-final-all.log`):

- `MusicBrowserTests.typingMultipleCharactersKeepsTheInsertionPointAndArrowKeysSelectResults`
- `PlayerLyricsTests.vinylClickExpandsWithoutTogglingPlayback`
- `PlayerLyricsTests.lyricClicksAndSelectionsPreservePresentationMode`
- `PlayerLyricsTests.syncClickPreservesPresentationMode`
- `PlayerLyricsTests.keyboardReadingAndSyncPreservePresentationMode`
- `PlayerShortcutTests.searchRevealsTheHiddenPlayerAndFocusesTheRetainedQuery`
- `PlayerShortcutTests.playerShortcutHidesSearchAndCanRevealThePlayerAgain`
- `PlayerWindowControllerTests.fullscreenEligibilityFollowsActualFocusWithoutChangingDesktopLevel`
- `PlayerWindowControllerTests.menuBarClickRaisesTheVisiblePlayerAfterAnotherWindowTakesFocus`

These failures concern key-window/pointer behavior; their environmental cause is not established by this run. No tests were loosened and no unrelated focus code was changed. Pairing/discovery regressions passed in both focused runs and the full run. Root integration owns signed metadata and actual network/first-pairing verification.
