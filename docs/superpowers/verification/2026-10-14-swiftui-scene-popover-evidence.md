# Declarative SwiftUI popover evidence

Verified 2026-10-14–15 on macOS 27.0.1, build 26A434, arm64, Xcode 27 / Apple Swift 6.4. This is framework-diagnostic evidence, not release acceptance or a production fix.

## Result

A fully declarative SwiftUI App/Window reproduces the popover transaction warning. No NSHostingController, custom NSWindow/NSPanel, Bopify UI, Spotify account, native engine or dependency is required. The fixture observes public popover notifications and uses process-scoped OSLog; SwiftUI owns the window and presentation.

Final direct-launch matrix:

| Mode | Runs | Valid evidence | Target diagnostics | Invalid CA transactions |
|---|---:|---|---:|---:|
| No-popover control | 6 | 6 clean | 0 | 0 |
| Binding dismissal | 6 | 6 reproductions | 6 per run | 1 per run |
| Outside click | 6 | 6 unavailable | Not classified as clean | Not qualified |

Runner exited 77 because outside-click input was unavailable. Every binding run validated exactly-once log and memory markers for presentation, content appearance, requested close, actual close and disappearance. The missing-close negative control returned 2 with lifecycleValidated=false; invalid arguments returned 2. Compilation targeted macOS 14 with Swift 6 warnings treated as errors. Eleven evidence-parser tests passed. The independent-review fix added negative coverage for missing click evidence, reversed lifecycle, premature dismissal, missing binding intent and popover activity in a control; the prior validator fails six new assertions. The fixture and parser both enforce ordered mode-specific evidence. Outside-click qualification now requires a tagged mouse-down observed in the target fixture window before closure, not just successful event posting.

Each reproduced stack has 35 frames: AppKit currentTransaction/window-property precommit, transaction deallocation and block disposal, QuartzCore commit handlers, the run loop, SwiftUI runApp/App.main and the fixture entrypoint. No Bopify code participates. This shows a custom Bopify AppKit adapter is unnecessary for reproduction; it does not establish that the warning is harmless or an Apple-confirmed defect.

## Input and launch findings

The fixture must use --binding/--outside/--control flags. Bare positional mode arguments prevented SwiftUI from creating its primary window; the bounded watchdog rejected those runs.

The first matrix had six clean controls and six binding reproductions, but outside-click delivery failed while the fixture was inactive and not key. A pre-review LaunchServices activation experiment captured warnings on three outside-mode closures, but lacked the newly required tagged delivery observation and is not qualified outside-click evidence. It also caused three binding popovers to dismiss before their requested close. Those binding runs were correctly invalidated. The final matrix removes that reopening interference and explicitly marks missing foreground/key-window activation unavailable. An earlier isolated active outside-mode run also captured six diagnostics; it likewise predates the delivery-proof requirement and is not qualified outside-click evidence. These supplementary runs are retained separately and are not added to the final matrix counts.

Apple documents activation as a request that may be denied: [Passing control with cooperative activation](https://developer.apple.com/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation). No deprecated force-activation API, private API, animation workaround or warning suppression was introduced. No fixture screenshots were captured for this diagnostic matrix; it does not claim visual parity.

## Reproduction and evidence

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s docs/superpowers/verification -p test_scene_popover_runner.py
python3 docs/superpowers/verification/run-swiftui-scene-popover-probe.py --output /private/tmp/bopify-scene-popover-reviewed
```

- Final complete per-process stdout/stderr, build log and 18-row summary: `/private/tmp/bopify-scene-popover-reviewed/`.
- Source SHA-256 recorded and checked against the final matrix: `da694d4598da6111b5a9976e639f3a9650802177d4907902b59af3d075fd2b29`.
- Negative controls: `missing-close.stdout` and `invalid.stdout` in that directory.
- Initial isolated modes: `/private/tmp/bopify-scene-popover-initial/`.
- First matrix with inactive outside-click failures: `/private/tmp/bopify-scene-popover-evidence/`.
- LaunchServices experiment with invalid early dismissals: `/private/tmp/bopify-scene-popover-final/`.
- Initial parser red evidence: `/private/tmp/bopify-scene-runner-red.log`; review regression red: `/private/tmp/bopify-scene-review-all-red.log`.
- Pre-review direct matrix: `/private/tmp/bopify-scene-popover-direct-final/`.
- Reviewed negative-control exit records: `negative-controls.json` in the final directory.

## Remaining gates

A second supported OS has not been tested. The final outside-click matrix needs an active/key fixture to qualify input. Neither this warning nor the separate historical recursive-layout finding is resolved. Keep the current player shell and the Apple Feedback draft; submitting it remains a separate action. This result rejects a complete SwiftUI rewrite as an evidence-backed warning fix.
