# Monolith Player Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the listening UI with the approved Monolith vinyl object, revealing a Liquid Glass control sleeve on engagement and receding to a record when unattended.

**Architecture:** Keep playback authoritative in `PlayerModel` and retain the existing AppKit panel/SwiftUI composition. Add deterministic attention and geometry models, demonstrate native window behavior before visual integration, then compose one record and one expanding sleeve. Auth, startup restore, Spotify integration, and Rust remain unchanged.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Observation, Swift Testing, existing native probe tools; macOS 14 deployment floor, native Liquid Glass on macOS 26+.

**Spec:** [2026-09-26-monolith-player-design.md](../specs/2026-09-26-monolith-player-design.md), approved 2026-09-27. Read it and its [interactive study](../specs/assets/2026-09-26-monolith-study.html) before execution.

## Global Constraints

- No new package dependency is required.
- Hover reveals controls; click or keyboard focus keeps them open.
- Both pointer and focus must leave before the 280 ms collapse grace period begins; active interactions also hold the interface open.
- Record diameters: 118 pt resting, 182 pt focused; initial focused content envelope approximately 460 × 240 pt, queue approximately 400 pt tall.
- Primary transport targets are at least 40 pt, play/pause 48 pt, secondary controls at least 28 pt, and secondary text approximately 12 pt.
- Keep the existing deliberate 250 ms hold before radial dragging; commit one seek on release; accessible increments are five seconds.
- Ambient reflection takes approximately 24 seconds per revolution; never spin the artwork label.
- Native regular Liquid Glass on macOS 26+, system material on older supported macOS versions, opaque semantic surfaces for reduced transparency.
- Preserve `PlayerMode` raw values and legacy placement compatibility; engagement and mute memory are transient.
- Preserve current `PlayerContent` precedence and engine-owned paused startup restore. Revealing, focusing, or moving the player must not issue playback commands.
- No new auth, playback backend, queue editing, remote takeover, or startup-restore feature.
- Use existing `BopifyLog` categories at state/command boundaries, never per frame or pointer move.
- Read and preserve the user's existing `Localizable.xcstrings` edits; add only the strings the new controls require.

## Review Focus

1. Pointer movement during window expansion must neither steal another app's focus nor leave an invisible window intercepting clicks after collapse — native two-window/two-process checks in Task 2.
2. Duplicate Spotify URIs, same-image tracks, and engine replacement must not confirm the wrong queue occurrence or reuse stale artwork — model tests in Task 3 and rendering probes in Task 4.
3. Startup outcome/metadata arrival order must preserve paused and remote states without briefly exposing the URI form or sending transport commands — integration fixtures in Task 5.
4. Popovers, VoiceOver, seek/volume drags, and rapid focus changes must not collapse controls during input or leave a permanent hold — attention tests in Task 1 and native interaction checks in Tasks 5–6.
5. Negative-origin displays, tiny visible frames, high contrast, and long localized text must keep controls reachable and readable — geometry tests in Task 2 and native captures in Task 6.

---

## File map and execution order

| Files | Responsibility |
| --- | --- |
| New `Packages/BopifyCore/Sources/BopifyPlayback/PlayerAttentionState.swift` | Pure engagement state/deadline rules |
| Existing `Packages/BopifyCore/Sources/BopifyPlayback/PlayerPresentation.swift` | Observable attention adapter, effective mode, queue visibility; retain startup content classifier |
| New `Packages/BopifyCore/Sources/BopifyPlayback/MonolithLayout.swift` | Pure layout, screen placement, anchor conversion |
| New `Bopify/Bopify/MenuBar/MonolithWindowController.swift` | Native frame envelope, transition completion, anchor persistence, pointer tracking |
| Existing `Bopify/Bopify/MenuBar/StatusPanel.swift`, `StatusItemController.swift` | Key/drag/menu lifecycle and window controller integration |
| Existing `Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift` | Confirmed mute memory and queue-selection result |
| New `Bopify/Bopify/Views/VinylRecordView.swift` | Vinyl material, upright center label, reflection and track transition |
| Existing `Bopify/Bopify/Views/ArtworkMorphState.swift`, `MorphingArtworkView.swift`, `ArtworkStore.swift` | Shared artwork ownership, interrupted transitions and cache; change cache only if integration requires it |
| New `Bopify/Bopify/Views/MonolithPlayerView.swift` | Record/sleeve composition and playback/status layout |
| Existing `Bopify/Bopify/Views/{MiniPlayerView,PlayerSurface,TransportControls,RadialProgressView,FavoriteButton,QueueView,PlayerPreviews}.swift` | Auth/startup routing, materials, controls, queue, and fixtures |
| Existing `Bopify/Bopify/AppEnvironment.swift`, `Localizable.xcstrings` | Composition and required localized strings |
| New `Packages/BopifyCore/Tests/PlaybackTests/{PlayerAttentionTests,MonolithLayoutTests}.swift`; existing playback/presentation tests | Behavior and geometry verification |
| New `docs/superpowers/verification/{MonolithWindowProbe,MonolithVisualProbe}.swift`, `run-monolith-probe.py` | Native production-code verification without starting Spotify |

Tasks 1 → 2 establish interaction/window behavior. Tasks 3 and 4 supply model and visual behavior. Task 5 integrates those interfaces, then Task 6 verifies the whole result. Do not build a separate production animation framework or modify the Xcode project file merely to register Swift files: the app uses a filesystem-synchronized root group.

### Task 1: Deterministic attention and reveal state

**Files:** Create `PlayerAttentionState.swift` and `PlayerAttentionTests.swift` at the paths above. Modify `PlayerPresentation.swift` and `Packages/BopifyCore/Tests/PlaybackTests/PlayerPresentationTests.swift`.

**Interfaces:**
- Produce `public enum PlayerInteraction: Hashable, Sendable` with `seek`, `volume`, `windowDrag`, `popover`, `menu`.
- Produce `public enum PlayerAttentionEvent: Sendable` with `visibility(Bool)`, `pointer(Bool)`, `keyboardFocus(Bool)`, `accessibilityFocus(Bool)`, `interaction(PlayerInteraction, Bool)`, and `reset`.
- Produce `public struct PlayerAttentionState`: `public init()`, read-only `isRevealed: Bool`, `collapseDeadline: TimeInterval?`; mutating `update(_ event: PlayerAttentionEvent, at now: TimeInterval)` and `advance(to now: TimeInterval)`.
- Add `PlayerPresentation.sendAttention(_ event: PlayerAttentionEvent)`, `requestQueue(_ open: Bool)`, and `resetEngagement()`. `mode` remains observable; derive `.compact`/`.expanded`/`.queue` from attention plus queue request. Retain `dismissQueue() -> Bool` and legacy `setMode(_:)` for existing fixture callers during migration; production uses attention and `requestQueue` after Task 5.

- [ ] **1. Establish the baseline in an isolated implementation checkout.** Use the worktree skill at execution time. Read `git status`, preserve the user's localization change, and verify `artifacts/BopifyCoreFFI.xcframework` exists; run `./scripts/build-rust.sh` only if required build artifacts are missing. Run `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-monolith-tests`; record exit status and investigate pre-existing failures before edits.
- [ ] **2. Add failing pure-state tests with explicit time.** Include the following assertions, plus parameterized tests for each focus/interaction hold and reset while a deadline exists:

```swift
@Test func hoverRevealsAndDisengagementWaits280ms() {
    var state = PlayerAttentionState()
    state.update(.visibility(true), at: 0)
    state.update(.pointer(true), at: 0)
    #expect(state.isRevealed)
    state.update(.pointer(false), at: 1)
    #expect(state.collapseDeadline == 1.280)
    state.advance(to: 1.279)
    #expect(state.isRevealed)
    state.advance(to: 1.281)
    #expect(!state.isRevealed)
}

@Test func returningPointerInvalidatesOldDeadline() {
    var state = PlayerAttentionState()
    state.update(.visibility(true), at: 0)
    state.update(.pointer(true), at: 0)
    state.update(.pointer(false), at: 1)
    state.update(.pointer(true), at: 1.1)
    state.advance(to: 1.3)
    #expect(state.isRevealed)
    #expect(state.collapseDeadline == nil)
}
```

Tests named `overlappingHoldsReleaseIndependently`, `hiddenPanelClearsEveryHold`, `queueResetsAfterFullCollapse`, and `queueDismissesBeforePanel` must respectively assert that ending seek cannot clear a popover hold, hiding cancels the deadline/reveal, a subsequent reveal is expanded rather than queue, and `dismissQueue()` returns true once and false next. Retain all `PlayerContent` precedence tests.
- [ ] **3. Run** `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-monolith-tests --filter PlayerAttentionTests`. Expect missing-symbol failures for the new interfaces before implementing them.
- [ ] **4. Implement the state and adapter.** Use a set of active interaction kinds, not a single interaction boolean. `visibility(true)` alone does not acquire focus. Hidden/reset state ignores later stale interaction completions. In `PlayerPresentation`, use monotonic `ProcessInfo.processInfo.systemUptime`, one cancellation-aware task for the current deadline, and a generation guard; the task calls `advance` with actual current time. Cancel it on every newly evaluated deadline and on reset. Do not use sleeps in pure tests. Keep `isVisible` synchronized with visibility events and log only effective presentation changes.
- [ ] **5. Run** the attention and presentation suites using `--filter 'PlayerAttentionTests|PlayerPresentationTests'`; require zero failures. Confirm legacy raw-value decoding still accepts `expanded`, `compact`, and `queue`.
- [ ] **6. Commit** the attention model, adapter, and tests with subject `Model hover and focus driven player presentation`.

### Task 2: Anchored window geometry and an early native proof

**Files:** Create `MonolithLayout.swift`, `MonolithLayoutTests.swift`, `MonolithWindowController.swift`, `MonolithWindowProbe.swift`, and `run-monolith-probe.py`. Modify `StatusPanel.swift` for optional input callbacks. Leave the production UI on its existing composition until Task 5.

**Interfaces:**
- Produce `public struct MonolithLayout` with `contentSize: CGSize`, `recordCenter: CGPoint`, `recordDiameter: CGFloat`, `sleeveFrame: CGRect`, `controlsFrame: CGRect`, `queueFrame: CGRect`. All local rectangles/points use SwiftUI top-left coordinates.
- Produce `public func monolithLayout(mode: PlayerMode, availableSize: CGSize) -> MonolithLayout` and `public func monolithFrame(recordCenter: CGPoint, layout: MonolithLayout, visibleFrame: CGRect) -> CGRect`. The latter's input anchor and returned frame use AppKit screen coordinates.
- Produce `@MainActor @Observable final class MonolithWindowController`, `init(defaults: UserDefaults)`, `attach(to panel: StatusPanel)`, `apply(mode: PlayerMode, reduceMotion: Bool)`, `invalidateTransition()`, and `persistAnchor()`. Expose read-only `layout: MonolithLayout`, `contentOffset: CGPoint`, and `transitionID: UInt64` for the SwiftUI root. The controller owns native frame changes and the SwiftUI geometry transaction; views must not start a second attention animation.
- Add optional `StatusPanel` callbacks `onKeyChanged: ((Bool) -> Void)?`, `onPointerChanged: ((Bool) -> Void)?`, `onWindowDragChanged: ((Bool) -> Void)?`. Existing callers with nil callbacks remain valid.
- Probe runner contract: `python3 docs/superpowers/verification/run-monolith-probe.py --derived-data <directory> --output <directory> --probe window|visual|artwork`; compile/run the named probe, forward its exit status, print the capture/report path. `artwork` builds the existing `ArtworkMorphProbe.swift`; the other choices build the new named probes. Follow the existing `run-glass-morph-probe.py` source/link/resource discovery rather than inventing package linkage. It builds a separate app and never creates a live Spotify session.

- [ ] **1. Write failing geometry tests.** Test default record diameters 118/182; focused and queue record centers/control rectangles equal; centered expansion preserves the screen anchor within 0.5 pt; a right/bottom edge placement fits the visible screen; collapse uses the adjusted anchor rather than the original offscreen point. For `CGRect(x: -800, y: 100, width: 320, height: 480)`, assert the whole resulting frame is contained, every required control is reachable, and queue extent cannot push the transport offscreen. Test finite fallback for invalid saved coordinates and old-frame midpoint migration.
- [ ] **2. Run** `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-monolith-tests --filter MonolithLayoutTests`; expect failures for missing geometry functions.
- [ ] **3. Implement pure geometry.** At normal widths use 12 pt outer padding: resting content 142 × 142 with center (71,71); focused content 484 × 264 with center (116,132), queue content 484 × 424 with that same center. Use a sleeve starting behind the record and controls to its right, matching the approved proportions. At 320–483 pt available width, use a 118 pt record, reduce unused spacing, and wrap secondary controls while retaining minimum targets. If even that minimum layout cannot fit, use a scrollable controls viewport rather than shrinking text/targets. Clamp screen placement only after computing the local anchor; reduce queue height before moving the anchor. Test the top-left/AppKit y-axis conversion explicitly.
- [ ] **4. Implement the native controller and probe.** Before reveal, synchronously allocate a frame covering the old and target geometry; compensate content offset so the spindle does not jump. Animate SwiftUI geometry with the native spring transaction, then tighten the window when that transition completes. Ignore completions with an obsolete transition ID; no independent `setFrame(... animate: true)` animation. Retarget from the visible presentation on reversal. Reduced Motion sets target frame immediately and uses a 160 ms opacity transition.

Track pointer presence while the app is inactive using `NSTrackingArea` with `.activeAlways`, tracking only the visible object and the record-to-sleeve corridor. Do not rely on the enlarged transparent rectangle as a hover target. Confirm actual cross-window click behavior: `NSView.hitTest == nil` alone does not prove another app receives a click. The native probe must demonstrate click-through outside the resting object and correct focus transfer, using a separate controlled background-target process rather than arbitrary user applications.

Use `player.recordCenter` as the new serialized `NSStringFromPoint` preference. Prefer it when valid, otherwise use the midpoint of valid `player.frame`, otherwise first-open placement beneath the status item. Retain old keys; save only settled/dragged anchor, never transient envelope frames. Probe with an isolated defaults suite. During a window drag, hold reveal, suppress layout resizing under the pointer, and persist after release.
- [ ] **5. Run the geometry suite and app build**, then run the probe:

```bash
swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-monolith-tests --filter MonolithLayoutTests
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-monolith-build build
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-monolith-build --output /private/tmp/bopify-monolith-window --probe window
```

Require `MONOLITH WINDOW PASS`, zero exit status, and inspected captures. The probe asserts stable spindle coordinates through rest/focus/queue, 20 rapid interrupted reveals without stale shrink, no focus theft on hover, focus acquisition on click, queue clamping, and no interception of the background target after settling. Include center-click versus >4 pt center-drag distinction. Do not advance to visual integration if this checkpoint fails.
- [ ] **6. Commit** geometry, controller, callbacks, and probe with subject `Anchor Monolith transitions to the record center`.

### Task 3: Authoritative mute and queue selection feedback

**Files:** Modify `Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift` and `Packages/BopifyCore/Tests/PlaybackTests/PlayerModelTests.swift`.

**Interfaces:**
- Add `public func toggleMute()` and private session-local last-positive-confirmed-volume memory. Retain `setVolume(_:)`.
- Add `public enum QueueSelectionStatus: Equatable, Sendable { case idle; case pending(entryID: String, target: QueueTarget); case confirmed(entryID: String, target: QueueTarget); case failed }` and read-only observable `queueSelection: QueueSelectionStatus` on `PlayerModel`. Existing `selectQueueEntry(_ target: QueueTarget)` remains the entry point.

- [ ] **1. Extend the existing engine-spy tests.** Reuse the suite's event/command harness, not the real engine. For mute, assert confirmed 0.65 → mute requests 0; confirmation 0 → unmute requests 0.65; starting with confirmed 0 and no positive history → unmute requests 0.5; a later external 0.3 becomes the next restore target; inactive-device mute sends nothing. Assert neither the displayed volume nor icon state changes before `.volumeChanged`.

For queue selection create two same-URI entries with different IDs and targets. Assert `.pending(entryID: selected.id, target: selected.target!)` after dispatch, unchanged by `.trackChanged` alone, then `.confirmed(entryID: selected.id, target: selected.target!)` when a newer queue's current ID matches. In a separate attempt, a newer snapshot whose current is the other same-URI occurrence must fail the pending request rather than confirm it. Test stale generation, operation failure, rejection, stop/new model, and rapid replacement selection; an older command failure must not overwrite a newer pending selection.
- [ ] **2. Run** `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-monolith-tests --filter PlayerModelTests`; expect new tests to fail before implementation.
- [ ] **3. Implement the two behaviors at the existing model boundary.** Capture entry ID before dispatch; current-entry `target` is nil after navigation and cannot serve as confirmation. Keep command serialization and active-device checks. Tag queue-operation failure handling with the captured selection pair so stale failures do not corrupt a newer request. On `.queueChanged`, match stable occurrence ID, never URI alone; a newer generation with another current ID invalidates the pending request and uses the existing queue-changed notice. Retain existing command notices. Since `.commandRejected` has no command correlation, conservatively invalidate pending selection on rejection so later natural playback cannot falsely close the queue. Clear pending/result state and remembered mute volume on stop/player replacement. No Rust/FFI extension or optimistic playback state is required.
- [ ] **4. Re-run `PlayerModelTests`**, including `startupStaysPendingUntilTheEngineResolvesIt`; require zero failures and no changes to command order or restored paused position 1545 ms.
- [ ] **5. Commit** with subject `Track confirmed queue selection and session mute volume`.

### Task 4: Vinyl material and interruptible artwork motion

**Files:** Create `Bopify/Bopify/Views/VinylRecordView.swift`. Modify `ArtworkMorphState.swift`, `MorphingArtworkView.swift`, `PlayerPreviews.swift`, and `docs/superpowers/verification/ArtworkMorphProbe.swift`. Create `docs/superpowers/verification/MonolithVisualProbe.swift` with record fixtures; extend its scenarios in Tasks 5–6.

**Interfaces:**
- Produce `VinylRecordView(image: Image?, occurrenceID: String, direction: CarouselDirection, diameter: CGFloat, isPlaying: Bool, isVisible: Bool)`.
- Extend `ArtworkMorphState.transition` to `transition(to image: Image?, occurrenceID: String, direction: CarouselDirection, at date: Date, diameter: CGFloat)`; retain bounded `frames(at:)`, `generation`, and `finish()` semantics. Update all compiled callers.
- Evolve `MorphingArtworkView` to accept the same occurrence/direction inputs. Late image arrival for the same occurrence blends the label without replaying track navigation.

- [ ] **1. Extend the rendering probe before changing behavior.** Assertions: changing occurrence with the same image still starts a transition; same-occurrence metadata/image hydration does not start navigation; 100 interrupted transitions retain at most two live artwork layers; the composited image and pose are continuous at interruption; final frame is the most recently confirmed occurrence. Verify missing → loaded artwork keeps diameter/center unchanged. Use the existing `ImageRenderer` pixel-comparison approach rather than tests of SwiftUI internals.
- [ ] **2. Run** `python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-monolith-build --output /private/tmp/bopify-monolith-artwork --probe artwork` and require the new assertions or missing interfaces to fail before implementing them. This uses the standalone artwork probe, not a live player session.
- [ ] **3. Implement the record.** Use SwiftUI shapes/gradients for subtle grooves, graphite body, thin rim, shadow, and upright artwork. Keep the existing artwork cache/owner. Replace the old lens distortion with native animated scale/3D rotation/offset of the record's visual layers; use SwiftUI's interruptible springs rather than a new physics engine. Keep attention sizing separate from local track-transition transforms so concurrent reveal and track changes compose correctly. Preserve current pose when a new direction interrupts a transition; guard all completions by generation.

Choose initial durations within the approved ranges: reveal 0.65 s, recede/queue 0.50 s, track 0.65 s, button feedback 0.14 s, reduced motion 0.16 s. The window controller owns reveal/recede/queue timing. The record owns only track motion and the 24-second reflection. Pause/stop/hide/reduced motion stop the reflection timeline; pausing can settle over 0.16 s. An idle hidden view must not retain a frame-rate animation schedule.
- [ ] **4. Run the Task 2 app-build command, the Task 4 step-2 artwork command, and** `python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-monolith-build --output /private/tmp/bopify-monolith-record --probe visual`. Require zero assertion failures and inspect native captures of normal/missing art, playing/paused, repeated next/previous, same-cover duplicates, and interrupted motion under Reduced Motion. These are records/material fixtures at this stage, not the complete player.
- [ ] **5. Commit** with subject `Render a vinyl record with continuous track transitions`.

### Task 5: Integrate the sleeve, queue, and lifecycle

**Files:** Create `Bopify/Bopify/Views/MonolithPlayerView.swift`. Modify the existing view, menu, environment, localization, and preview files in the file map; extend `PlayerPresentationTests.swift` and both native probes. Remove old signed-in carousel/compact UI code only when this integration makes it unreachable; remove its unused gesture helper and tests in the same task. Do not delete unrelated older verification reports.

**Interfaces:**
- Produce `MonolithPlayerView(player: PlayerModel, store: ArtworkStore, presentation: PlayerPresentation, window: MonolithWindowController)`. Read authoritative state from the supplied player and use the controller's layout/content offset.
- Add `let monolithWindow: MonolithWindowController` to `AppEnvironment`, initialized with standard defaults. `StatusItemController` attaches its panel and calls `apply(mode:reduceMotion:)` only for the signed-in/current-track listening state; invalidate Monolith transitions before switching to the existing auth/startup/error-without-track shell.
- Change `QueueView` to `QueueView(player: PlayerModel, store: ArtworkStore, select: (QueueEntry) -> Void)`: scrolling rows only, no surface or embedded compact transport.
- Add `interactionChanged: (Bool) -> Void` to `RadialProgressView` with a default no-op for older fixtures; add `detailsChanged: (Bool) -> Void` to `FavoriteButton` similarly. Both emit balanced end events on cancellation/disappearance.

- [ ] **1. Add failing integration scenarios.** Extend the native fixture to assert commands are unchanged after status-item reveal, hover, focus, and drag. Feed startup pending → restored → track → paused(1545), pending → remote("iPhone"), and remote → error; assert the content matches existing `PlayerContent` tests, never flashes the context form, and never issues resume/activate/load. Preserve the current `AppEnvironment.connect()` behavior with no `activate()`.

Add pure radial assertions at the existing `radialProgress` boundary:

```swift
#expect(radialProgress(x: 0, y: -1) == 0)
#expect(radialProgress(x: 1, y: 0) == 0.25)
#expect(radialProgress(x: 0, y: 1) == 0.5)
#expect(radialProgress(x: -1, y: 0) == 0.75)
```

Retain zero/nonfinite rejection and crossing-start/end clamp tests. Native assertions: <250 ms ring click commits no seek; held drag commits exactly once; capability loss, occurrence replacement, or panel hiding cancels; center click never seeks or skips; center drag moves the window without playback commands.
- [ ] **2. Run the relevant presentation suite and native fixture against the old composition**; record expected layout/interaction failures before integration.
- [ ] **3. Compose the production Monolith.** Use one stable `VinylRecordView` and one `PlayerSurface` sleeve, with native regular glass and semantic accessibility fallbacks. Split primary transport from the secondary row without glass around every group. Bind mute/volume to Task 3, retain repeat's three states, and reuse favorites behavior. Move elapsed/total time into the sleeve and orient rim drawing, scrub angle, and knob geometry consistently at twelve o'clock. Keep all gestures/controls within the task-2 hit regions and avoid an overlay that intercepts center dragging.

Only a signed-in player with a current track enters Monolith. Keep `StartupContent`, URI entry, sign-in, and current no-track error behavior in their existing usable shell. Do not use `PlayerContent == .player` alone as proof a track exists: errors without metadata also return `.player`. Preserve status notices; use a quiet nonflashing rim indication at rest and full localized messages when engaged. Track data for a confirmed queue occurrence must use matching-URI `currentTrack` or that occurrence's hydrated metadata; show its placeholder rather than pairing stale artwork/title with a new identity. Reset view/selection/artwork state when the `PlayerModel` instance changes.
- [ ] **4. Wire native lifecycle and queue completion.** Key and pointer callbacks send Task 1 events; VoiceOver uses focus state on the record and descendants. Mark hidden controls inaccessible and non-hit-testable. Hold attention during seek, volume drag, window drag, favorites popover, and player-owned menu; clear on dismissal/disappearance. Escape lets the active popover handle dismissal, then calls `dismissQueue`, then hides the panel. Status-item opening still focuses the sleeve; hover never makes it key. Move keep-on-top to the status-item menu with a checked state and its existing preference key.

Queue selection stores the request pair in the view before calling `selectQueueEntry`; only a matching Task 3 `.confirmed` closes the extension. Failure keeps it visible with the model notice. Disengagement clears the view's pending close request so late confirmation cannot affect a later reopening; it does not cancel the engine command. Repeat requests for the same occurrence can remain one pending request. Queue rows scroll independently of the fixed record/transport.
- [ ] **5. Run package tests, app build, and both native probes.** Require no new failures. Verify 40/48/28 pt targets, keyboard order, Favorite permission/retry flow, missing artwork, queue loading/empty/failed metadata, inactive device, and the full default-state startup sequence. Add only required localization keys with existing project conventions and preserve the pre-existing localization diff.
- [ ] **6. Commit** with subject `Integrate the Monolith sleeve and focus driven controls`.

### Task 6: Native visual acceptance and regression closure

**Files:** Extend `MonolithVisualProbe.swift`, `MonolithWindowProbe.swift`, `PlayerPreviews.swift`; create `docs/superpowers/verification/2026-09-27-monolith-player.md` and relevant captures under `docs/superpowers/verification/assets/monolith/`. Make only fixes required by the checks below.

**Interfaces:** Final probes use production `StatusPanel`, `MonolithWindowController`, `MonolithPlayerView`, and `PlayerModel` with a stub engine; they exit nonzero on assertion failure and emit `MONOLITH WINDOW PASS` / `MONOLITH VISUAL PASS` only after completing all scenarios. Record unsupported/manual checks explicitly rather than treating screenshots as proof of them.

- [ ] **1. Run the interaction matrix.** Hover from another app; rapid leave/re-enter; click hold; keyboard traversal; VoiceOver focus; favorite popover; overlapping seek/popover holds; volume drag leaving the window; hide/sign-out during a hold; Escape hierarchy; center drag; keep-on-top; display disconnection; negative-origin screen; restored legacy frame. Assert no focus theft, no stranded hold, no hidden-control focus, and no stale completion frame shrink. Use a controlled background process for cross-app checks.
- [ ] **2. Capture and inspect the visual matrix.** Resting/focused/queue in light/dark appearance over light/dark wallpapers, Reduce Motion, Reduce Transparency, Increase Contrast, long localized titles/artists, missing art, rapid same-cover duplicate transitions, stale selection/rejection, empty/loading queue, and 320 × 480 available space. Compare to the approved HTML reference; explain material differences. ScreenCaptureKit own-process captures establish material appearance, while geometry captures alone do not.
- [ ] **3. Record interruption/motion evidence.** Sample native frames through reveal/recede/queue and rapid next-next-previous while resizing. Require continuous spindle/pose, at most two live artwork layers, no stale title/cover pairing, and no delayed command dispatch. Measure active timeline ticks with playing, paused, hidden, and Reduced Motion fixtures; paused/hidden/reduced-motion ambient tick count must stop increasing after settling. Remove temporary per-frame instrumentation after recording evidence.
- [ ] **4. Run final regression commands once fixes are complete:**

```bash
swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-monolith-tests
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-monolith-build build
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-monolith-build --output /private/tmp/bopify-monolith-window-final --probe window
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-monolith-build --output /private/tmp/bopify-monolith-visual-final --probe visual
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-monolith-build --output /private/tmp/bopify-monolith-artwork-final --probe artwork
git diff --check
```

Require zero exit status for every command; inspect full failure logs. A native interaction or accessibility check that cannot be run remains an explicit unresolved acceptance item, not an inferred pass. No Rust code changes are planned, so rebuilding/rerunning Rust is only necessary for missing artifacts or evidence of a bridge regression.
- [ ] **5. Write the verification report** with actual commands/results, inspected before/after captures, motion evidence, and any unresolved limitation. Mark the implementation complete only after required native checks pass, then commit with subject `Verify Monolith motion and native window interactions`.

## Native API references

- `.activeAlways` tracks the pointer regardless of application/key-window status: [Apple — NSTrackingArea options](https://developer.apple.com/documentation/appkit/nstrackingarea/options-swift.struct), consulted 2026-09-27.
- SwiftUI offers animation completion criteria/callbacks for coordinating the window envelope: [Apple — Animations](https://developer.apple.com/documentation/swiftui/animations), consulted 2026-09-27. Generation checks remain application responsibility.
- The spec's material, spring, fluid-interface, and accessibility sources apply throughout; no third-party animation or glass dependency is proposed.

## Review and execution handoff

Plan review and execution-method selection precede implementation. **Recommend Native execution**: these six tasks share attention, window, and view contracts, so one implementer can retain context while the native probe provides an early correctness checkpoint. Finish with an independent whole-branch review. Subagent-driven execution remains available for a separate implementer/reviewer cycle per task.
