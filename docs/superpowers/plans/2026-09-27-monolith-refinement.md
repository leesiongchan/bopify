# Monolith Refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refine Monolith's surface and interaction handling, add bounded volume updates and vinyl scrubbing, and display individual liked songs in Cover Flow below the controls.

**Architecture:** Retain the native panel/SwiftUI split and authoritative playback model. Give the existing expanded and queue modes identical geometry with different lower-section content. Add a paged saved-track service/model alongside favorites, and keep carousel selection separate from playback queue identity.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Observation, Swift Testing, existing Spotify client and native probe runner; macOS 14 minimum, native Liquid Glass on macOS 26+.

**Spec:** [2026-09-27-monolith-refinement-design.md](../specs/2026-09-27-monolith-refinement-design.md), approved 2026-09-27. Read this and the original Monolith spec's retained requirements before execution.

## Global Constraints

- At rest, show only the vinyl. Hover reveals controls without taking focus; clicking or keyboard focus keeps them open. Preserve the existing 280 ms grace period.
- Start native layout verification at approximately 484 × 360 pt with the existing 182 pt focused record and 118 pt resting record. Both lower-section occupants use the same outer geometry.
- Preserve 40 pt primary transport targets, 48 pt play/pause, 28 pt secondary controls, and approximately 12 pt secondary text.
- Panel movement and relative record scrubbing use 4 pt drag slop. The spindle dead zone is 12 pt; one scrub revolution corresponds to 60 seconds; one automatic revolution takes 12 seconds.
- Coalesce volume to at most one normal dispatch per 150 ms, with one operation in flight and one replaceable pending value. Release and mute bypass the normal delay.
- Cover Flow shows five covers normally and three at narrow widths, approximately 76 pt center artwork, and a roughly 280 ms settling spring. Retain at least an 80 pt lower viewport where the screen permits.
- Request saved tracks in pages of up to 50 with `user-library-read`. Refresh on confirmed membership change, consent, and first reveal after at least 60 seconds hidden. No idle polling.
- No new package dependency or Rust/FFI change is planned. Preserve mode raw values, saved record-center preferences, startup behavior, and existing queue confirmation protections.
- Preserve the user's uncommitted `Localizable.xcstrings` edit. Add only required copy; never commit their existing removal of `%@ of %@` as part of this work.
- Log state/command boundaries through existing categories, never frame/pointer samples, credentials, response bodies, or library contents.

## Review Focus

1. A volume operation completing after device loss and subsequent reactivation must not restore obsolete work or block transport; Task 2 tests delayed completion across generations.
2. A liked-song refresh while browsing far into a changing library must preserve selection when still present, ignore stale pages, and never fetch unbounded pages trying to find a removed song; Task 4 tests refresh of a previously loaded prefix.
3. Favorite reads on focus and optimistic toggles must not reset Cover Flow or trigger overlapping OAuth; Tasks 4 and 6 test confirmed changes and shared consent ownership.
4. Record growth beneath a held pointer, angle wraparound, and a pass through the spindle must not produce a seek jump; Task 5 tests geometry rebasing and native reveal-time input.
5. Window background handling and panel shortcuts must not steal carousel/slider input or make transparent corners clickable; Tasks 1 and 6 use real native event routing and a background window.

---

## File map and verification commands

| Area | Files and responsibility |
| --- | --- |
| Window and layout | Modify `Packages/BopifyCore/Sources/BopifyPlayback/MonolithLayout.swift`, `Bopify/Bopify/MenuBar/{StatusPanel,MonolithWindowController,StatusItemController}.swift`, `Bopify/Bopify/Views/{PlayerSurface,MonolithPlayerView}.swift` for fixed engaged geometry, native focus, and background movement |
| Volume | Modify `Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift`; create `Bopify/Bopify/Views/VolumeControl.swift`; update both slider entry points |
| Saved-track boundary | Create `Packages/BopifyCore/Sources/BopifyDomain/SavedTracksService.swift`; modify `Packages/BopifyCore/Sources/BopifyLibrary/SpotifyLibraryClient.swift` |
| Library state | Create `Packages/BopifyCore/Sources/BopifyLibrary/LikedSongsModel.swift`; modify `FavoriteModel.swift`, `Bopify/Bopify/AppEnvironment.swift`, and `Bopify/Bopify/Views/MiniPlayerView.swift` for lifecycle and confirmed-change integration |
| Record | Create `Packages/BopifyCore/Sources/BopifyPlayback/RecordScrub.swift` and `RecordRotation.swift`; modify `Bopify/Bopify/Views/{VinylRecordView,MonolithPlayerView,RadialProgressView}.swift` |
| Focused UI | Create `Bopify/Bopify/Views/LikedSongsCoverFlow.swift`; modify `Packages/BopifyCore/Sources/BopifyPlayback/PlayerPresentation.swift` and `Bopify/Bopify/Views/{FavoriteButton,MiniPlayerView,MonolithPlayerView,PlayerPreviews}.swift` |
| Tests | Extend existing layout/presentation/attention/player/library/favorite tests; create `PlayerVolumeTests.swift`, `RecordScrubTests.swift`, `RecordRotationTests.swift` in PlaybackTests and `LikedSongsModelTests.swift` in LibraryTests |
| Native evidence | Extend `docs/superpowers/verification/{MonolithWindowProbe,MonolithVisualProbe,MonolithCompositionProbe}.swift` and `run-monolith-probe.py`; create `2026-09-27-monolith-refinement.md` and captures in `assets/monolith-refinement/` |

Use these commands from the execution checkout; a task's filtered command is the package command with its specified `--filter` appended:

```bash
swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-refinement-tests
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-refinement-build build
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-refinement-build --output /private/tmp/bopify-refinement-window --probe window
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-refinement-build --output /private/tmp/bopify-refinement-visual --probe visual
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-refinement-build --output /private/tmp/bopify-refinement-composition --probe composition
```

Native GUI probes must run sequentially. Exit zero and the runner's matching `MONOLITH ... PASS` message mean the probe completed; inspect failure output in full. Build before native checks whenever app/package sources have changed. Do not run Rust checks unless artifacts are missing or evidence points to a bridge regression.

At execution start use the worktree skill, establish an isolated branch, preserve the localization diff, and verify the existing package/build baseline. Reuse or link the existing ignored FFI artifacts as in the prior Monolith workflow. The document-writing phase does not create an execution checkout or change app behavior.

### Task 1: Fixed lower-section geometry, native background focus, and surface diagnosis

**Files:** Window/layout files above; `Packages/BopifyCore/Tests/PlaybackTests/MonolithLayoutTests.swift`; window/visual/composition probes and verification report.

**Interfaces:** Preserve `monolithLayout(mode:availableSize:) -> MonolithLayout`, `MonolithWindowController.apply(mode:reduceMotion:visibleFrame:)`, and mode raw values. Rename the internal-use layout property `queueFrame` to `lowerFrame` at every repository caller. Generalize `RecordDragRegion` into `PlayerBackgroundDragRegion: NSViewRepresentable`, retaining balanced `onWindowDragChanged` callbacks. Add `StatusPanel.onCancelInteraction: (() -> Bool)?` before queue dismissal in `cancelOperation` for Tasks 5–6.

- [ ] **1. Capture the baseline and write failing geometry/native assertions.** Use actual light/dark backdrop windows, not transparent PNG display, for the reported contour. In `engagedModesShareGeometry`, for available sizes 484×480, 320×480, and 484×300, assert:
  ```swift
  #expect(expanded.contentSize == queue.contentSize)
  #expect(expanded.recordCenter == queue.recordCenter)
  #expect(expanded.controlsFrame == queue.controlsFrame)
  #expect(expanded.lowerFrame == queue.lowerFrame)
  #expect(expanded.lowerFrame.height >= 80)
  ```
  Extend native probes to click blank sleeve/lower-panel areas, move the pointer outside, and require `panel.isKeyWindow` and revealed presentation. Drag backgrounds by a known screen delta and assert equal frame/anchor movement, 4 pt slop, and no transport commands. Cover rounded exterior corners, buttons, queue rows, scrolling, and drag interruption during reveal.
- [ ] **2. Run RED.** Run package command with `--filter MonolithLayoutTests`, build, then window/composition probes. Record behavioral failures against current code separately from expected compilation failures for renamed properties. First use existing field names to reproduce the unequal geometry.
- [ ] **3. Implement geometry and native routing.** Engaged modes use 484×360 targets, fixed upper controls, and the same lower viewport. Apply short-screen reservation equally to both modes in `apply`; retain spindle anchoring and stale-completion guards. Acquire native key focus for visible-object left presses before normal dispatch. Put background drag regions beneath interactive content and on noninteractive metadata; do not use a blanket overlay. Keep record dragging until Task 5 replaces it, so intermediate commits retain a usable record. Make sleeve containment honor rounded corners.
- [ ] **4. Isolate and fix the contour.** In a fixture compare explicit-stroke removal, native shadow, and native glass edge individually; record which changes the observed line. Apply only the demonstrated decorative-outline fix to production. Preserve semantic accessibility boundaries. If the contour is inseparable from native glass, show the measured material alternative before changing that approved treatment; do not claim a fix from inference.
- [ ] **5. Run GREEN.** Repeat layout tests, build, and window/composition probes; inspect native light/dark before/after captures. Update old 264/424 geometry assertions deliberately. Keep unrelated startup, queue-selection, and click-through assertions.
- [ ] **6. Commit only this task's changes:** `Fix Monolith background focus and shared panel geometry`.

### Task 2: Bounded volume command lifecycle

**Files:** `PlayerModel.swift`; create `Packages/BopifyCore/Tests/PlaybackTests/PlayerVolumeTests.swift`; update existing mute tests if dispatch completion requires deterministic waiting.

**Interfaces:** Keep `setVolume(_ value: Double)` and `toggleMute()`. Add `beginVolumeEditing()`, `endVolumeEditing()`, `cancelVolumeEditing()`, and read-only `displayVolume: Double`. `state.volume` remains authoritative. Retain public `init(engine:)`; add an internal test initializer accepting `volumeNow: @MainActor () -> TimeInterval` and `volumeSleep: @Sendable (Duration) async throws -> Void`, with production using monotonic uptime and cancellable task sleep.

- [ ] **1. Write failing `PlayerVolumeTests`.** Follow the controllable-actor pattern in FavoriteModelTests for a test engine that suspends volume completions and timestamps calls. Use a test clock with explicit advance/resume handshakes, never arbitrary sleeps. `rapidVolumeKeepsOnlyLatest` sends 100 values over simulated 100 ms and asserts one dispatch; after 150 ms its next value is the latest. `releaseFlushesBehindInFlight` holds the first call, releases at 0.83, resolves it, and asserts:
  ```swift
  #expect(volumes == [0.1, 0.83])
  #expect(maxConcurrentVolumeCalls == 1)
  #expect(model.state.volume == confirmedVolume)
  ```
  Add tests for normal spacing ≥0.150 s, duplicate/clamped/nonfinite values, immediate mute/final dispatch, a newer edit replacing an unsent final value, failure rollback, incoming external volume, and next/pause reaching the engine while volume is suspended. Delay a completion across device loss/reactivation and stop/start; assert no stale resend, notice, or draft resurrection.
- [ ] **2. Run RED.** Package command with `--filter PlayerVolumeTests`; also reproduce the flood through existing `setVolume` before relying on missing-interface failures.
- [ ] **3. Implement one volume worker in `PlayerModel`.** Separate it from `pendingCommand`; hold one replaceable requested value, one cancellable wait, and one in-flight operation. Apply 150 ms normal spacing, immediate-final intent, generation invalidation, and deduplication without treating engine success as an authoritative volume event. Track draft ownership separately from confirmed mute memory. A completed operation releases its worker even when obsolete, but cannot mutate a newer generation's state. Log dispatch/failure only.
- [ ] **4. Run GREEN.** Run `--filter PlayerVolumeTests` and `--filter PlayerModelTests`; require the exact final value, no duplicate history, and unchanged confirmed mute behavior. Task 6 wires both controls into begin/end/cancel.
- [ ] **5. Commit:** `Coalesce volume updates and flush the final adjustment`.

### Task 3: Paginated saved-track client

**Files:** Create `Packages/BopifyCore/Sources/BopifyDomain/SavedTracksService.swift`; modify `SpotifyLibraryClient.swift` and `Packages/BopifyCore/Tests/LibraryTests/SpotifyLibraryClientTests.swift`.

**Interfaces:** `public struct SavedTracksPage: Equatable, Sendable` contains `tracks: [Track]`, `nextOffset: Int?`, `total: Int`, with `public init(tracks:nextOffset:total:)`. `public protocol SavedTracksService: Sendable` has `func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage`. Existing `SpotifyLibraryClient` implements it alongside unchanged `LibraryService`.

- [ ] **1. Add failing request/decoding tests using the existing serialized URLProtocol fixture.** `savedTracksRequestUsesReadScope` checks GET, fixed `https://api.spotify.com/v1/me/tracks`, offset=0, limit=50, and exactly `user-library-read`. `skippedTrackDoesNotChangeNextOffset` returns three raw items with one null/unavailable item and asserts:
  ```swift
  #expect(page.tracks.count == 2)
  #expect(page.nextOffset == 3)
  #expect(page.total == 7)
  ```
  Test zero tracks with a nonempty raw page, duplicate album art, missing images, invalid track URI/duration, malformed page metadata, nonadvancing offsets, empty last page, and next=nil. Confirm 401/403/429/5xx mapping, Retry-After, cancellation, and no redirects or response-provided foreign pagination URL receiving credentials. Invalid offset/limit sends no request.
- [ ] **2. Run RED.** Package command with `--filter SpotifyLibraryClientTests`; expect the missing conformance/method initially.
- [ ] **3. Implement the client boundary.** Reuse fixed-origin authenticated request/error/redirect handling only where needed. Validate offset ≥0 and limit 1…50. Decode wire items separately from `Track`, allowing null/unavailable/invalid individual tracks to be skipped while rejecting invalid page structure. Calculate next offset from raw item count with overflow/nonprogress checks, use next only as continuation metadata, and always construct the next request locally. Never give the model a bearer-bearing URL.
- [ ] **4. Run GREEN.** Require all existing membership/mutation tests and new browsing tests to pass. No Package.swift or dependency changes are needed.
- [ ] **5. Commit:** `Add paginated Spotify liked-song retrieval`.

### Task 4: Session-owned liked-song state and confirmed favorite updates

**Files:** Create `LikedSongsModel.swift` and `Packages/BopifyCore/Tests/LibraryTests/LikedSongsModelTests.swift`; modify `FavoriteModel.swift`, `FavoriteModelTests.swift`, `AppEnvironment.swift`, `MiniPlayerView.swift`, and composition probe fixtures.

**Interfaces:** `@MainActor @Observable public final class LikedSongsModel`, `init(service: any SavedTracksService)`, read-only `tracks: [Track]`, `selectedURI: SpotifyURI?`, `isLoading: Bool`, `error: LibraryError?`, `retryAfter: Date?`; methods `reveal(at: Date) async`, `hide(at: Date)`, `select(_ uri: SpotifyURI)`, `loadMoreIfNeeded(near uri: SpotifyURI) async`, `refresh() async`, `retry(at: Date) async`, `clear()`. Add read-only monotonic `FavoriteModel.membershipRevision: UInt64`, incremented only after toggle reconciliation confirms a change from the pre-toggle value. It does not change on ordinary reads, optimistic updates, clear, rollback, or stale completion.

AppEnvironment owns `likedSongs`, adds `enableLikedSongs() async`, and shares one library-consent in-flight guard across it and `enableFavorites()`. Extend the DEBUG initializer with optional `savedTracksService: (any SavedTracksService)? = nil` and `authorizeLibraryScopes: (@Sendable (Set<String>) async throws -> Void)? = nil`; absent fixture providers report unavailable instead of starting OAuth. Production wraps the existing auth service in the same private consent closure. Preserve existing favorite-only fixtures.

- [ ] **1. Write deterministic failing model tests.** A controlled saved-track actor exposes page-request and completion handshakes. Assert reveal requests (0,50) once, selecting the last five loaded items requests the next page once, duplicate URIs retain first-seen order, and hide prevents new requests. `refreshPreservesDeepSelection` loads three pages, selects an item in the third, refreshes with inserted/deleted items, then asserts selectedURI is preserved if still present. Bound refresh to the previously loaded raw prefix, keeping old visible content until replacement is ready; if the selection is absent, choose the nearest surviving index. Never scan the rest of the library to find it.
  ```swift
  #expect(model.selectedURI == selectedTrack.uri) // still present after refresh
  #expect(model.tracks.map(\.uri).count == Set(model.tracks.map(\.uri)).count)
  #expect(maxConcurrentPageRequests == 1)
  ```
  Test 59 s hidden means no refresh and 60 s means refresh, retained pages on failure, initial/empty/auth/rate-limit states, retry deadline enforcement, refresh invalidating an older suspended page, and clear rejecting late results. Extend FavoriteModelTests to assert revision increments once on reconciled change and remains unchanged for focus reads, rejected/ambiguous-no-change writes, and clear-during-mutation.
- [ ] **2. Run RED.** Run the package command separately with `--filter LikedSongsModelTests` and `--filter FavoriteModelTests`.
- [ ] **3. Implement the model and lifecycle.** Use one generation-protected page task, URI selection/deduplication, raw page offsets, bounded prefix refresh, and explicit error/retry state. Keep playback out of the model. Share one client between favorite and browsing models. Clear browsing on sign-out, replacement, and quit. Observe membershipRevision in the composition root/view and refresh only after a confirmed revision; do not observe `saved`. Refresh successful consent without starting or replacing playback.
- [ ] **4. Extend the composition fixture for consent/lifecycle.** Before the shelf view arrives in Task 6, drive model and enable actions directly with a controlled consent closure: a missing read grant reports authorizationRequired without calling consent; overlapping enable actions invoke consent once with the first action's required scopes. Task 6 checks the visible enable action. Preserve the existing favorite write-consent recovery when read permission alone is granted. Native focus refresh does not reset carousel state; late sign-out results cannot restore it.
- [ ] **5. Run GREEN.** Run LibraryTests and AuthTests, build, then composition probe with separate browsing and favorite fixtures. Do not contact a live account merely to make unit fixtures pass.
- [ ] **6. Commit:** `Manage liked-song browsing within the signed-in session`.

### Task 5: Continuous record rotation and relative scrubbing

**Files:** Create `RecordScrub.swift`, `RecordRotation.swift`, and corresponding PlaybackTests; modify `VinylRecordView.swift`, `MonolithPlayerView.swift`, `RadialProgressView.swift`, visual probe, and ambient instrumentation in the runner.

**Interfaces:** `public struct RecordScrub` exposes `positionMs: Int64`, `angleDelta: Double` (radians), `init(positionMs: Int64, durationMs: Int64)`, `mutating func update(x: Double, y: Double, geometryID: UInt64)`. Coordinates are relative to the spindle; first valid sample, dead-zone exit, or geometry change rebases without a delta. `public struct RecordRotation` exposes `init()`, `func angle(at: TimeInterval) -> Double`, `mutating func setRunning(_ running: Bool, at: TimeInterval)`, and `mutating func setAngle(_ radians: Double, at: TimeInterval)`. Use monotonic time and radians throughout.

VinylRecordView adds `rotation: RecordRotation`, `rotationOverride: Double? = nil`, and `isScrubbing: Bool = false` inputs while retaining occurrence/direction/artwork inputs. Monolith owns the rotation state and pointer session so a press can capture the exact displayed phase; the record view samples that same rotation state for rendering. Update every VinylRecordView caller, including previews and native record fixtures, to supply a rotation state. Keep track-transition tilt independent of this state.

- [ ] **1. Write failing pure tests.** `relativeScrubWrapsAndReverses` starts at 30_000 ms, samples the top then right of a 90 pt radius, and asserts 45_000; reverse returns to 30_000. Test both zero-angle crossings, repeated rotations, dead-zone entry/exit, invalid values, clamping at 0/duration with immediate reversal, and geometry changes with no position delta. `rotationPreservesPhase` asserts π/2 after three seconds of running, the same angle after ten seconds paused, and π after another three running seconds. `setAngle` during a gesture rebases the next ambient frame without snapping.
- [ ] **2. Run RED.** Package command with `--filter RecordScrubTests` and `--filter RecordRotationTests`. Extend the native fixture before view changes to show that a normal clockwise record drag currently moves the window or sends no relative seek.
- [ ] **3. Implement math and render integration.** Use shortest angular deltas, a 12 pt dead zone, 60_000 ms per 2π, and discard bound overshoot. Rotate body/grooves/label while lighting/progress remain fixed; stop scheduling in all nonplaying/hidden/reduced-motion states. Remove record-center window dragging from production composition. Keep historical absolute-scrub helpers only where existing callers still need them; do not delete unrelated historical probes.
- [ ] **4. Implement the one record gesture.** Focus on press, capture occurrence/position/angle, begin seek hold after 4 pt, preview time/progress immediately, and commit one seek on release. Rebase pointer geometry during reveal without resetting accumulated preview. Press through release suspends visual ambient rotation, including a click with no seek. Wire Escape to cancel before lower-section dismissal. Hide/sign-out/duration/occurrence/capability changes cancel; ignored nonseekable input sends no command. Keep accessible five-second seek adjustment and remove the old pointer ring recognizer from Monolith.
- [ ] **5. Repair probe instrumentation and run GREEN.** Make temporary source-marker instrumentation fail if the expected site is not found exactly once. Require a positive playing tick count before checking zero paused/hidden/inactive/Reduce Motion ticks. Replace old 250 ms absolute-seek expectations with relative-drag assertions; verify click=zero, drag=one, cancellation=zero seeks and unchanged window origin. Capture pause/resume, reveal while pressed, repeated same-cover occurrences, and rapid interruption. Run pure tests, build, visual and composition probes.
- [ ] **6. Commit:** `Spin the vinyl and seek with relative record dragging`.

### Task 6: Vertical volume popover and liked-song Cover Flow composition

**Files:** Create `VolumeControl.swift` and `LikedSongsCoverFlow.swift`; modify presentation, FavoriteButton, MonolithPlayerView, MiniPlayerView, PlayerPreviews, localization, and native probes as mapped above. Extend `Packages/BopifyCore/Tests/PlaybackTests/PlayerAttentionTests.swift` and `PlayerPresentationTests.swift`.

**Interfaces:** Add `public enum PlayerPopover: Sendable { case favorite, volume }`, read-only `PlayerPresentation.activePopover: PlayerPopover?`, `presentPopover(_:)`, and `dismissPopover() -> Bool`. One owner controls `.popover` attention; hide/reset clears it. `VolumeControl(player: PlayerModel, presentation: PlayerPresentation)` uses Task 2 lifecycle. `LikedSongsCoverFlow(model: LikedSongsModel, store: ArtworkStore, play: (Track) -> Void)` keeps playback explicit. Monolith passes `player.load(PlayRequest(contextURI: track.uri))` as the play closure.

- [ ] **1. Write failing presentation and native assertions.** `popoverSwitchKeepsAttention` opens favorite, switches to volume, removes pointer/key focus, and verifies reveal stays held until volume closes. After a close with an active volume hold, advancing by 280 ms must still leave it open. Native fixtures assert the speaker opens a vertical slider; editing beyond panel bounds keeps focus; Escape closes popover, then queue, then panel. Cover Flow fixture has >50 songs, duplicate album art, long names, null artwork, and an unavailable page. Assert scrolling/centering causes zero playback commands, while explicit center click/Return adds exactly one `load:<selected URI>`.
- [ ] **2. Run RED.** Run presentation/attention tests and build/native visual/composition probes. Preserve expected startup and error announcements; new UI assertions should fail before integration.
- [ ] **3. Integrate popovers and volume.** Replace FavoriteButton's private independent popover state with presentation ownership, including shell callers. Use an AppKit `NSSlider` wrapper sized vertically inside the speaker popover so native keyboard/accessibility behavior is retained. Its pointer tracking reports begin/end; keyboard/accessibility changes use immediate finish after value change. Drive thumb/percentage from `displayVolume`, include separate mute action, and reconcile ordinary close versus hide/session cancellation. Update the shell slider to begin/end/cancel too. Route Escape through active popover, then scrub, then queue, then panel.
- [ ] **4. Implement Cover Flow and shared lower content.** Render only selected/nearby covers, use five/three visible items, ~76 pt center art, restrained perspective/reflection, and 280 ms snap. Direct dragging tracks the pointer; horizontal wheel/trackpad input accumulates into the same selection/snap path. Suppress click after drag, including drag beginning on the centered item. Left/right/Return belong to the carousel only when focused; use native forwarding so StatusPanel shortcuts do not consume them first. Reduce Motion uses flat/faded transitions. Call reveal/hide and near-end loading at shelf lifecycle boundaries; scrolling never calls play. Mount queue and carousel in `lowerFrame`, retaining queue confirmation identity and failure behavior.
- [ ] **5. Add required localized copy and accessible states.** Include library enable/retry/empty labels, song+artist item names, selected state, explicit play action, and volume percentage/mute labels. Keep full names in tooltips. Never put API/scopes/engine implementation text in product copy. Preserve the unrelated localization deletion and commit only task-owned changes.
- [ ] **6. Run GREEN.** Run LibraryTests and PlaybackTests, build, then all three native probes. Inspect actual production composition for background drag versus cover/slider/queue gestures, mutually exclusive popovers, focus refresh, loading/error states, narrow layout, and switching lower content without spindle/frame movement. Assert browsing has no transport effects and favorite actions still target the confirmed current track.
- [ ] **7. Commit:** `Add liked-song Cover Flow and vertical volume controls`.

### Task 7: Native acceptance, live boundary checks, and review closure

**Files:** Verification report and assets; probes/production code only for failures directly within the approved scope.

**Interfaces:** Continue using production views/controllers with stub engines for controlled native checks. Live Spotify checks are a separate evidence category; never label a fixture as a real authorization or playback result.

- [ ] **1. Run the native interaction matrix sequentially.** Background click/drag for controls and both lower occupants; real cross-app hover/click-through; rounded corners; queue confirmation/failure; carousel click/drag/trackpad/keyboard; volume pointer outside bounds; popover switching; Escape order; hide/sign-out during every gesture; record reveal-time scrub and cancellation; repeated window edge/clamp transitions. Check keyboard and actual accessibility traversal, not only labels exposed in an AX tree.
- [ ] **2. Capture and inspect the visual/motion matrix.** Light/dark backdrops, resting/focused/queue, narrow/short/negative-origin displays, missing/shared artwork, long localized text, loading/empty/permission/error states, and real accessibility settings where available. Include native before/after contour evidence and motion sequences for vinyl phase, scrub, Cover Flow snapping, and simultaneous track/reveal transitions. Differentiate injected fixture settings from real system preference notifications.
- [ ] **3. Verify live boundary behavior when the signed-in session permits it.** Fetch one saved-track page through the app's existing authenticated service without printing credentials or response bodies. Verify selected-track playback, relative seek, and volume final value against actual observed events as part of the requested interaction checks. Browse-only interaction must not take over remote playback. Report unavailable live acceptance clearly; request user input only if a missing credential or explicit OAuth consent prevents the check.
- [ ] **4. Run final regression commands.** Run the unfiltered package command and app build once fixes are complete, then window, visual, composition, and artwork probes. Run the visual probe once with `--measure-ambient` for the positive/zero tick checks. Use `--probe artwork --output /private/tmp/bopify-refinement-artwork` with the same derived-data directory. Run `git diff --check`; require zero exit status and inspect every result.
- [ ] **5. Complete the verification report.** Map each of the six user requests to implementation, commands, captures, and observed results. Record any unverified live/manual checks explicitly. Fix minor findings within scope before handoff; do not automatically defer them because of their severity label. A required acceptance check without evidence remains incomplete.
- [ ] **6. Commit and request the execution workflow's independent review.** Commit verified changes as `Verify Monolith refinement interactions and appearance`. For Native execution, use one fresh whole-branch reviewer after implementation, fix findings with focused regression checks, and complete the branch workflow without merging or publishing unless authorized for this new branch.

## Current API references

- [Apple: NSSlider](https://developer.apple.com/documentation/appkit/nsslider), consulted 2026-09-27: native sliders support vertical layout and expose `isVertical`.
- [Apple: NSWindow.sendEvent(_:)](https://developer.apple.com/documentation/appkit/nswindow/sendevent(_:)), consulted 2026-09-27: native mouse/key dispatch is the window boundary; test real dispatch instead of bypassing it with direct method calls.
- [Apple: SwiftUI input events](https://developer.apple.com/documentation/swiftui/input-events/), consulted 2026-09-27: focused views can handle key presses; verify interaction with the panel's existing shortcuts.
- The approved spec's Spotify saved-track, slider-direction, and accessibility references govern Tasks 2–6. No third-party carousel, gesture, or animation package is needed for these local transforms and existing native controls.

## Self-review and execution handoff

Coverage: contour/focus/window dragging → Task 1; bounded volume → Tasks 2 and 6; liked-song retrieval/state/consent → Tasks 3–4; spinning/scrubbing → Task 5; popover/carousel/queue composition → Task 6; all native/live acceptance → Task 7. The five Review Focus conditions each have an owning test step. Public signatures and lifecycle ownership above are shared across tasks; no task may silently substitute a conflicting interface.

Recommend continuing Native execution for this refinement: its seven tasks share window, playback, library, and view state, so one implementer can retain the integration context and finish with a fresh whole-branch review. Review this plan before execution; preserve the previously selected Native method unless the user requests a different one.
