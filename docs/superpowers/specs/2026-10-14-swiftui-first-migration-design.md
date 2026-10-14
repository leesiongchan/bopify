# SwiftUI-first migration

Status: design and plans approved in chat; native execution completed 2026-10-15 with qualification gates retained. Audit baseline: `672e2cf` on `codex/public-distribution-integration`. The native player shell is retained. Qualification found and corrected a native menu-cell accessibility label; the SwiftUI control replacement remains deferred. Evidence is recorded in the popover and recovery-menu verification reports.

## Intent and constraints

Prefer supported SwiftUI APIs where they simplify Bopify without losing player behavior. Keep the existing macOS 14 minimum pending an explicit decision to raise it. Distribution remains a free, ad-hoc-signed GitHub release; this work changes neither signing nor playback/authentication policy.

Assumed behavior to preserve: a movable player that stays visible when another app activates, optional Keep on top, keyboard playback controls, current record/queue animations and position restoration, left-click status-item toggling and right-click menu access. A migration succeeds only when the same behavior and accessibility work through a smaller implementation. Removing every AppKit import is not a success criterion.

The open AppKit diagnostics are a separate problem. Existing minimal SwiftUI popover content hosted in both an ordinary window and a nonactivating panel reproduces the transaction warning. The warning also reproduced in six validated binding-dismissal runs with a fully declarative SwiftUI App/Window on macOS 27.0.1. Outside-click qualification remains unavailable. Framework choice alone is not evidence of a fix; see [declarative popover evidence](../verification/2026-10-14-swiftui-scene-popover-evidence.md).

## Approaches and decision

1. **Incremental SwiftUI migration, recommended.** SwiftUI continues to own content and presentation state. Replace individual native controls/gestures only after proving their required behavior. Retain the native boundaries with unmatched public APIs. This permits small, reversible diffs and preserves macOS 14.
2. **Raise the minimum to macOS 15.** Unlocks native SwiftUI window dragging, pointer events and additional window styling. It can remove drag adapters after runtime qualification, but does not remove the persistent nonactivating panel or raw wheel boundary. Raising further has no verified benefit for those gaps.
3. **Replace the complete shell.** A stock MenuBarExtra or UtilityWindow changes the current player contract. UtilityWindow hides when inactive; MenuBarExtra's window style is popover-like. This requires an explicit product redesign, and offers no demonstrated diagnostic fix.

Choose approach 1. Approach 2 remains optional; do not introduce parallel implementations merely to use a newer API. Approach 3 is outside the preserved behavior in this design.

## Component decisions

| Current component | Public SwiftUI candidate | Decision and qualification |
|---|---|---|
| StatusPanel / PlayerWindowController | Window, UtilityWindow, scene window modifiers | Retain. No equivalent was verified for nonactivating keyboard-capable persistence, all-Spaces/fullscreen behavior, exact live frame changes around a fixed spindle, or custom screen clamping/restoration. UtilityWindow's hide-on-inactive behavior conflicts directly. |
| StatusItemController | MenuBarExtra (macOS 13+) | Retain status-item routing. No equivalent distinct left/right status-icon actions was found in the installed public interface. Do not substitute a popover for the movable player. |
| WindowDragRegion | WindowDragGesture and allowsWindowActivationEvents (macOS 15+) | Strongest direct migration candidate if 15 is approved. First prove startup dragging, then listening background dragging. Preserve control precedence, native focus, cancellation, attention holds and release-time position persistence. |
| PlayerBackgroundDragRegion | WindowDragGesture with GestureState (15+) | Requires qualification across sleeve, queue, empty library and control gaps. Current 4-point threshold has no exposed equivalent gesture configuration. Cancellation must release the drag hold even without onEnded. |
| RecordPointerRegion | SpatialEventGesture (15+) | Defer until drag qualification. Preserve immediate press freeze, 4-point scrub activation, cancellation and exactly one seek on release. SwiftUI global coordinates are root-view coordinates; screen-space rebasing on native window relocation still needs a bridge. |
| CompactPlaybackConnectionMenu | Menu with Button actions (14 supported) | First control feasibility candidate on the current minimum. Prove fit/accessibility/action dispatch before replacement. Current native wrapper fixes a measured 106-point intrinsic width against a 94-point capsule. A compile-only Menu does not establish parity. Match the existing StationMenu styling pattern when testing. |
| VerticalVolumeSlider | Slider, possibly rotated | Retain. No public vertical axis/style was found in the installed interface. Rotation does not prove vertical keyboard or accessibility semantics, or current final-flush/cancellation behavior. Do not hand-roll a slider merely to remove NSSlider. |
| CoverFlowInput | FocusState/onKeyPress (14), SpatialEventGesture (15), ScrollView | Retain raw wheel input. No public equivalent callback was found for precise/coarse deltas, phases and momentum outside a ScrollView. A snapping ScrollView would redesign the carousel's spring/input behavior. Defer pointer/keyboard splitting until it produces a demonstrated simplification. |
| LibrarySetupWindowController | Unique Window with openWindow/dismissWindow (13/14) | Secondary candidate. Prove hidden startup, repeated centering/activation, draft retention and save dismissal before replacement. The existing controller is only 23 lines; adding a scene-action bridge without removing complexity is not a win. |

Keep appropriate platform services: NSWorkspace sleep/wake notifications, the backend's injected URL launcher, NSPasteboard for Copy, and NSImage at Nuke/MediaPlayer boundaries. Scene phase is not machine sleep/wake, and PasteButton would not replace the Copy action.

## Execution sequence

### 1. Establish framework-warning evidence independently

Create an account-free, throwaway pure SwiftUI App/Window popover fixture to complement the existing hosting-controller fixtures. Exercise explicit binding dismissal and normal outside-click/system dismissal. Capture complete process-scoped diagnostics and validate that each popover actually opened and closed. Run on the affected OS; a second supported OS is required before making an OS-specific claim.

No Spotify session, output device, credential or installed app needs to change. The probe answers whether fully declarative ownership changes the warning. It does not authorize a player-shell rewrite or prove app-wide parity. If it reproduces, retain the minimal evidence for an Apple report; submission needs separate authorization. If it does not reproduce, investigate the lifecycle difference before modifying Bopify.

### 2. Qualify the compact recovery menu on macOS 14

Use an account-free fixture with the current recovery states and real action callbacks. Capture before/after screenshots and verify the 94-point capsule, long labels, permanent-error icon, full accessible name/help, keyboard opening and action selection. Exercise Retry now, Retry restoration and Reconnect Spotify using fake services; ensure each dispatches once and the panel frame stays stable.

Adapt the relevant portion of PlaybackRecoveryProbe to observe behavior rather than NSPopUpButton selectors. Its existing native checks establish the baseline, not evidence that a SwiftUI replacement works. Replace only CompactPlaybackConnectionMenu after the candidate passes; otherwise record the failed requirement and keep the current adapter.

### 3. Optional macOS 15 gesture migration

Proceed only if the minimum-OS change is approved. Start with the startup WindowDragRegion, then qualify PlayerBackgroundDragRegion at every caller. Use the existing presentation and setDragging boundary rather than adding a new input abstraction. Compare first-click, normal drag, sub-threshold movement, release, cancellation, detachment, interactive controls, scrolling, compact/expanded/queue transitions, Spaces and stored anchor position.

RecordPointerRegion follows only if the drag migration passes and a small screen-position bridge preserves rebasing. Do not combine the volume slider, carousel redesign or player window replacement into this change.

## Verification and stop conditions

- Compile on the retained minimum OS and use Swift 6 warnings-as-errors for API probes. Availability checks do not prove runtime behavior.
- Run the affected package tests, including RecordLayoutTests and PlayerPresentationTests when gestures/window behavior changes, and a fresh app build.
- Verify UI visually before and after each replacement, plus keyboard and accessibility behavior in its account-free fixture. A runtime check on macOS 14 remains required if support is retained; targeting 14 with a newer SDK is insufficient.
- Reject a candidate that loses focus/keyboard access, strands an interaction hold, changes the spindle anchor, expands the capsule, duplicates actions or requires more custom code to recreate native behavior.
- Keep warning reproduction results separate from migration results. Neither a clean compile nor removal of an AppKit wrapper closes the diagnostic gate.
- Historical MonolithRefinementProbe and MonolithInputRoutingProbe contain obsolete APIs. Adapt and run them before relying on their older pass reports.

## Evidence and primary sources

Audit read all six NSViewRepresentable types and their callers, existing geometry/presentation tests, native probes and relevant git history. Local compile-only probes in `/private/tmp/bopify-swiftui-audit` checked current installed Xcode 27 interfaces. No GUI, account or audio-device changes occurred during the audit. Temporary probes are not shipping code or runtime acceptance evidence.

Primary API research checked 2026-10-14; minimum versions above were also checked against the installed SDK declarations.

- Apple, active SwiftUI/AppKit interoperability: [SwiftUI](https://developer.apple.com/swiftui/).
- Apple, UtilityWindow lifecycle: [UtilityWindow](https://developer.apple.com/documentation/swiftui/utilitywindow).
- Apple, menu versus popover-like window status items: [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra).
- Apple, macOS 15 window APIs: [Tailor macOS windows with SwiftUI, WWDC24](https://developer.apple.com/videos/play/wwdc2024/10148/).
- Apple, native window-drag gesture: [WindowDragGesture](https://developer.apple.com/documentation/swiftui/windowdraggesture).
- Apple, pointer event phases: [SpatialEventGesture](https://developer.apple.com/documentation/swiftui/spatialeventgesture).
- Apple, root-view coordinate space: [CoordinateSpace.global](https://developer.apple.com/documentation/swiftui/coordinatespace/global).
- Apple, keyboard delivery: [onKeyPress](https://developer.apple.com/documentation/swiftui/view/onkeypress(keys:phases:action:)).
- Apple, standard menu composition: [Menu](https://developer.apple.com/documentation/swiftui/menu).
- Apple, slider editing callbacks: [Slider](https://developer.apple.com/documentation/swiftui/slider).
- Apple, declarative window scene: [Window](https://developer.apple.com/documentation/swiftui/window).
- Apple, explicit launch suppression on macOS 15: [defaultLaunchBehavior](https://developer.apple.com/documentation/swiftui/scene/defaultlaunchbehavior(_:)).
