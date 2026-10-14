# Modern SwiftUI recovery menu

Implemented and verified on 2026-10-15; release acceptance remains open. Base: `7a64b26`, isolated `codex/public-distribution-integration` worktree. User approved following the migration recommendation and permits a newer macOS minimum.

## Scope and behavior

The active minimum is macOS 26, aligned in Xcode, SwiftPM, native build/test scripts, boundary compilation, layout/UI fixtures and README. This deliberately ends macOS 14/15 support. The menu itself did not require an OS bump; 26 matches the app's existing native Liquid Glass path. No dependency was added. The persistent nonactivating panel, wheel handling, playback recovery and free ad-hoc distribution remain.

CompactPlaybackConnectionMenu uses SwiftUI Menu and Button, replacing manual NSMenu construction, the representable container and mutable selector coordinator. The 94×24 capsule remains parent-owned, with a short restoration caption, error symbol, explicit small chevron, full accessible explanation and help. Menus expose a disabled explanation when it differs from the action; reauthentication has a single Reconnect Spotify item.

Selected retry and reconnect callbacks remain distinct. AppEnvironment now rejects reconnect when the current connection no longer requires authorization, checking again after serialization. The regression failed before the fix with Unexpected browser after playback recovered. Headless coverage now checks stale ready/sign-out requests, valid expired/corrupt authorization, duplicate requests and cancellation on quit. These use synthetic stores, browser callbacks and engines.

## Verification approach

The layout fixture measures geometry and local accessibility only. Apple XCUITest separately selects actual menu items, validates exactly-once counters and exported names, opens visible explanations, dismisses with Escape/outside click, changes status during an open menu, and checks focus-driven expansion through the production StatusPanel and PlayerPresentation. A generated test-only project launches only its uniquely identified synthetic app. The full recovery fixture additionally uses the actual StatusItemController, PlayerRootView, fake engine factory and recovery coordinator.

The UI runner snapshots the source files before compilation, hashes those copies, retains the xcresult bundle, validates declared versus executed test counts, and rejects missing/failed/zero-test results. Skipped qualification returns 77 even when xcodebuild succeeds. Seven negative-result tests demonstrate that prior exit-only handling incorrectly accepted eight cases, then pass against the fail-closed implementation.

The initial XCTest setup needed its own sandbox temporary directory and the production panel's exported Dialog role. Long explanation queries use explicit predicates because XCTest's string-identifier shortcut rejects more than 128 characters. Focused keyboard-opening attempts found hasFocus=false; the public NSApplication keyboard-navigation setting is disabled. Opening is skipped explicitly instead of changing that preference or changing product focus policy. These exploratory failures are preserved and are not passing evidence.

## Results

Runtime host: macOS 27.0.1 (26A434), Xcode 27, Swift 6.4, Apple Silicon. Compilation targets macOS 26; this does not prove runtime acceptance on macOS 26.

- Debug and Release builds passed. The Debug app's Info.plist and Mach-O LC_BUILD_VERSION both declare 26.0.
- Swift packages: 360 tests passed (177 playback, 60 library, 28 domain, 95 auth).
- Native gates: 173 unit tests and 2 documentation tests passed; one audio-hardware test remains explicitly ignored. The native release library rebuilt with the macOS 26 deployment setting.
- Python: 28 release/tooling tests, 11 scene-parser tests and 7 UI-result validation tests passed (46 total). The old-minimum packaging regression failed before the verifier change and now passes.
- Headless app boundaries passed logout, valid/duplicate/stale authorization, cancellation and artwork/cache/retry checks.
- Both native baseline and SwiftUI layout fixtures passed nine visible states and two hidden states, with 94×24 layout and complete local names/help.
- Final XCUITest run: six passed, one skipped, no failures. Mouse dispatch covers Retry now, Retry restoration, Reconnect Spotify, corrupt credentials and saved-sign-in retry with exact counts. Exported names and visible menu explanations passed. Keyboard selection, Escape, outside dismissal, status change during tracking, and focus-driven expanded recovery passed. Keyboard opening is skipped because NSApplication.isFullKeyboardAccessEnabled is false. xcodebuild exited 0; the qualification runner correctly exited 77.
- Full production-player probe completed its behavior assertions: stable compact/expanded/queue geometry, blocked detached commands, restoration retry creating a replacement, focus expansion keeping recovery reachable, 100 replacements plus 10 failed creations, single live engine/create, stale input rejection, teardown and interrupted animation. Its strict diagnostic gate **failed** on the existing AppKit recursive-layout signature; overall exit 251, not a clean recovery-probe pass. The warning occurred 1.057 seconds after start beside AppKit's status-item initialization logs. This is consistent with the previously isolated NSStatusItem finding, not proof of an Apple-confirmed cause. The first run also failed at the final diagnostic gate; the instrumented run preserves all 2,526 process-scoped log records and one matching warning.

Before/after closed-state screenshots preserve the capsule and discoverable chevron. Actual open-menu captures show the restoration explanation/action and the longest existing cleanup explanation without truncation. The chevron now follows the existing StationMenu's small explicit symbol. Earlier exploratory fixture failures and interrupted runs are retained separately and never counted as passing qualification. Older native input-run metadata predates source snapshotting; the final before/after layout comparison uses frozen source copies instead.

Evidence (private, not committed):

- Final UI: `/private/tmp/bopify-menu-ui-final-evidence/` (compiled source copies, hashes, test-summary.json, run-metadata.json, UIResults.xcresult, cropped menu captures).
- Layout pair: `/private/tmp/bopify-menu-layout-native/`, `/private/tmp/bopify-menu-layout-swiftui/`.
- Full player: `/private/tmp/bopify-modern-menu-full-recovery-logged.log`, `/private/tmp/bopify-modern-menu-full-recovery-logged/ui-diagnostics.json` and 16 captures. The earlier strict failure is preserved in `/private/tmp/bopify-modern-menu-full-recovery/`.
- Build/test logs: `/private/tmp/bopify-modern-menu-{debug-build,release-build,swift-tests,native-tests,native-build,boundaries,tooling-tests}.log`.
- Red regressions: `/private/tmp/bopify-menu-action-regression/red.log`, `/private/tmp/bopify-menu-ui-results-red.log`, `/private/tmp/bopify-modern-menu-release-floor-red.log`.

Reproduction:

```sh
python3 docs/superpowers/verification/run-compact-recovery-menu-probe.py --derived-data /private/tmp/bopify-modern-menu-build --output /private/tmp/bopify-menu-layout-repeat
python3 docs/superpowers/verification/run-recovery-menu-ui-tests.py --derived-data /private/tmp/bopify-modern-menu-build --output /private/tmp/bopify-menu-ui-repeat
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-modern-menu-build --output /private/tmp/bopify-menu-full-repeat --probe recovery
```

Run GUI probes serially. The UI runner returns 77 for skipped keyboard-opening qualification; the full probe still rejects framework diagnostics.

## Remaining acceptance

Keyboard opening with system-wide all-controls navigation enabled, VoiceOver speech, and macOS 26 runtime remain unverified. Normal keyboard menu selection and Escape have separate automated coverage. Actual Spotify sign-out/reconsent, new native recovery live tests, clean-machine installation and hosted release CI remain separate gates. The AppKit transaction and historical recursive-layout findings remain open; this migration is not presented as their fix. No tag, push or GitHub release publication is authorized by this work.

## Sources checked 2026-10-15

- Apple, [Menu](https://developer.apple.com/documentation/swiftui/menu): standard declarative menu actions.
- Apple, [ButtonMenuStyle](https://developer.apple.com/documentation/swiftui/buttonmenustyle): current public button menu style.
- Apple, [focusable(_:interactions:)](https://developer.apple.com/documentation/swiftui/view/focusable(_:interactions:)): conventional button focus depends on system-wide keyboard navigation.
- Apple, [2025 design announcement](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/): Liquid Glass arrives on macOS 26.
- GitHub, [Xcode 27 runner announcement](https://github.com/actions/runner-images/issues/14404): the existing xcode-27 label uses macOS 27 as of 2026-09-16; its hosted run remains unexecuted here.
