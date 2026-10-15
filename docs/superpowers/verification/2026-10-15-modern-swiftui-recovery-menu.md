# Modern SwiftUI recovery menu

Implemented and verified on 2026-10-15; release acceptance remains open. Base: `7a64b26`, isolated `codex/public-distribution-integration` worktree. User approved following the migration recommendation and explicitly selected macOS 26 and later.

## Scope and behavior

The active minimum is macOS 26, aligned in Xcode, SwiftPM, native build/test scripts, boundary compilation, layout/UI fixtures and README. This deliberately ends macOS 14/15 support. The menu itself did not require an OS bump; 26 matches the app's existing native Liquid Glass path. No dependency was added. The persistent nonactivating panel, wheel handling, playback recovery and free ad-hoc distribution remain.

CompactPlaybackConnectionMenu uses SwiftUI Menu and Button, replacing manual NSMenu construction, the representable container and mutable selector coordinator. The 94×24 capsule remains parent-owned, with a short restoration caption, error symbol, explicit small chevron, full accessible explanation and help. Menus expose a disabled explanation when it differs from the action; reauthentication has a single Reconnect Spotify item.

Selected retry and reconnect callbacks remain distinct. The menu identity follows the action key, preserving the original command in an already-open menu when recovery changes; it does not promise automatic dismissal. AppEnvironment now rejects reconnect when the current connection no longer requires authorization, checking again after serialization. The regression failed before the fix with Unexpected browser after playback recovered. Headless coverage now checks stale ready/sign-out requests, valid expired/corrupt authorization, duplicate requests and cancellation on quit. These use synthetic stores, browser callbacks and engines.

## Verification approach

The layout fixture measures geometry and local accessibility only. Apple XCUITest separately selects actual menu items, validates exactly-once counters and exported names, opens visible explanations, dismisses with Escape/outside click, changes status during an open menu, and checks focus-driven expansion through the production StatusPanel and PlayerPresentation. A generated test-only project launches only its uniquely identified synthetic app. The full recovery fixture additionally uses the actual StatusItemController, PlayerRootView, fake engine factory and recovery coordinator.

The UI runner snapshots the source files before compilation, hashes those copies, retains the xcresult bundle, validates declared versus executed test counts, and rejects missing/failed/zero-test results. Skipped qualification returns 77 even when xcodebuild succeeds. Seven negative-result tests demonstrate that prior exit-only handling incorrectly accepted eight cases, then pass against the fail-closed implementation.

The initial XCTest setup needed its own sandbox temporary directory and the production panel's exported Dialog role. Long explanation queries use explicit predicates because XCTest's string-identifier shortcut rejects more than 128 characters. Focused keyboard-opening attempts found hasFocus=false; the public NSApplication keyboard-navigation setting is disabled. Opening is skipped explicitly instead of changing that preference or changing product focus policy. These exploratory failures are preserved and are not passing evidence.

## Results

Runtime host: macOS 27.0.1 (26A434), Xcode 27, Swift 6.4, Apple Silicon. Compilation targets macOS 26; this does not prove runtime acceptance on macOS 26.

- Debug and Release builds passed. The Debug app's Info.plist and Mach-O LC_BUILD_VERSION both declare 26.0.
- Swift packages: 360 tests passed (177 playback, 60 library, 28 domain, 95 auth).
- Native gates: 173 unit tests and 2 documentation tests passed; one audio-hardware test remains explicitly ignored. The native release library rebuilt with the macOS 26 deployment setting.
- Python: 28 release/tooling tests, 11 scene-parser tests, 7 UI-result validation tests and 3 process-cleanup tests passed (49 total). The old-minimum packaging regression failed before the verifier change and now passes.
- Headless app boundaries passed logout, valid/duplicate/stale authorization, cancellation and artwork/cache/retry checks.
- Both native baseline and SwiftUI layout fixtures passed nine visible states and two hidden states, with 94×24 layout and complete local names/help.
- Final post-review XCUITest run: eight passed, one skipped, no failures. Mouse dispatch covers Retry now, Retry restoration, Reconnect Spotify, corrupt credentials and saved-sign-in retry with exact counts. Exported names and visible explanations passed. Keyboard selection, Escape, outside dismissal and focus-driven expanded recovery passed. Pending Retry remains Retry after changing to reauthentication, then selects once with zero reconnects. Pending Reconnect remains Reconnect after ready; its synthetic callback fires once, while the separate AppEnvironment regression proves that callback cannot authorize after recovery. Offline-to-reconnecting selects the unchanged Retry once. Intermediate JSON attachments prove tracking and original titles before actual selection; the tests do not dismiss with Escape to bypass pending selection. Keyboard opening is skipped because NSApplication.isFullKeyboardAccessEnabled is false. xcodebuild exited 0; the qualification runner correctly exited 77. Compiled source hashes match current production and fixture files.
- Post-review Debug and Release builds passed; Swift packages passed 360 tests. The final layout fixture also passed all nine visible states and two hidden states after the menu identity fix.
- Full production-player probe completed its behavior assertions: stable compact/expanded/queue geometry, blocked detached commands, restoration retry creating a replacement, focus expansion keeping recovery reachable, 100 replacements plus 10 failed creations, single live engine/create, stale input rejection, teardown and interrupted animation. Its strict diagnostic gate **failed** on the existing AppKit recursive-layout signature; overall exit 251, not a clean recovery-probe pass. The warning occurred 1.057 seconds after start beside AppKit's status-item initialization logs. This is consistent with the previously isolated NSStatusItem finding, not proof of an Apple-confirmed cause. The first run also failed at the final diagnostic gate; the instrumented run preserves all 2,526 process-scoped log records and one matching warning.

Before/after closed-state screenshots preserve the capsule and discoverable chevron. Actual open-menu captures show the restoration explanation/action and the longest existing cleanup explanation without truncation. The chevron now follows the existing StationMenu's small explicit symbol. Earlier exploratory fixture failures and interrupted runs are retained separately and never counted as passing qualification. Older native input-run metadata predates source snapshotting; the final before/after layout comparison uses frozen source copies instead.

Evidence (private, not committed):

- Final UI: `/private/tmp/bopify-menu-review-final-unlocked/` (compiled source copies, hashes, test-summary.json, run-metadata.json, UIResults.xcresult, cropped menu captures).
- Layout pair: `/private/tmp/bopify-menu-layout-native/`, `/private/tmp/bopify-menu-layout-swiftui/`; final post-review layout: `/private/tmp/bopify-menu-layout-review-final/`.
- Full player: `/private/tmp/bopify-modern-menu-full-recovery-logged.log`, `/private/tmp/bopify-modern-menu-full-recovery-logged/ui-diagnostics.json` and 16 captures. The earlier strict failure is preserved in `/private/tmp/bopify-modern-menu-full-recovery/`.
- Build/test logs: `/private/tmp/bopify-modern-menu-{debug-build,release-build,swift-tests,native-tests,native-build,boundaries,tooling-tests}.log`.
- Final review logs: `/private/tmp/bopify-menu-review-final-python.log`, `/private/tmp/bopify-menu-review-all-swift.log`, `/private/tmp/bopify-menu-action-final/{build.log,run.log}`.
- Red regressions: `/private/tmp/bopify-menu-action-regression/red.log`, `/private/tmp/bopify-menu-ui-results-red.log`, `/private/tmp/bopify-modern-menu-release-floor-red.log`.

Reproduction:

```sh
python3 docs/superpowers/verification/run-compact-recovery-menu-probe.py --derived-data /private/tmp/bopify-modern-menu-build --output /private/tmp/bopify-menu-layout-repeat
python3 docs/superpowers/verification/run-recovery-menu-ui-tests.py --derived-data /private/tmp/bopify-modern-menu-build --output /private/tmp/bopify-menu-ui-repeat
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-modern-menu-build --output /private/tmp/bopify-menu-full-repeat --probe recovery
```

Run GUI probes serially. The UI runner returns 77 for skipped keyboard-opening qualification; the full probe still rejects framework diagnostics.

## Independent review and one fix pass

A fresh independent whole-branch review of `7a64b26..8fc7f70` found no Critical issue, one Important pending-selection evidence gap, and a cleanup finding initially graded Minor. Cleanup is treated as Important because a surviving automation process could affect desktop input. Both were addressed in one fix pass; no second review was dispatched.

The strengthened tracking probe exposed an actual issue: changing offline to reauthentication replaced the open menu's Retry item with Reconnect Spotify. The original source failed with exit 2 and a tracking snapshot containing Reconnect Spotify. The probe deliberately refused to select that unexpected authorization command; it does not establish that unsolicited browser authorization occurred. Giving the SwiftUI menu its action identity preserves the original open-menu command. The same probe then passed with Retry selected once, zero reconnects, and tracking ended without watchdog cancellation. The unchanged-action case passed separately. All three compile logs were empty with warnings treated as errors.

Ruling: preserving the original command plus rejecting stale actions at AppEnvironment is the required safety contract. Automatic dismissal is not required and was not observed. This matches the approved no-authorization-from-pending-retry requirement, uses SwiftUI identity, and adds no production AppKit menu observer or private API. Apple documents state reset for changed identity, not a guarantee that a menu dismisses. Public-input XCTest independently confirms the observed behavior on this host.

The runner now owns its xcodebuild process group and cleans only the exact paths of its generated fixture and test runner in a finally block. Real compiled test executables reproduced surviving fixtures with the original helper in completion, timeout and interruption cases (three RED failures); all three pass with the fix. An unrelated executable with the same basename survives. Each UI output directory has distinct bundle identifiers. The completed final run left no process at its fixture/test-runner paths.

Evidence: `/private/tmp/bopify-menu-pending-old-final/`, `/private/tmp/bopify-menu-pending-changed-green-final/`, `/private/tmp/bopify-menu-pending-unchanged-green-final/`, `/private/tmp/bopify-menu-cleanup-red.log`, `/private/tmp/bopify-menu-cleanup-green.log`. Earlier UI runs that could not activate the app or enable automation are environment-unavailable results, not product regressions or passing evidence. The final run followed the user's confirmation that the Mac was unlocked and idle.

Review limits and rulings: actual pending-selection behavior is now tested locally and through XCTest. macOS 26 runtime, keyboard opening with global navigation enabled, VoiceOver speech, real Spotify consent/audio on this revision, clean installation and hosted CI remain unqualified; this host cannot establish them. Existing AppKit warnings remain strict diagnostic failures, and neither their root cause nor harmlessness is established. Forced cleanup is verified with real local executables, while broad permission changes and system-wide process termination are outside this task. The branch is retained for local review and candidate packaging; no merge or publication is implied.

## Local ad-hoc candidate

Built `build/release/Bopify-0.1.0-rc.4.dmg` from clean source commit `54eda55caabce859a62b53618771ab3359686125` with Rust 1.99.0 and `scripts/release.sh 0.1.0-rc.4 --ad-hoc`. The app reports version 0.1.0, build 264. The mounted DMG passed deep/strict signature verification, arm64-only architecture, hardened runtime, the four approved sandbox/network/file entitlements, absence of debugger exceptions and signing authority/team, and macOS26.0 in both Info.plist and Mach-O. App and DMG license/notices match source with mode0644; the Applications link points to /Applications. The read-only test mount was ejected. The candidate was not launched, installed or published.

Artifact size: 10015708 bytes. SHA-256: `2324cd98fed7db675af05bc55733242455494dc6fff05c0f2353cd5343289e8c`.

This is the user's selected free, ad-hoc distribution: it is not notarized and has no Developer ID identity. Packaging success does not close the acceptance gates below. The rebuild still emits the existing eleven cbindgen warnings (skipped non-exported items and unresolved BopifyError type messages); they are not claimed resolved. Xcode also logged its Supported platforms diagnostic while the archive/export completed. macOS27 warned that the verification mount's hdiutil command is deprecated; this is a local tooling message, not an app runtime finding. Evidence: `/private/tmp/bopify-modern-menu-rc4-release.log`, `/private/tmp/bopify-modern-menu-rc4-acceptance.json`, `/private/tmp/bopify-modern-menu-rc4-detach.log`, and `build/release/0.1.0-rc.4.iwk7ml/export-check.json`.

## AppKit follow-up

The [2026-10-15 warning disposition](2026-10-15-appkit-warning-disposition.md) records fresh macOS 26-targeted native, visibility-staged and declarative SwiftUI MenuBarExtra reproductions. All three warn; no reliable application workaround is verified. Three clean debugger runs of the current recovery probe do not supersede the positive failures. The strict diagnostic gate remains open.

## Remaining acceptance

Keyboard opening with system-wide all-controls navigation enabled, VoiceOver speech, and macOS 26 runtime remain unverified. Normal keyboard menu selection and Escape have separate automated coverage. Actual Spotify sign-out/reconsent, new native recovery live tests, clean-machine installation and hosted release CI remain separate gates. The AppKit transaction and historical recursive-layout findings remain open; this migration is not presented as their fix. No tag, push or GitHub release publication is authorized by this work.

## Sources checked 2026-10-15

- Apple, [Menu](https://developer.apple.com/documentation/swiftui/menu): standard declarative menu actions.
- Apple, [id(_:)](https://developer.apple.com/documentation/swiftui/view/id(_:)): changed identity resets view state; menu tracking behavior is qualified experimentally above.
- Apple, [ButtonMenuStyle](https://developer.apple.com/documentation/swiftui/buttonmenustyle): current public button menu style.
- Apple, [focusable(_:interactions:)](https://developer.apple.com/documentation/swiftui/view/focusable(_:interactions:)): conventional button focus depends on system-wide keyboard navigation.
- Apple, [2025 design announcement](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/): Liquid Glass arrives on macOS 26.
- GitHub, [Xcode 27 runner announcement](https://github.com/actions/runner-images/issues/14404): the existing xcode-27 label uses macOS 27 as of 2026-09-16; its hosted run remains unexecuted here.
