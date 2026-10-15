# AppKit recursive-layout warning disposition

Investigated 2026-10-15 in the isolated public-distribution integration worktree at `ffcf0dd`. Host: macOS 27.0.1 (26A434), Xcode 27, Swift 6.4, arm64. Every new control targets macOS 26.0. The release candidate rc4 remains unchanged.

## User decision — 2026-10-15

The user confirmed that only the current macOS 27 Mac is available and explicitly instructed not to send feedback. Keep the evidence bundle and draft local; no report was submitted. Apple Feedback reached its sign-in page only, and the isolated browser session was closed. macOS 26 runtime acceptance remains unverified. The earlier submission recommendation below is superseded by this decision.

## Finding

No verified application fix was found. The warning reproduces with both a minimal public NSStatusItem and a declarative SwiftUI MenuBarExtra. Configuring the native image while the item is hidden does not reliably prevent it. The strict application diagnostic gate remains open. This is evidence of a framework path independent of Bopify, not an Apple-confirmed defect or proof of harmlessness.

The existing [72-frame stack](appkit-layout-2026-10-12/recursive-view.lldb.log) identifies NSNextStepFrame in NSStatusBarWindow: FrontBoard scene-settings update, AppKit layout, frame-change notification, AppKit observer changing the window frame, then nested layout. Bopify's panel, saved-frame restoration, animations, menus and playback are unnecessary to reproduce that captured failure. Production already creates the status item in applicationDidFinishLaunching. Earlier activation-policy, creation-time, square-length and expanded-delegate controls are recorded in the [previous investigation](2026-10-12-appkit-layout-investigation.md); those were not repeated as new fixes.

## Bounded fresh controls

Serial fresh processes, no account, browser, Keychain, Spotify or audio. Each item variant stops at its first observed warning or after 20 launches; the SwiftUI no-item control runs three times. These are falsification attempts, not comparative failure-rate estimates. Each process collects its own logs for three seconds and requires a start marker; exits 0/1/2 mean clean observation/reproduced diagnostic/invalid collection. All 28 observations were valid.

| Control | Launches | Warning launches | Result |
| --- | ---: | ---: | --- |
| Native public status item, image assigned normally | 1 | 1 | Reproduced at current deployment target |
| Same, hidden before image configuration and shown afterward | 4 | 1 | Visibility staging is not a reliable fix |
| SwiftUI App owning standard MenuBarExtra | 20 | 1 | Declarative ownership is not a reliable fix |
| SwiftUI Settings-only App, compiled without MenuBarExtra | 3 | 0 | Bounded no-item observation |

The SwiftUI control's first 19 launches were clean; launch 20 captured the same AppKit WarnOnce message 129 ms after its start timestamp. That process preserved 254 scoped log records and observed two status-bar windows. The Settings-only control observed none. These window class names are diagnostic observation through public NSApplication.windows, not production API dependencies. SwiftUI owns construction; the fixture never creates or mutates an NSStatusItem, NSWindow, NSPanel or hosting controller. AppKit imports only support process-local observation. No interface was opened and no global input was posted. This does not qualify a complete SwiftUI product shell's interactions or the separate popover transaction warning.

Both controls use ad-hoc hardened-runtime signatures, verified strictly, and no entitlements. They isolate the framework but do not reproduce the release app's sandbox configuration. The native fixture adds only the staged visibility option; its baseline path remains the original public initialization. All fixture builds treat warnings as errors.

Evidence retained privately in `/private/tmp/bopify-appkit-disposition-20261015/`: exact sources, source hashes, build logs, Info.plists, matrix-summary.json, stdout/stderr for each launch and all SwiftUI process log JSON files. The durable fixture sources are [AppKitStatusItemRepro.swift](AppKitStatusItemRepro.swift) and [SwiftUIStatusItemRepro.swift](SwiftUIStatusItemRepro.swift).

## Current recovery-probe attribution

A fresh current-source recovery executable was compiled with the same production source/object inputs as run-monolith-probe.py, targeting 26.0. Its source manifest and debugger logs are in `/private/tmp/bopify-appkit-current-stack-20261015/`. Debugger attempts are observations, not normal release acceptance: breakpoint hits deliberately terminate that isolated fake-engine process after capture, and clean debug runs cannot disprove the intermittent warning. Three bounded fresh launches reached the end of all recovery behavior and strict diagnostic assertions with probe exit 0, but none hit the breakpoint. LLDB then returned 1 because its requested backtrace had no stopped process; this is not a captured stack. All three full logs are retained. The earlier positive current-menu recovery runs remain failed diagnostic evidence, and this follow-up does not establish the exact receiver of those particular warnings. Further same-host retries were stopped rather than collecting more clean runs.

## Reproduction

Compile the SwiftUI fixture with Swift 6, MainActor default isolation, warnings as errors and `-target arm64-apple-macosx26.0`. Place it in an app bundle with CFBundleExecutable, a unique CFBundleIdentifier, CFBundlePackageType=APPL, LSUIElement=true and LSMinimumSystemVersion=26.0; ad-hoc sign with hardened runtime. Run its executable with `item /absolute/output/log.json`. Compile the same source with `-D NO_ITEM` for the Settings-only control and run with `noitem /absolute/output/log.json`. Retain return codes as well as stdout; a reproduced warning intentionally returns 1. Run serially on a logged-in desktop.

The native reproduction uses the same compiler target and bundle configuration. `staged` hides the newly created item, assigns the same symbol, then shows it; omitting that argument gives the baseline. This is a diagnostic option, not a product workaround. Existing expanded-delegate registration requires the macOS 27 SDK/runtime and remains separately qualified in the older report.

## Remediation and release decision

Retain the minimal native shell for its persistent, movable panel behavior. The new evidence does not justify switching that shell to SwiftUI as a warning fix. Supported remediation is a verified public-API workaround or an OS/framework correction. No such fix has been established here; suppressing the message or passing a later clean run would not resolve it. No app-owned cause was identified in the captured recursion path.

Prepare Apple Feedback with both standalone sources, exact OS/compiler/signature metadata, the retained recursive-view stack and the positive native/staged/SwiftUI outputs. The local evidence bundle `build/diagnostics/Bopify-AppKit-layout-evidence-2026-10-15.zip` contains standalone sources, bundle plists, compiler/source metadata, all 28 matrix stdout logs, exact positive diagnostics and the earlier captured stack. It excludes credentials and application binaries. Its manifest verifies the evidence members. A ready-to-submit Apple Feedback draft is included for review. No report was sent. Test the same controls and rc4 on macOS 26 or another clean supported host next. That comparison is unavailable on this macOS 27-only host and is required before claiming supported-OS release acceptance. The warning remains a strict failed gate until fixed or the user explicitly accepts a documented framework limitation after impact testing. No merge, push, release publication or waiver was performed.

## Primary sources checked 2026-10-15

- Apple, [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra): the public declarative menu-bar scene used by the standalone control.
- Apple Developer Forums, [Layout recursion error message](https://developer.apple.com/forums/thread/806471), November 2025–April 2026: reports include a suspected status-button connection; Apple's accepted answer explicitly does not resolve the original issue and discusses console filtering. It supplies no verified workaround or harmlessness determination for this warning.
- Apple, [Modernize your AppKit app](https://developer.apple.com/videos/play/wwdc2026/289/) and [expandedInterfaceDelegate](https://developer.apple.com/documentation/appkit/nsstatusitem/expandedinterfacedelegate): modern focus/session integration, already tested for startup registration in the prior investigation; not a verified recursion fix and available only on macOS 27.
