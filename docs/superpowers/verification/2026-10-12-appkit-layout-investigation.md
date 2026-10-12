# AppKit status-item layout investigation

The recursive-layout warning remains unresolved. The current evidence isolates a failing path in AppKit's status-item window using public status-item APIs, without Bopify's player, panel, SwiftUI, Spotify, or credentials. No production implementation or diagnostic assertion was changed. This does not establish harmlessness, a regression from another OS version, or an Apple-confirmed defect.

Environment: macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), arm64, logged-in desktop. Base application revision: `27f2339`. All runs below are account-free.

## Fresh observations

The development-signed, hardened-runtime accessory control creates only a variable-length status item with a system `music.note` image. Its bundle sets `LSUIElement=true`. The signature passed `codesign --verify --strict`; the control has no sandbox entitlements, so it is not an entitlement-equivalent production acceptance run.

Twenty serial pairs alternate baseline and expanded-delegate registration in fresh processes. No other GUI probe ran concurrently with this paired matrix. Each process observes its own unified logs for three seconds, verifies a start marker, and exits 1 on the layout warning, 2 on diagnostic-collection failure, or 0 when the observation window is clean.

| Control | Launches | Launches with warning | Diagnostic failures |
| --- | ---: | ---: | ---: |
| Image, baseline accessory | 20 | 2 (runs 4, 7) | 0 |
| Same image, expanded delegate registered | 20 | 2 (runs 4, 13) | 0 |

[All per-process outputs](appkit-layout-2026-10-12/matched-runs.log) and [exit/count results](appkit-layout-2026-10-12/matched-results.csv) preserve this matrix. These counts describe this sample; they do not estimate a general failure rate or prove the two variants equivalent. Registering the newer delegate does not reliably prevent the warning.

An earlier serial signed matrix observed no warning in four no-item, four no-image, and four expanded-registration launches, but one warning in four baseline image launches. The later failures invalidate treating those four clean expanded runs as a workaround. A variable-length item without an image may change visibility and geometry; its clean sample does not establish that image rendering is the root cause. Earlier unsigned activation-policy/creation-time controls were exploratory and partly overlapped the recovery probe; they are not used to compare failure rates.

## Exact recursive view

The [exact captured frame-notification helper source](appkit-layout-2026-10-12/CapturedFrameControl.swift) is retained verbatim as an experimental artifact, separate from the maintained reproduction. It was compiled with Swift 6, MainActor default isolation, and warnings as errors. The account-free helper was run with the `regular` argument separately under LLDB with a breakpoint on `_NSDetectedLayoutRecursion`. Its 72-frame stack contains the nested view-layout and frame-notification path entirely in Apple frameworks, then the normal application run loop. The captured receiver is `NSNextStepFrame`; its window is `NSStatusBarWindow`. No application window is created by this control.

[Full captured stack, disassembly, and receiver inspection](appkit-layout-2026-10-12/recursive-view.lldb.log) show:

1. FrontBoardServices delivers a scene-settings update into AppKit.
2. AppKit changes the window frame and displays/layouts its view tree.
3. A layout-driven view-frame change posts a notification; an AppKit observer changes the window frame again.
4. The nested window layout re-enters the same frame view and reaches `_NSDetectedLayoutRecursion`.

For this exact arm64 OS build, frame 2's disassembly stores its receiver at `sp + 0x28` before calling `NSPerformVisuallyAtomicChange`. Inspecting that slot yields the frame view. The independently captured receiver at `x19 + 0x20` yields the same object. These offsets are debugger evidence for this build, not supported API or portable production logic. The debugger process was intentionally killed after capture; its exit is not a successful runtime test.

Public frame-change notification instrumentation observed only the status-item window's internal views during this failure. Instrumentation and LLDB can change timing; the uninstrumented signed matrix independently reproduced the same warning.

## Modern API assessment

Apple recommends expanded-interface sessions so AppKit knows when a status item's custom window is active and can manage keyboard focus. Applications show/hide their interface in delegate callbacks and cancel the session when finished; the system can also cancel it when focus moves elsewhere. [Modernize your AppKit app — WWDC26, keyboard navigation and status items](https://developer.apple.com/videos/play/wwdc2026/289/).

The macOS 27 SDK declares the weak `expandedInterfaceDelegate` property and delegate callbacks as available on macOS 27. [expandedInterfaceDelegate — Apple Developer Documentation](https://developer.apple.com/documentation/appkit/nsstatusitem/expandedinterfacedelegate). Availability was also checked in the installed SDK's `AppKit.framework/Headers/NSStatusItem.h` on 2026-10-12.

The reproduction's `expanded` option registers a retained delegate with no-op callbacks, without user interaction or an expanded window. It tests registration during status-item startup, not complete adoption or keyboard behavior. Both variants still warn before any custom window exists. A production migration must separately reconcile Bopify's persistent, movable panel with session cancellation on focus changes; it is not justified as a recursion fix by this evidence.

## Reproduce and capture

Use Xcode 27 or newer on a logged-in desktop; compiling the optional delegate control requires the macOS 27 SDK. The `expanded` option rejects older runtime versions. No real account or application build is needed. The command below targets arm64 macOS 14, matching the application deployment target; executing the resulting binary on an older OS has not yet been verified.

```sh
swiftc -target arm64-apple-macosx14.0 -module-cache-path /private/tmp/bopify-appkit-module-cache -parse-as-library -swift-version 6 -default-isolation MainActor -warnings-as-errors docs/superpowers/verification/AppKitStatusItemRepro.swift -o /private/tmp/bopify-appkit-statusitem-repro
/private/tmp/bopify-appkit-statusitem-repro
/private/tmp/bopify-appkit-statusitem-repro expanded
/private/tmp/bopify-appkit-statusitem-repro noitem
/private/tmp/bopify-appkit-statusitem-repro square noimage
```

The default installs after launch with accessory activation policy. `regular`, `prelaunch`, and `square` remain available as controls. Run variants serially in fresh processes and retain both stdout and exit status. A clean three-second run does not disprove an intermittent warning.

To repeat the signed accessory setup, use the retained [control Info.plist](appkit-layout-2026-10-12/Control.Info.plist) and a locally available Apple Development signing identity. This creates a diagnostic app in temporary storage; it does not install or distribute Bopify.

```sh
mkdir -p /private/tmp/bopify-appkit-control/Control.app/Contents/MacOS
cp docs/superpowers/verification/appkit-layout-2026-10-12/Control.Info.plist /private/tmp/bopify-appkit-control/Control.app/Contents/Info.plist
cp /private/tmp/bopify-appkit-statusitem-repro /private/tmp/bopify-appkit-control/Control.app/Contents/MacOS/Control
codesign --force --options runtime --timestamp=none --sign 'Apple Development' /private/tmp/bopify-appkit-control/Control.app
codesign --verify --strict /private/tmp/bopify-appkit-control/Control.app
/private/tmp/bopify-appkit-control/Control.app/Contents/MacOS/Control
/private/tmp/bopify-appkit-control/Control.app/Contents/MacOS/Control expanded
```

For the paired matrix, alternate baseline and `expanded` in twenty fresh-process pairs, keeping each process's output and return code (1 is an observed warning, not a runner failure):

```python
from pathlib import Path
import subprocess

exe = "/private/tmp/bopify-appkit-control/Control.app/Contents/MacOS/Control"
output = Path("/private/tmp/bopify-appkit-paired-runs")
output.mkdir(exist_ok=True)
for run in range(1, 21):
    for case, args in [("image", []), ("expanded", ["expanded"])]:
        result = subprocess.run([exe, *args], capture_output=True, text=True, timeout=20)
        (output / f"{case}-{run}.log").write_text(result.stdout + result.stderr)
        print(case, run, result.returncode)
```

The final fixture compiled under Swift 6 with warnings treated as errors. [Fresh fixture smoke outputs](appkit-layout-2026-10-12/final-fixture-smoke.log) reproduced the warning with exit 1 in default, expanded-registration, and regular/prelaunch cases; no-item and square/no-image cases returned 0. All five cases reported the correct exit/count relationship. These smoke runs used an unsigned command-line executable and are separate from the signed paired matrix.

To reproduce the instrumented capture, compile `appkit-layout-2026-10-12/CapturedFrameControl.swift` with the same Swift flags, then launch that executable in LLDB and set `target.run-args regular`. The retained full log includes the original launch, notification output, and debugger commands; unrelated Intents and window-tab messages came from this bare debugger helper. To capture a stack without instrumentation, launch the maintained reproduction in LLDB, set `target.disable-aslr` to false if required by the host, set a breakpoint on `_NSDetectedLayoutRecursion`, and run. On a hit, use `thread backtrace -c 120`. If a process exits without hitting the breakpoint, start a fresh process. Identify the receiver from that build's disassembly rather than assuming the register/stack offsets above are stable.

## Recovery UI and release gate

The unchanged full offline recovery UI probe passed once on this host, including compact/expanded/queue states, 100 replacements plus 10 failed creates, animation interruption/dismissal, and the existing warning assertion. [Captured output](appkit-layout-2026-10-12/recovery-ui.log).

```sh
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-audio-debug-build --output /private/tmp/bopify-appkit-20261012-recovery --probe recovery
```

One clean recovery run is not a warning fix. Keep the existing diagnostic assertion and the unresolved warning as a release gate. Next, compare this reproduction and the installed signed app on another supported macOS build or a clean host session, then validate any supported workaround against repeated status-item launches and the recovery UI probe. Installed-app Keychain access, audible physical audio recovery, and distribution/notarization acceptance also remain separate gates.

## Apple Feedback draft (not submitted)

Title: Public NSStatusItem startup can recursively lay out NSStatusBarWindow's frame view on macOS 27.0.1.

Expected: Creating a standard status item and assigning a system image completes without recursive layout.

Actual: Some fresh launches emit the warning below before any custom window or expanded interface is shown. The minimal AppKit-only reproduction and attached stack isolate the nested layout to the status-item window. Registering the macOS 27 expanded-interface delegate also reproduces the warning.

```text
It's not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out.  If you are implementing the view's -layout method, you can call -[super layout] instead.  Break on void _NSDetectedLayoutRecursion(void) to debug.  This will be logged only once.  This may break in the future.
```

Attach `AppKitStatusItemRepro.swift`, this report, the paired matrix outputs/results, and the captured helper source and recursive-view LLDB log. The original signed matrix used the same creation/delegate logic before the fixture gained an explicit older-runtime rejection; all observations were on macOS 27.0.1. The frame-notification helper used only public notifications; its extra instrumentation is not needed to reproduce the warning. Committed text logs normalize line endings and trailing whitespace only. No report has been sent, and no Apple acknowledgement or resolution is claimed.
