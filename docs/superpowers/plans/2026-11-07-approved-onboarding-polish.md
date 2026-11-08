# Approved Onboarding Polish Implementation Plan

> Execute inline with the executing-plans skill. The user approved the readability-only browser demo; no additional visual redesign is authorized.

**Goal:** Restore the original onboarding style with comfortable, readable copy and labeled Liquid Glass inputs.

**Architecture:** Keep the existing one-window flow, native fields/scroll bridge, saved setup reuse, and controller behavior. Restore the full Aurora, centered composition, original record sizing, compact header progress, and glass capsule actions. Add only the soft instructional tint and typography/wrapping improvements shown in the demo.

**Tech Stack:** SwiftUI/AppKit, existing Liquid Glass controls; no dependencies.

**Approved spec:** User-approved `build/onboarding-readability-demo/index.html` and its comparison image. These are visual mock-ups, not exact native rendering references. The user's follow-up requires simple, seamless UX and comfortable UI.

## Constraints and decisions

- Preserve the original Aurora, record animation, centered layout, and glass buttons.
- Keep permanent labels, native secure entry, visible focus and readable wrapping.
- Keep compact visual progress; expose the full step name and number to accessibility.
- Keep the instructional tint soft, without opaque panels or additional cards. Respect Reduce Transparency, Increase Contrast and Reduce Motion.
- No playback, authentication, scopes, account data or consent lifecycle changes.
- Only related onboarding rendering, keyboard/scroll and window/record layout tests may run. Do not run the full app/package/native suites or repeat unrelated live installation checks.
- Future design changes require a demo before application.

## One task: Apply the approved visual polish

Files: `StartupView.swift`, `StartupInput.swift`, `PlayerRootView.swift`, `SignInRecordView.swift`, `SignInView.swift`, `PlaybackOnboardingView.swift`, `LibraryAuthorizationSetupView.swift`; localization only for removal of newly unused onboarding copy.

- [x] Read the original and current views, approved demo and relevant existing tests.
- [x] Restore the original composition and glass surface; use the demo's text-area tint, semantic accessibility fallback, readable copy and compact step accessibility.
- [x] Keep the native labeled glass inputs and centered simplified registration guidance; preserve saved values and every action.
- [x] Run only `SoloistSetupRenderingTests`, `SignInRecordTests`, and `StartupShellTests`; inspect relevant native captures with their known GPU compositing limitations.
- [x] Build a signed Release app; review the final scoped diff once, record actual results and hand over the exact artifact. No real credentials or playback commands.

This is a reversible visual adjustment; existing meaningful secure-entry/Return/Tab/scroll and layout regressions are reused rather than adding tests that mirror styling declarations. No new product behavior is introduced.

## Implementation and observed results

The original record scale, centered headings/forms, full-window Aurora, capsule glass actions and compact header progress are restored. Readable instruction text sits over a soft scrolling tint rather than an opaque content panel. Full step names remain available to accessibility. Native labeled inputs retain secure cells, keyboard/focus handling, and saved-value reuse. The glass editor uses a dark appearance only within the control during the colorful presentation; the whole window is not forced into a different color scheme. Solid accessibility fallbacks retain semantic colors.

The library keyboard fixture originally used an ordinary titled NSWindow while XCTest's application activation policy was prohibited. Diagnostics showed no active/key window, an unchanged native field, and lost editing focus; neither a self-activation request nor a temporary regular activation policy made that ordinary window key in this tool context. Those temporary diagnostics/policy changes were removed. The test now uses the actual production `StatusPanel` and nested hosting container, with an added key-window prerequisite and every existing validation, focus, authorization and scrolling assertion retained. The isolated test passed in that production panel. No production workaround or test assertions were disabled.

- Selected three onboarding suites: **21 tests passed**, exit 0 (`/tmp/bopify-approved-onboarding-final.log`).
- After the final input/color refinement, only the affected presentation suite was repeated: **9 tests passed**, exit 0 (`/tmp/bopify-approved-onboarding-appearance.log`). Unaffected record/window checks were not repeated.
- Signed Release build passed (`/tmp/bopify-approved-onboarding-release.log`). Artifact: `build/approved-onboarding-test-20261107/Build/Products/Release/Bopify.app`.
- Final `codesign --verify --deep --strict` passed with macOS trust-service access. The sandbox-only invocation could not access trust evaluation (`CSSMERR_TP_NOT_TRUSTED`); the same verification succeeded with normal trust-service access, without modifying or re-signing the artifact.
- One fresh read-only review found no actionable issue in the seven-view implementation. The final scoped diff and `git diff --check` were reviewed after fixture cleanup and the final appearance adjustment.
- No full package/app/Rust suites, fresh Soloist installation check, user credentials, real playback commands, or automatic app relaunch were used for this change.

Native capture matrices were inspected for text wrapping and scrolling; as before, `cacheDisplay` does not faithfully capture GPU blur, record transforms or native glass. These are layout evidence, not a composited screenshot of the running app. The approved browser demo remains the visual reference; the signed app is supplied for live appearance review. This plan supersedes the preceding opaque-surface/left-aligned onboarding design.
