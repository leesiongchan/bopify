# Quiet Lyric Ribbon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the approved native lyric-ribbon study with original sample words, simulated playback and verified reading/focus behavior.

**Architecture:** Keep the study in the existing app module behind `#if DEBUG`. Separate normalized cues, reading state, SwiftUI presentation and the AppKit panel; a fixture session owns the simulated clock and standalone launch path. Do not instantiate the live app environment in that path.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Observation and Swift Testing; existing macOS 26 and Apple Silicon targets, with no added dependencies.

**Spec:** [Approved native design](../specs/2026-10-17-lyric-ribbon-design.md). [Approved appearance](../../mockups/lyric-ribbon-retro.html).

## Global Constraints

- “The study remains a development preview, with no release menu item or automatic display during real music playback.”
- “The study exercises these outcomes with fixtures; it adds no network calls, credentials, persistence of lyric text or service dependency.”
- “Holding, scrolling, returning to live and closing the ribbon must never issue playback commands.”
- “Start with a 448-point width, approximately 23-point current text, 14-point previous text and a 24-point continuous corner radius.”
- “Keep this height stable during playback.”
- “Opening, hovering, dragging and clicking reading controls must preserve the front application's keyboard focus.”
- “Do not automatically announce each timed cue.”
- “Do not tie cue accuracy to Reduce Motion.”
- Preserve existing live player behavior and source files; only the Debug launch branch touches composition. No Spotify adapter, LRC parser, provider framework or package changes.
- Commit on `main` with Conventional Commits and push completed work directly to `main`, as required by `AGENTS.md`; no pull request.

## Review Focus

- Same recording with a new occurrence or session: clear held text before new metadata appears; Task 2 tests both identities independently.
- A canceled load completes late, including after hiding: reject its token; Task 2 exercises completion after replacement and hide.
- A long or right-to-left passage on a small display: retain all words, bounded geometry and usable controls; Tasks 3 and 4 cover measurement plus native inspection.
- Pause, correction and end while held: preserve the passage and show truthful playback status; Tasks 2 and 5 cover deterministic transitions.
- A passive ribbon click or hidden clock: keep the other app's typing focus and stop background ticks; Tasks 4 and 5 combine policy tests with native checks.

## File Map and Verification Setup

Create `Bopify/Bopify/Lyrics/` with `LyricDocument.swift` (normalization/projection), `LyricRibbonModel.swift` (reading state), `LyricRibbonLayout.swift` (text measurement), `LyricRibbonView.swift` (appearance), `LyricRibbonWindowController.swift` (panel/focus/frame) and `LyricRibbonPreview.swift` (fixtures/session/control window). Wrap these files and their new tests in `#if DEBUG`.

Create matching test files under `Bopify/BopifyAppTests/`: `LyricDocumentTests.swift`, `LyricRibbonModelTests.swift`, `LyricRibbonLayoutTests.swift`, `LyricRibbonWindowTests.swift` and `LyricRibbonPreviewTests.swift`. The synchronized app group already compiles into the hostless test target; only `BopifyApp.swift` is excluded. Do not edit `project.pbxproj` or import a nonexistent app module in these tests.

Modify `Bopify/Bopify/BopifyApp.swift` for isolated Debug startup and `README.md` for the preview command. Create `docs/lyric-ribbon-native-validation.md` for actual native check results. Use existing `BopifyLog.playback` for lifecycle logs without lyric text.

Before Task 1, read `AGENTS.md` and the spec, use the execution workflow selected by the user, and establish the required isolated working setup without creating a PR branch. Capture the current app appearance before UI changes. Verify the Rust XCFramework exists; run `./scripts/build-rust.sh` only if missing or incompatible. Xcode 27.0, the XCFramework and schemes `Bopify`/`BopifyAppTests` were found during planning; no product tests were run in the planning phase.

Use this command for each focused suite, adding `-only-testing:BopifyAppTests/<SuiteName>`:

```sh
xcodebuild -project Bopify/Bopify.xcodeproj -scheme BopifyAppTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/lyric-ribbon-study CODE_SIGNING_ALLOWED=NO test
```

Expected final output: `TEST SUCCEEDED` with the intended suite executed. A new missing-type compile error is the initial red check, never a passing result. If the sandbox prevents Xcode cache access, run through the available approval mechanism; do not change global caches or permissions.

## Task 1: Normalize and Project Original Timed Cues

**Files:** create `Bopify/Bopify/Lyrics/LyricDocument.swift` and `Bopify/BopifyAppTests/LyricDocumentTests.swift`.

**Interfaces:** internal value types, `Equatable` and `Sendable`; mark pure types `nonisolated` to match the app's MainActor-default build.

- `LyricCue(id: String, startMs: Int64, text: String)` represents one occurrence.
- `LyricCueGroup` exposes `startMs: Int64`, `occurrenceIDs: [String]`, `text: String`.
- `LyricDocument.init(cues: [LyricCue]) throws`; `groups: [LyricCueGroup]`; `project(positionMs: Int64, durationMs: Int64) -> LyricProjection`.
- `LyricProjection` exposes `interval: LyricInterval`, `current: LyricCueGroup?`, `previous: LyricCueGroup?`; `LyricInterval` is `.beforeFirst`, `.cue`, `.gap`, `.ended`.
- Normalization throws `LyricDocumentError.invalidTimestamp` for negative times and `.duplicateOccurrence` for duplicate IDs.

- [ ] **Step 1: Write failing `LyricDocumentTests` assertions.** Define a test-only `lyricTestDocument()` fixture with cues at 10,000, 20,000 (two distinct IDs), 30,000 (empty), 70,000 and 80,000 ms; duration 100,000 ms. Repeat the text at 10,000 and 70,000 with different IDs. Assert:

```swift
#expect(doc.project(positionMs: 9_999, durationMs: 100_000).interval == .beforeFirst)
#expect(doc.project(positionMs: 20_000, durationMs: 100_000).current?.occurrenceIDs == ["b", "c"])
#expect(doc.project(positionMs: 30_000, durationMs: 100_000).interval == .gap)
#expect(doc.project(positionMs: 99_999, durationMs: 100_000).current?.startMs == 80_000)
#expect(doc.project(positionMs: 100_000, durationMs: 100_000).interval == .ended)
```

Add assertions for unsorted input preserving source order at equal timestamps, repeated text retaining distinct IDs, empty documents, negative position clamping to zero, unknown duration not inventing an end, and both normalization errors.

- [ ] **Step 2: Run the focused suite and confirm the missing-type failure.**
- [ ] **Step 3: Implement the interfaces.** Stable-sort by timestamp and original index; join simultaneous text with newlines. A group containing only blank text is an explicit gap. Use standard array lookup for the latest timestamp at or before position; the previous group is the preceding timestamp. End only at a positive reported duration, not at the last cue's start. No external parser or timing library is needed for normalized in-memory fixtures.
- [ ] **Step 4: Rerun `LyricDocumentTests`; require all assertions to pass.**
- [ ] **Step 5: Commit only these files:** `feat: add fixture lyric timeline projection`.

## Task 2: Implement Reading State and Stale Result Protection

**Files:** create `Bopify/Bopify/Lyrics/LyricRibbonModel.swift` and `Bopify/BopifyAppTests/LyricRibbonModelTests.swift`.

**Consumes:** Task 1's document and projection.

**Produces:** `@MainActor @Observable final class LyricRibbonModel`, initialized with `init(snapshot: LyricPlaybackSnapshot)`. Snapshot is an `Equatable` value with `sessionID`, `occurrenceID`, `recordingID`, `title`, `artist` strings, `positionMs`, `durationMs` Int64 values, `isPlaying: Bool` and `seekRevision: UInt64`.

Expose read-only `snapshot: LyricPlaybackSnapshot`, `content: LyricContent`, `projection: LyricProjection?`, `isHeld: Bool`, `isVisible: Bool` and `scrollResetRevision: UInt64`; methods `update(_ snapshot: LyricPlaybackSnapshot)`, `show()`, `hide()`, `holdText()`, `backToLive()`, `beginLoad() -> LyricLoadToken`, `completeLoad(_ content: LyricContent, token: LyricLoadToken)`. `LyricContent` is `.loading`, `.timed(LyricDocument)`, `.plain(String)`, `.instrumental`, `.noMatch`, `.failure`. Token captures generation and session/occurrence identity. No playback engine is accepted by this model.

- [ ] **Step 1: Write failing `LyricRibbonModelTests`.** Load the Task 1 fixture at 72,000 ms and assert:

```swift
model.holdText()
model.update(at87Seconds)
#expect(model.isHeld)
#expect(model.projection?.current?.startMs == 70_000)
#expect(model.snapshot.positionMs == 87_000)
model.backToLive()
#expect(model.projection?.current?.startMs == 80_000)
```

Use full snapshot values for `at87Seconds`. Add named tests `correctionAndPausePreserveHold`, `seekRevisionReleasesHold`, `sameRecordingNewOccurrenceClearsHold`, `newSessionClearsHold`, `lateResultCannotReplaceNewOccurrence`, `hideInvalidatesPendingLoad`, `heldPassageSurvivesPlaybackEnd`, `plainAndUnavailableContentDisableHold`, and `reopenProjectsCurrentTime`. Assert scroll revision stays fixed while held and changes on catch-up. Complete a canceled request's token deliberately; cancellation is not the assertion.

- [ ] **Step 2: Run the focused suite and confirm failure on missing model/types.**
- [ ] **Step 3: Implement the state transitions.** A session, occurrence or recording change clears content/hold and invalidates tokens before updating metadata. Hide clears hold and invalidates outstanding tokens; it may retain already loaded content for the same input. New accepted content clears hold. Hold is available only for a displayed timed cue. Pause/corrections preserve hold; a changed seek revision releases it. Preserve the held projection through playback end. Log visibility and reading transitions without lyric bodies.
- [ ] **Step 4: Rerun `LyricRibbonModelTests` and Task 1's suite; require success.**
- [ ] **Step 5: Commit:** `feat: add independent lyric reading state`.

## Task 3: Build the Retro Surface and Stable Text Layout

**Files:** create `Bopify/Bopify/Lyrics/LyricRibbonLayout.swift`, `LyricRibbonView.swift` and `Bopify/BopifyAppTests/LyricRibbonLayoutTests.swift`.

**Consumes:** Task 2's observable model; no live environment.

**Produces:** `LyricRibbonView(model: LyricRibbonModel, layout: LyricRibbonLayout, onHide: @escaping () -> Void, onDragHeader: @escaping (NSEvent) -> Void)`. `LyricRibbonLayout.measure(content: LyricContent, width: CGFloat, textScale: CGFloat, availableHeight: CGFloat) -> LyricRibbonLayout` exposes `panelSize: CGSize` and `textViewportHeight: CGFloat`. `textScale` defaults to 1 and is adjustable in the study controls.

- [ ] **Step 1: Write failing layout tests.** With normal width 448, compare short and multiline fixtures and assert the long fixture reserves more text height, larger text requires no less height, and an oversized passage stays within a 320-point available height. Assert finite positive geometry for narrow screens and an empty document. These tests check content-fit boundaries, not hardcoded font-rendering pixel counts.

```swift
// long, short and scaled use the same available frame; bounded uses height 320.
#expect(long.textViewportHeight > short.textViewportHeight)
#expect(scaled.textViewportHeight >= long.textViewportHeight)
#expect(bounded.panelSize.height <= 320)
#expect(bounded.textViewportHeight > 0)
```
- [ ] **Step 2: Run `LyricRibbonLayoutTests` and confirm missing-type failure.**
- [ ] **Step 3: Implement measurement and view.** Measure all previous/current pairs using the same native text layout and font metrics used to render; reserve the largest pair once per content, width, scale or available-frame change. Use a read-only selectable `NSTextView` through `NSViewRepresentable` for the lyric passage and its native attributed-text layout for measurement, with no character-count estimates. Keep the surrounding surface and controls in SwiftUI. [Apple attributed-string measurement](https://developer.apple.com/documentation/foundation/nsattributedstring/boundingrect(with:options:context:)).

Render 23/14-point system lyric fonts at scale 1, 24-point corners, warm charcoal with ivory hierarchy, small static vinyl mark, track identity and monospaced elapsed time. Keep metadata/footer outside the vertical lyric scroll view. Bind scroll reset to `scrollResetRevision`; scrolling and hold preserve position until catch-up. Scope drag handling to the header. Keep hover/focus controls in reserved space. Use standard content material, opaque accessibility fallbacks and direct cue changes. Expose accessible reading/hide controls and selectable words without a live-region announcement.

Include all content states. Exact copy: “Lyrics start soon”, “End of lyrics”, “Reading · music continues”, “Reading · music paused”, “Hold text”, “Back to live”, “Hide Ribbon”. Use ordinary scrollable reading for `.plain`, with no Live or Hold text controls. Define the remaining concise state copy locally; do not alter unrelated localization entries.

- [ ] **Step 4: Rerun layout and model suites.** Add SwiftUI `#Preview` variants using local original data for Live, Reading, long text, plain, unavailable and RTL presentation. Inspect them in Xcode; final native panel checks happen in Task 5.
- [ ] **Step 5: Commit:** `feat: add clean retro lyric ribbon surface`.

## Task 4: Add Independent Native Panel and Focus Policy

**Files:** create `Bopify/Bopify/Lyrics/LyricRibbonWindowController.swift` and `Bopify/BopifyAppTests/LyricRibbonWindowTests.swift`.

**Consumes:** Task 3's view/layout and Task 2's model.

**Produces:** `@MainActor final class LyricRibbonWindowController` with `init(model: LyricRibbonModel, defaults: UserDefaults, onHide: @escaping () -> Void)`, `show()`, `hide()`, `focusForReading()`, `refreshLayout(textScale: CGFloat)` and read-only `panel: NSPanel`. Own a ribbon-specific panel subclass; `canBecomeKey` is false until explicit keyboard interaction, and resets on resigning key. Frame preference key is `lyrics.preview.frame`, independent of the player.

- [ ] **Step 1: Write failing window-policy tests in a serialized MainActor suite.** Construct the controller with an isolated temporary defaults suite. Assert passive mode cannot become key, explicit focus enables key eligibility, hide clears reading state, a malformed/offscreen saved frame becomes reachable, and a 320-by-480 visible frame bounds the result. Reuse existing `clampedPlayerFrame` rather than duplicate its algorithm. Clean up panels and defaults after each test.

```swift
#expect(!controller.panel.canBecomeKey)
controller.focusForReading()
#expect(controller.panel.canBecomeKey)
controller.hide()
#expect(!model.isVisible && !model.isHeld)
```
- [ ] **Step 2: Run `LyricRibbonWindowTests` and confirm failure on missing controller.**
- [ ] **Step 3: Implement the controller.** Use borderless nonactivating presentation with controller-owned frame and a nested hosting view so SwiftUI cannot resize the window on every layout pass. Passive show uses `orderFront`, never `makeKeyAndOrderFront`; only Focus Ribbon requests key focus. Do not copy `StatusPanel` media shortcuts or hit regions. Use `.floating`, `hidesOnDeactivate = false`, and join ordinary Spaces/fullscreen auxiliary presentation for the study. Clamp saved/default frames against visible screens and handle display-change notifications; invalidate observations on disposal.

Only the header starts `performDrag(with:)`; lyrics and controls remain interactive. Escape in keyboard mode routes through `onHide`. Pointer reading/hide actions must not request key focus. [Apple panel focus guidance](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded) describes hit-view participation; test the actual hosted controls rather than assuming the flag alone guarantees focus preservation.

- [ ] **Step 4: Rerun window and layout suites.** Keep native cross-app focus verification as a required Task 5 check; hostless policy tests cannot establish another application's insertion focus.
- [ ] **Step 5: Commit:** `feat: add passive native lyric ribbon panel`.

## Task 5: Wire Isolated Fixture Launch and Validate the Study

**Files:** create `Bopify/Bopify/Lyrics/LyricRibbonPreview.swift`, `Bopify/BopifyAppTests/LyricRibbonPreviewTests.swift`; modify `Bopify/Bopify/BopifyApp.swift` and `README.md`.

**Consumes:** Tasks 1–4.

**Produces:** `@MainActor final class LyricRibbonPreviewSession` with `init(now: @escaping () -> TimeInterval, sleep: @escaping @Sendable (Duration) async throws -> Void)`, read-only `model`, `controller`, `isClockRunning`, and methods `show()`, `hide()`, `setPlaying(_ playing: Bool)`, `advance(by milliseconds: Int64, explicitSeek: Bool)`, `selectFixture(_ fixture: LyricPreviewFixture)` and `shutdown()`. `LyricPreviewFixture` lists `.timed`, `.long`, `.rtl`, `.plain`, `.instrumental`, `.noMatch`, `.failure`, `.loading`. Session initialization defaults to monotonic uptime and `Task.sleep` in the app; tests inject a controllable clock/gate.

- [ ] **Step 1: Write failing preview tests.** Assert a running visible session ticks from injected time, pause freezes time, correction preserves hold, explicit seek releases hold, hide and shutdown cancel the task, and reopening reflects current simulated time. With a suspended sleep, hide then release the gate: assert no stale tick changes the model and `isClockRunning == false`. Test repeated occurrence identity and all fixture outcomes. Use a generation guard as well as cancellation for clock restarts.

```swift
session.model.holdText()
session.advance(by: 5_000, explicitSeek: false)
#expect(session.model.isHeld)
session.advance(by: 5_000, explicitSeek: true)
#expect(!session.model.isHeld)
session.hide()
#expect(!session.isClockRunning)
```
- [ ] **Step 2: Run `LyricRibbonPreviewTests` and confirm missing-session failure.**
- [ ] **Step 3: Implement fixtures, clock and controls.** Use only invented track metadata and original lyric lines. Start at 72,000 ms; controls allow play/pause, +5 seconds, explicit seek, correction, new occurrence, state selection, text scale, show/hide, Focus Ribbon and Quit Preview. Tick at 100 ms while visible and playing, publish elapsed seconds only when changed, and avoid publishing unchanged cue groups. Stop at the reported duration. Hidden time can advance through the simulated input without a presentation task; compute the latest snapshot on reopen. No real player or service references.

In `BopifyApp.swift`, delay normal `AppEnvironment` construction until after a Debug-only `--lyric-ribbon-preview` branch. That branch retains the session and opens only its control window and ribbon, returning before status-item creation or auth restoration. Keep the existing live launch behavior otherwise unchanged. Session shutdown cancels tasks and closes both preview windows. Wrap the branch, launcher and preview controls in `#if DEBUG`; do not add a release command or change `AppEnvironment`.

- [ ] **Step 4: Run the complete hostless app tests with the command above, without a suite filter.** Require `TEST SUCCEEDED`. Build both Debug and Release:

```sh
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/lyric-ribbon-study CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/lyric-ribbon-study CODE_SIGNING_ALLOWED=NO build
```

Require `BUILD SUCCEEDED` for both. Inspect Release symbols to confirm no `LyricRibbonPreviewSession`; review the only composition diff to ensure Release has no preview branch. No Rust or package code changes are planned, so do not rerun unrelated Rust suites absent a new failure.

- [ ] **Step 5: Launch the native Debug study and complete the spec's native checks.**

```sh
open -n build/lyric-ribbon-study/Build/Products/Debug/Bopify.app \
  --args --lyric-ribbon-preview
```

Type continuously in another app while showing, hovering, dragging and clicking Hold text/Back to live. Verify typing stays in that app, then separately verify Focus Ribbon, Tab, Escape and VoiceOver. Check 1:12 hold → 1:27 catch-up, paused status, end while held, plain text, RTL, long scrollable cues, larger text, dark/light desktops, Reduce Transparency, Increase Contrast, Dock clearance, display removal and fullscreen Spaces. Capture native before/after screenshots and inspect them against the approved browser study; record actual results and any remaining environment limitations in `docs/lyric-ribbon-native-validation.md`. Do not substitute browser screenshots for native evidence or mark inaccessible checks as passed.

- [ ] **Step 6: Document the Debug command and its original sample data in README.** Run `git diff --check`, inspect the scope of the diff, confirm only the explicit Debug path creates the study and that no provider/network/auth work was introduced. Commit `feat: add isolated native lyric ribbon study`, perform the selected workflow's final review, then push completed commits to `main` and verify synchronization. Do not publish a completion claim for native validation before its checks have actually run.

## Execution Handoff

Recommended method: Native execution in this session. The five tasks share a small set of interfaces and one native preview; one implementer can carry those interfaces through with less repeated context. Subagent-driven execution remains available if independent review after each task is preferred. Implementation starts after the user reviews this plan and chooses the method.
