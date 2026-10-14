# SwiftUI recovery-menu qualification

> Historical qualification result. The 2026-10-15 continuation replaces the adapter and raises the minimum to macOS 26; see [current implementation and evidence](2026-10-15-modern-swiftui-recovery-menu.md). Earlier unqualified results below remain historical evidence.

Execution started 2026-10-14; final checks completed 2026-10-15. Host: macOS 27.0.1 (26A434), arm64, Xcode 27 / Swift 6.4. The macOS 14 minimum is unchanged.

## Shipping result

Retain CompactPlaybackConnectionMenu as the existing native adapter. Correct its native popup cell's accessibility label to the full connection explanation. The local accessibility tree exposes NSPopUpButtonCell as the menu element; labeling only its button left the restoration state named by the short visible Retry now caption. The full explanation was available as help, but absent from that element's name.

The baseline failed that name check in exactly one of nine visible states. Adding the cell label passed all nine while preserving the short caption, help, 94×24 capsule and existing handlers. Before/after screenshots were inspected; this metadata correction retains the native chevron and current appearance. VoiceOver and exported-client accessibility verification remain separate gates; a local getter is not a substitute for either.

The SwiftUI Menu candidate stayed outside production source. It compiled targeting macOS 14 with Swift 6 warnings-as-errors and passed the same nine visible-state layout/name/help checks on this host. Its screenshot omits the native chevron, following the existing StationMenu style. Actual action selection, keyboard behavior and macOS 14 runtime acceptance remain unqualified, so it was not substituted into the app.

## Qualification results

| Check | Native baseline | Native cell-label correction | SwiftUI candidate |
|---|---|---|---|
| Nine visible states, 94×24 capsule | Passed | Passed | Passed |
| Complete local name and help | Name failed for restoration | Passed all nine | Passed all nine |
| Ready/stopped without unavailable | Hidden | Hidden | Hidden |
| Actual menu action selection | Unverified | Unverified | Unverified |
| Keyboard opening/selection/Escape | Unverified | Unverified | Unverified |
| macOS 14 compilation | Passed | Passed | Passed |
| macOS 14 runtime | Unavailable | Unavailable | Unavailable |

Visible states: connecting, restoring, reconnecting, offline, unavailable restoration, reauthentication, corrupt credentials, saved-credential retry and permanent Premium failure. Geometry is measured separately from accessibility bounds: the original native element reports 91×26 for a 94×24 layout. SwiftUI returns attributed accessibility text, which the fixture normalizes before comparison.

The menu fixture returns 77 for incomplete input/keyboard qualification even when layout and name checks pass. The uncorrected native baseline returned 2 for its name failure. Public local accessibility actions did not establish reliable actual selection; denied activation was explicitly unavailable. No callback-count success is claimed from those runs. Inspection is limited to visible fixture windows, and diagnostic output does not dump the system menu bar.

The existing PlaybackRecoveryProbe retains its native-specific action assertions until behavior-based public-input parity can be demonstrated. Its direct action dispatch is useful existing coverage, but does not replace the missing public menu/keyboard qualification.

## Verification

- Final Debug app build: passed, code signing disabled.
- Swift packages: 360 tests passed (177 playback, 60 library, 28 domain, 95 auth).
- Python tooling: 27 tests passed; scene-evidence parser: 11 tests passed after the independent-review regression fix (38 Python tests total).
- Final native UI fixture: all nine geometry/local-name/help checks and both hidden states passed; overall exit 77 for incomplete input/keyboard qualification.
- Existing fake-engine recovery probe: passed with exit 0, including current compact/expanded/queue geometry, actual handler dispatch, detached-command blocking, restoration retry, permanent-error explanation, 100 replacements plus 10 failed creations, single live engine/create, stale-input rejection, teardown and interrupted animations.
- That recovery run's strict UI diagnostic check was clean. The separately validated pure SwiftUI popover reproduction still emits the transaction warning; this run does not close either historical AppKit finding.

The recovery runner initially failed to link with unresolved Nuke symbols because it compiles ArtworkStore but omitted Nuke.o. Adding that existing build product fixed the linker failure, and the final probe passed. No dependency, package version, Rust source, signing policy or native playback behavior changed.

## Evidence and commands

```sh
python3 docs/superpowers/verification/run-compact-recovery-menu-probe.py --derived-data /private/tmp/bopify-swiftui-menu-build --output /private/tmp/bopify-swiftui-menu-native-final
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-swiftui-menu-build --output /private/tmp/bopify-swiftui-menu-linked-recovery-final --probe recovery
swift test --package-path Packages/BopifyCore
```

- Native red baseline/screenshots: `/private/tmp/bopify-swiftui-menu-native/`.
- Final corrected source fixture/screenshots/JSON/metadata: `/private/tmp/bopify-swiftui-menu-native-final/`.
- Final production source SHA-256: `2d4df1ff1ddcb1d745f6c2420c63ba925b1aa9344db4609052a5de5dc38f0b82`.
- Throwaway candidate source/screenshots/results: `/private/tmp/bopify-swiftui-menu-candidate/`; its runner accepts `--candidate-source` to compare a temporary source copy without editing shipping code.
- Native-only correction prototype: `/private/tmp/bopify-native-menu-name-candidate/`.
- Recovery linker red log: `/private/tmp/bopify-swiftui-menu-recovery-red.log`.
- Final recovery log/captures: `/private/tmp/bopify-swiftui-recovery-linked.log`, `/private/tmp/bopify-swiftui-menu-linked-recovery-final/`.
- Final Debug build and Swift logs: `/private/tmp/bopify-swiftui-menu-final-build.log`, `/private/tmp/bopify-swiftui-final-tests.log`.
- Python tooling log: `/private/tmp/bopify-swiftui-tooling-tests.log`.

## Remaining decisions and gates

Keep the player shell and macOS 14 support. Before adopting the SwiftUI menu, qualify real menu selection, state updates while a menu is open, keyboard/Escape, VoiceOver/exported accessibility, long-label fit and runtime behavior on macOS 14. The local prototype is feasibility evidence only. Gesture migration needs a separate macOS 15 decision. See [declarative popover evidence](2026-10-14-swiftui-scene-popover-evidence.md) for the unresolved framework warning. The running app, Spotify session, stored credentials and audio output were untouched; no app was installed or release published.
