# SwiftUI Recovery Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the compact native recovery menu only if a smaller SwiftUI implementation preserves its layout, accessibility and real recovery actions on supported macOS versions.

**Architecture:** Keep PlaybackConnectionStatusView as the existing state/action mapping. Qualify CompactPlaybackConnectionMenu through an account-free fixture and behavior-based recovery checks, then change only that view if acceptance succeeds. Keep the panel, recovery coordinator and engine unchanged.

**Tech Stack:** Swift 6, SwiftUI Menu/Button, existing BopifyPlayback/BopifyDomain, public accessibility inspection, existing Python probe tooling. No dependencies.

**Spec:** [Approved SwiftUI-first design](../specs/2026-10-14-swiftui-first-migration-design.md), execution sequence 2. Approved in chat after commit `c3a7369`. Warning evidence is handled by [the separate probe plan](2026-10-14-swiftui-popover-evidence.md).

## Global Constraints

- Keep the existing macOS 14 minimum pending an explicit decision to raise it.
- Replace only CompactPlaybackConnectionMenu after the candidate passes; otherwise record the failed requirement and keep the current adapter.
- Current native wrapper fixes a measured 106-point intrinsic width against a 94-point capsule.
- Match the existing StationMenu styling pattern when testing.
- A runtime check on macOS 14 remains required if support is retained; targeting 14 with a newer SDK is insufficient.
- No live sign-in, native engine, credentials, audio-output changes, panel redesign or minimum-OS change.

## Review Focus

- A pending menu selection after a state update must invoke the current recovery action once; Task 1 tests the update and Task 2 tests actual selection.
- Long labels and permanent errors must preserve 94-point geometry while exposing the complete explanation; Tasks 1–2 verify fit and accessibility.
- Keyboard opening, selection and Escape must work when the panel is key, and dismissal must not trigger recovery; Task 1 records input behavior.
- Ready/stopped visibility and credential-recovery actions must retain existing policy; Tasks 1–2 cover the full mapping.
- Current-OS success must not mask missing macOS 14 runtime evidence or framework diagnostics; Task 3 keeps acceptance gates separate.

### Task 1: Establish behavior-based native baseline

**Files:** Create `docs/superpowers/verification/CompactRecoveryMenuProbe.swift` and `docs/superpowers/verification/run-compact-recovery-menu-probe.py`. Modify only relevant compact-menu assertions (credential retry, restoration retry, reconnect and permanent failure) in `docs/superpowers/verification/PlaybackRecoveryProbe.swift` and the link object list in `docs/superpowers/verification/run-monolith-probe.py`.

**Interfaces:** Consume unchanged `PlaybackConnectionStatusView(status:restorationUnavailable:onRetry:onReconnect:)` and `CompactPlaybackConnectionMenu(connection:)`. New fixture CLI takes one absolute output directory; new runner CLI accepts `--derived-data <directory> --output <directory>`. Fixture result records case/status, retry/reconnect counts, accessible name/help, capsule/panel bounds and input results. Use public accessibility roles/actions with the existing `tree`, `hasText` and `press` patterns; never depend on NSPopUpButton, Handler type names or selector spellings.

- [ ] Build a minimal account-free host of the actual production status view and menu, constrained to 94×24 points with the existing material capsule. Inject counters instead of network/auth services. Cases: connecting/restoring/reconnecting/offline → Retry now; ready+unavailable → short Retry now caption and Retry restoration action; needsReauthentication/credentialCorrupt → Reconnect Spotify; retryable credential fault → Retry saved sign-in; premiumRequired → icon and full explanation without action; ready/stopped without unavailable → hidden.
- [ ] Open the actual menu through accessible input and select its action, asserting exactly one expected counter increments and the other stays zero. Repeat after changing the connection value to catch stale callbacks. Verify the full accessible name/help, explanation inside the menu, icon state and capsule width within 0.5 points. Check mouse opening, keyboard opening/selection, Escape without dispatch and long localized labels. Capture before screenshots and actual menu/panel frames; report unsupported automation as unverified, never passed. Do not add product copy or localization just for the fixture; use existing longer translations or a fixture-owned long-label example.
- [ ] Compile the fixture with the production PlaybackConnectionStatusView.swift and package objects, using Swift 6 warnings-as-errors and `-target arm64-apple-macosx14.0`. Follow scripts/test-app-boundaries.py's module/library/framework arguments and resource copying from run-monolith-probe.py. Build only the required source set; do not construct AppEnvironment or link a new service client. The runner creates an isolated fixture bundle and fails on compile/assertion failure.
- [ ] Replace PlaybackRecoveryProbe compact native internals with the same visible/accessible behavior checks. Preserve existing frame, retry-creation and permanent-error assertions; selecting Retry restoration must increase ProbeFactory.options.count exactly once. Keep checkUIDiagnostics unchanged. Remove popups/captionFits only when unused by this change.
- [ ] Add `Nuke` to run-monolith-probe.py's existing linked object names: it compiles ArtworkStore for recovery and other probes, and Debug/Nuke.o supplies that source's unresolved Nuke symbols. Do not change unrelated runner deployment targets or instrumentations.
- [ ] Build the Debug app using the Task 3 command, then run `python3 docs/superpowers/verification/run-compact-recovery-menu-probe.py --derived-data /private/tmp/bopify-swiftui-menu-build --output /private/tmp/bopify-swiftui-menu-native` against the unchanged native menu. Then run `python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-swiftui-menu-build --output /private/tmp/bopify-swiftui-menu-native-recovery --probe recovery`. Preserve diagnostic failures independently from menu assertions; do not weaken or suppress them. Commit the behavior-based fixture/runner changes only after inspecting results.

### Task 2: Qualify the smallest SwiftUI replacement

**Files:** Modify `Bopify/Bopify/Views/PlaybackConnectionStatusView.swift`; use Task 1 fixtures unchanged.

**Interfaces:** Preserve the two existing view initializers, actionKey/message mapping and performAction(). CompactPlaybackConnectionMenu becomes `View`; its input remains `connection: PlaybackConnectionStatusView`. No new model/protocol/coordinator.

- [ ] Confirm the Task 1 native baseline results and macOS 14 runtime availability before removing the adapter. If a supported runtime is unavailable, use a clearly labeled temporary candidate outside the shipping source for feasibility; retain production AppKit until required runtime evidence exists.
- [ ] Implement Menu with Button actions calling connection.performAction, existing full explanation, short unavailable caption and permanent-error symbol. Use `.menuStyle(.button)`, `.buttonStyle(.plain)` and `.menuIndicator(.hidden)` as StationMenu does. Keep 10-point caption font, single-line truncation, full accessibility label/help, and parent-owned capsule dimensions. Do not hard-code 94 points in the product view; RecordPlayerView owns diameter−24. Delete only the native coordinator/container made obsolete by this replacement.
- [ ] Run the same fixture before/after on the current OS and macOS 14. Inspect screenshots and keyboard/AX results for every case. Exercise state changes before menu reopening, and verify selection uses the current action exactly once. Reject a candidate requiring custom sizing/input machinery greater than the adapter it replaces.
- [ ] Run the focused recovery probe again. Assert unchanged compact/expanded/queue frames, blocked detached commands, actual retry creation and permanent-error explanation. A framework diagnostic is still a failed diagnostic gate; it cannot be relabeled a menu pass for overall release readiness.
- [ ] If any required menu behavior fails or macOS 14 acceptance remains unavailable, restore the product view, retain useful qualification evidence and stop the replacement. If all acceptance checks pass, commit the surgical view replacement with the before/after evidence referenced.

### Task 3: Final verification and report

**Files:** Create `docs/superpowers/verification/2026-10-14-swiftui-recovery-menu.md`.

- [ ] Debug build: `xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-swiftui-menu-build -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build`. Expect exit 0. If native artifacts require rebuilding, use `RUSTUP_TOOLCHAIN=1.99.0 ./scripts/build-rust.sh` first; no Rust source changes or unrelated native test expansion.
- [ ] Run `swift test --package-path Packages/BopifyCore`; expect zero failures. Run the focused menu and recovery probes against the final source. Inspect all output and screenshots, including diagnostics, without inferring runtime support from compilation.
- [ ] Report candidate shipped/retained adapter, OS/runtime coverage, exact menu behavior results, screenshots, full log locations and remaining diagnostic/release gates. If unavailable runtime/input permissions block acceptance, say so explicitly and keep the adapter. Do not claim the AppKit warning is fixed because the wrapper was removed.
- [ ] Run `git diff --check`, review every changed line against this plan and commit the report. Do not tag, push, merge or publish. macOS 15 gestures and Library Access scene changes require a later plan after the OS decision.
