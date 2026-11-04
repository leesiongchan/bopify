# Unified Record Appearance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two record choosers with the approved native sunburst turntable settings window, preserving independent material/pattern preferences.

**Architecture:** A SwiftUI chooser and reusable AppKit window own the settings experience. A preference/focus model saves independently of a deterministic two-deck preview state machine; normalized geometry resolves preview motion into coordinates. Reuse existing native Metal records and bundle the accepted decoration/fonts, leaving the main player's rendering and handoff policy intact.

**Tech Stack:** Existing Swift 6, SwiftUI, AppKit, CoreText, Metal and Swift Testing; macOS 26/Apple silicon. No package, toolchain, Rust or network-runtime changes.

**Spec:** `docs/superpowers/specs/2026-11-01-record-appearance-design.md`, approved 2026-11-01. Approved assets and screenshot: `docs/superpowers/specs/assets/record-appearance/`.

## Global Constraints

- Keep `player.recordDesign` and `player.vinylDesign`, their existing IDs/defaults/fallbacks, and immediate independent persistence. Opening, focusing or hovering writes nothing.
- Do not reset preferences to the study's Glass/Bloom examples. Do not alter playback, queue, player rotation, classification, shaders or outgoing appearance snapshots.
- One **Record Appearance…** menu entry and reusable window, identifier `record-appearance`; replace obsolete chooser implementations and UI tests.
- Ideal content approximately **900 × 655 pt**, compact approximately **760 × 631 pt**; horizontal option rows wrap without horizontal scrolling.
- Edge candidates are exactly half visible at rest. All record diameters remain equal and constant through motion. Layer order never changes on hover/selection.
- Prepare **0.46 s**, swap **0.86 s**, settle **0.08 s**, restore **0.28 s**, lower **0.16 s**. Needle clears before simultaneous straight-path exchange. Both motors cruise at **45 degrees per second**, not RPM.
- BOPIFY plate **54 × 18 pt** / **48 × 16 pt**, IBM Plex Sans Condensed Medium **7 pt** / **6.2 pt**, flat **#cbd0c6**, no text shadow. Level mounted names use Allura Regular **24 pt** / **22 pt**.
- Corduroy source **1254 × 1254**, displayed **625 × 625 pt**, no blur/stretch. Use the exact accepted sunburst image and preserve font licenses.
- Reduce Motion settles immediately and stops continuous spin. Reduce Transparency preserves the existing opaque Glass fallback. Hidden/closed/occluded windows do not run clocks.
- Localize copy; provide native accessible choices, focus, activation and Escape. No slogans, stage narration, browser-only notes or simulated window controls.
- No installation, packaging, publishing, release or signing-configuration changes.

## Review Focus

1. Re-selecting the mounted/outgoing record during parking must not duplicate a disc or lower a needle across it: Task 2 tests cancellation and both flight directions.
2. Close, occlusion, resize or an accessibility change mid-flight must not leave stale work, a stuck needle or stopped motor on reopen: Tasks 2 and 4.
3. Existing/invalid defaults and external changes while closed must retain compatibility without incidental writes: Tasks 1 and 4 use isolated defaults.
4. Arrow/Space interception can desynchronize native/SwiftUI focus or activate the previous choice from the motion button: Task 4 drives actual native events.
5. Resource packaging, long names or the compact layout can substitute fonts, blur cloth, hide Glass transparency or collide with a cartridge: Tasks 3 and 5 require native resources/captures.

## File Responsibilities and Tasks

Unless prefixed with `docs/` or `Packages/`, paths below are relative to `Bopify/`. The Xcode project uses filesystem-synchronized groups; add no redundant explicit source/resource entries.

### Task 1: Independent preferences and focus

**Files:** Create `Bopify/Views/RecordAppearanceChoice.swift`, `Bopify/Views/RecordAppearancePickerModel.swift`, `BopifyAppTests/RecordAppearancePickerModelTests.swift`.

**Interfaces:**
- `enum RecordAppearanceFamily: CaseIterable, Hashable { case material, pattern }`.
- `enum RecordAppearanceChoice: Hashable { case material(RecordDesign), pattern(VinylDesign) }`, exposing `family: RecordAppearanceFamily`, `index: Int`, `nameKey: String`, `accessibilityIdentifier: String`, and `static func choices(in: RecordAppearanceFamily) -> [Self]`. Derive names/IDs from the existing catalogs, not copied tables.
- `enum RecordAppearanceFocus: Hashable { case choice(RecordAppearanceChoice), motion }`.
- `@MainActor @Observable final class RecordAppearancePickerModel`: `init(defaults: UserDefaults = .standard)`; read-only `selectedMaterial: RecordDesign`, `selectedPattern: VinylDesign`; writable `focused: RecordAppearanceFocus`, `isMotionPaused: Bool`, `isPreviewVisible: Bool`.
- Methods `select(_ choice: RecordAppearanceChoice)`, `refreshPreferences()`, `activateFocused()`, `move(_ direction: NavigationDirection)`. Nested `NavigationDirection` has `left, right, up, down, first, last`. Motion-focused activation toggles preview pause; arrows there do nothing.

- [ ] **Step 1:** Add failing tests `catalogUsesExistingStableIDs`, `openingAndFocusWriteNothing`, `activationSavesOnlyItsFamily`, `invalidIDsUseExistingFallbacks`, `sameChoiceDoesNotRewrite`, `recreationKeepsBothPreferences`, `focusTraversesGroupsAndClamps`. Include `drift` fallback and unrelated defaults. Observe writes for the no-op test, not only final strings. Representative assertions:

  ```swift
  defaults.set("carnival", forKey: VinylDesign.preferenceKey)
  let model = RecordAppearancePickerModel(defaults: defaults)
  model.move(.right)
  #expect(defaults.string(forKey: RecordDesign.preferenceKey) == nil)
  model.activateFocused()
  #expect(defaults.string(forKey: RecordDesign.preferenceKey) == "glass")
  #expect(defaults.string(forKey: VinylDesign.preferenceKey) == "carnival")
  ```

- [ ] **Step 2:** Run `RecordAppearancePickerModelTests` with the focused command below; establish failure from the missing API. Implement the model with existing resolvers, no write on initialization/refresh, resolved same-choice guards and only stable-ID selection logs through `BopifyLog.playback`. Do not reference an audio engine or persist preview pause.
- [ ] **Step 3:** Add `externalDefaultsRefreshDoesNotSave` and `motionFocusActivatesOnlyPreviewPause`. Implement focus navigation: Left/Right/Home/End within a family, Up/Down between families at the same clamped index, stable material-then-pattern catalog order. Native Tab traversal comes in Task 4.
- [ ] **Step 4:** Run the new model suite plus `RecordDesignTests`, `VinylDesignTests`, `VinylDesignSelectionTests`; expect no failures. Review and commit `feat: model unified record appearance choices`.

### Task 2: Deterministic exchange and geometry

**Files:** Create `Bopify/Views/RecordAppearanceMotion.swift`, `Bopify/Views/RecordAppearanceGeometry.swift`, `BopifyAppTests/RecordAppearanceMotionTests.swift`, `BopifyAppTests/RecordAppearanceGeometryTests.swift`.

**Interfaces:**
- Consume Task 1's choice/family types. Produce value-type `RecordAppearanceMotion`, `typealias Instant = SuspendingClock.Instant`, `init(material: RecordDesign, pattern: VinylDesign, at: Instant)`; mutating `select(_ choice: RecordAppearanceChoice, at: Instant)`, `advance(to: Instant)`, `setPaused(_ paused: Bool, at: Instant)`, `setReducedMotion(_ reduced: Bool, at: Instant)`, `setVisible(_ visible: Bool, at: Instant)`, `settle(material: RecordDesign, pattern: VinylDesign, at: Instant)`.
- Expose `snapshot: Snapshot`, `needsFrames: Bool`. Snapshot has per-family deck state (`phase`, optional `mounted`, `desired`, `labelChoice`, `armAngle`, `needleLift`, `speed`) and one `RecordFrame` per catalog choice (`choice`, `from`, `to`, `progress`, `travelAngle`, `motorAngle`, `lift`, `zIndex`). `Placement` is `.edge`, `.extracted` or `.platter`; choice supplies family/slot. Phase is `.play`, `.prepare`, `.swap`, `.settle`, `.restore`, `.lower`, plus a bounded cancellation-return stage if needed. Durations are named constants.
- `RecordAppearanceGeometry(sceneWidth: CGFloat)` exposes `deckFrame: CGRect`, `sceneHeight: CGFloat`, `recordDiameter: CGFloat`; `platterCenter(in: RecordAppearanceFamily) -> CGPoint`, `tonearmPivot(in: RecordAppearanceFamily) -> CGPoint`, `home(for: RecordAppearanceChoice) -> CGPoint`, `extracted(for: RecordAppearanceChoice) -> CGPoint`, `pose(for: RecordAppearanceMotion.RecordFrame, peek: Bool) -> Pose`. Pose contains centre, angle, lift and scale fixed at 1.

- [ ] **Step 1:** Write failing explicit-clock tests: `needleClearsBeforeSwap`, `bothRecordsCrossTogether`, `mountedLabelChangesAfterDocking`, `loweringRestartsBothEqualMotors`, `sameChoiceHasNoFlight`, `lastSelectionWinsDuringPrepare`, `lastSelectionWinsDuringSwap`, `returningToMountedDuringPrepareIsSafe`, `selectingOutgoingDuringSwapLeavesExactlyOneMounted`, `familiesExchangeIndependently`. Initialize with a fixed `start` and call `setVisible(true, at: start)` before flight tests; advance with `start.advanced(by:)`, not sleeps. Assert phase ordering and final identity invariants; do not duplicate easing implementation in tests.
- [ ] **Step 2:** Run the motion suite to establish failure, then implement independent decks using the exact stage durations, quintic smootherstep, approximately 55° extraction / 180° total travel, raised-needle restore and continuous lift/shadow input. Preserve angles and direct crossing. Integrate elapsed time for both motors, coalesce requests, catch up across a long frame interval, and keep motor restart eligible for a frame after lowering finishes.
- [ ] **Step 3:** Add `pauseStopsCruiseButAllowsExchange`, `reducedMotionDuringEveryPhaseSettlesLatest`, `hiddenDuringFlightSettlesWithoutFrames`, `resizeSettlementCancelsOldFlight`, `reopenUsesLatestSavedChoices`, `longFrameGapDoesNotLoseSelection`. Hidden/reduced means `needsFrames == false`; settled latest choices and labels agree. Re-showing retains pause intent, Reduced Motion always wins, and settling never writes defaults.
- [ ] **Step 4:** Write failing geometry tests at scene widths 758 and 898 for exactly half-visible homes, fully visible extraction, proportional platter alignment, equal/constant diameter, fixed z-order and direct straight-path exchange. Implement from the accepted 1509 × 1042 source: deck width `min(604, sceneWidth * 0.68)`, diameter `deckWidth * 570 / 1509`, deck y=10, centred x, calibrated source centres/pivots from the spec, arm length `0.86 * diameter`. Scene height is `ceil(max(deckHeight + 24, diameter * 1.85 + 24))`; first home y `0.80 * diameter + 4`, last y `sceneHeight - diameter / 2 - 14`, equal catalog spacing. Extract centre `diameter * 0.54 + 4` from either edge; peek at most 8 pt.
- [ ] **Step 5:** Sample both full arm/cartridge silhouettes against uppermost crossing discs at both widths; require at least 8 pt clearance for the native silhouette. Resolve any necessary few-pixel spacing correction without changing approved proportions or direct travel. Run motion, geometry and Task 1 suites; review and commit `feat: animate physical record exchanges in settings`.

### Task 3: Native scene, resources, typography and controls

**Files:** Create `Bopify/Views/RecordAppearancePicker.swift`, `RecordAppearanceScene.swift`, `RecordAppearanceDeck.swift`, `RecordAppearanceResources.swift`, `RecordAppearanceOptionLayout.swift`, `BopifyAppTests/RecordAppearanceRenderingTests.swift`; add `Bopify/Resources/RecordAppearance/`. Modify `Bopify/Localizable.xcstrings`; extend `BopifyAppTests/VinylRenderingFixture.swift` only for reusable comparisons actually needed.

**Interfaces:**
- Consume Tasks 1–2, `VinylPressingView`, `RecordMaterialSheen` and existing palette behavior. Produce `RecordAppearancePicker(model: RecordAppearancePickerModel, onClose: @escaping () -> Void = {})`, `RecordAppearanceScene(model: RecordAppearancePickerModel)`, `RecordAppearanceDeck(geometry: RecordAppearanceGeometry, snapshot: RecordAppearanceMotion.Snapshot)` as native Views. The scene owns one motion value; saved selections remain in the model.
- `RecordAppearanceOptionLayout: Layout` wraps horizontal buttons in stable catalog order.
- `@MainActor enum RecordAppearanceResources`: `static func prepare()`, `static func image(named: String) -> NSImage?`, `static var deck: NSImage?`, `static var corduroy: NSImage?`, `static func plateFont(compact: Bool) -> Font`, `static func recordFont(compact: Bool) -> Font`. Use the module's `Bundle(for:)` marker, including tests; register fonts once at process scope through CoreText and verify their PostScript names. The image properties use the shared lookup; a missing name returns nil for a readable view fallback.

- [ ] **Step 1:** Add failing built-bundle tests for exact image sizes/alpha, both font identities and both licenses. Copy only `sunburst-deck.png`, `corduroy-crisp.png`, `Allura-Regular.ttf`, `Allura-OFL.txt`, `IBMPlexSansCondensed-Medium.ttf`, `IBMPlexSansCondensed-OFL.txt` from the approved review bundle into app resources. Do not ship reference photos, old fonts, prompts, screenshots or browser code.
- [ ] **Step 2:** Implement the resource boundary: process-local font registration and native sizes; a once-only existing-category error log plus plain readable fallback for missing resources instead of a crash. Missing/bad required resources remain failing packaging tests. Do not rely on installed system fonts or remove licenses.
- [ ] **Step 3:** Add failing native rendering/layout tests mounting saved Glass/Bloom choices at ideal/compact sizes. Assert all nine accessible choices, one selected per group, fitted horizontal/wrapped rows, visibly transparent Glass and opaque Nacre using existing shaders. Implement the scene/deck/options with chooser seed 42, existing colorful palette, a muted `.tinted` sample, 0.43 label ratio and native sample label art. No classifier changes or artwork requests.
- [ ] **Step 4:** Compose image/background below fixed-z records, then native arms/cartridges/spindles above them. Resolve positions through Task 2 geometry; keep stationary sheen. Clipped edge artwork is a pointer shortcut, not a duplicate keyboard/accessibility control. Save through the model, and render mounted names from `snapshot.labelChoice`.
- [ ] **Step 5:** Match the spec's resource and UI details: square 625-pt cloth tiles below the title region, horizontal repeat only, no blur/stretch; small metal screw-mounted laser plate; level Allura names; dark detailed gimbaled arms and hardware; 32-pt buttons with 8-pt corners, checkmarks and focus outline. Add localized unified title/menu/help/group/summary/motion/accessibility strings, reusing existing choice names. Keep the main-player surface and its glass/blur behavior unchanged.
- [ ] **Step 6:** Use one `TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !motion.needsFrames))`, calling `advance(to: SuspendingClock.now)` from a view update callback, never mutating state during body evaluation. Route selection, pause, Reduce Motion and visibility to the motion methods. Use short implicit animation only for hover/focus nudge, not engine travel. Geometry changes settle current saved choices. Propagate Reduce Transparency to the renderer and preserve readable selected/focus treatment under Increased Contrast.
- [ ] **Step 7:** Test a deliberately long localized name in the wrapping layout, a missing image lookup returning nil, and opaque reduced-transparency Glass with unchanged saved choice/label. Inspect the plain view fallback branch during review without removing a real bundled resource to force failure. Capture real WindowServer/Metal ideal/compact/Retina results and compare to the approved screenshot, including exact fonts, cloth, hardware and clipping. Run Task 1–3 suites and existing material rendering tests; review and commit `feat: render unified turntable appearance settings`.

### Task 4: Menu, native input and window lifecycle

**Files:** Create `Bopify/MenuBar/RecordAppearanceWindowController.swift`, `BopifyAppTests/RecordAppearancePickerTests.swift`; modify `Bopify/MenuBar/StatusItemController.swift` and `Bopify/Localizable.xcstrings`. Remove obsolete `RecordDesignWindowController.swift`, `VinylDesignWindowController.swift`, `Views/RecordDesignPicker.swift`, `RecordDesignPickerModel.swift`, `VinylDesignPicker.swift`, `VinylDesignPickerModel.swift` and their two old picker UI test suites after replacing coverage. Preserve catalogs, rendering, preference selection and player continuity.

**Interfaces:** Consume `RecordAppearancePicker(model:onClose:)` and the model. Produce `@MainActor final class RecordAppearanceWindowController` with `init(defaults: UserDefaults = .standard)`, `show()`, `close()`. Its private NSWindow subclass/delegate routes unmodified navigation/activation/Escape and visibility/occlusion into the model. Status menu owns one controller and one `showRecordAppearance(_:)` action.

- [ ] **Step 1:** Write failing native tests `oneWindowIsReused`, `savedChoicesAppearOnOpenWithoutWrites`, `realKeysFocusBeforeSaving`, `motionButtonSpaceDoesNotActivateLastChoice`, `modifiedKeysUseNormalWindowRouting`, `escapeClosesAndRetainsChoices`, `closedDefaultsChangesAppearOnReopen`, `closeDuringCrossingReopensSettled`, `occlusionStopsPreviewWork`. Reuse existing accessibility traversal and capture conventions. Identify choices by existing `record.design.*` / `vinyl.design.*` IDs. Include Tab/Shift-Tab, family transfer, Home/End, Enter and Space.
- [ ] **Step 2:** Run the new suite to establish failure, then implement one reusable titled/closable full-size-content window, `record-appearance` identifier, fit-to-screen sizing and draggable title/background. Use actual window controls and the spec's 38-pt title region. Refresh selections before showing, no stale replay; add no general window-size preference.
- [ ] **Step 3:** Synchronize FocusState with `RecordAppearanceFocus`. Leave Tab to normal native traversal; route unmodified arrows/Home/End/activation to the focused target only and preserve modified shortcuts. Expose selected state per family and effective preview motion state. Mark duplicate artwork, mounted sample labels and hardware decorative. Escape/close stops work without reverting preferences.
- [ ] **Step 4:** Route close/visibility/occlusion callbacks to `isPreviewVisible`. Re-show uses latest saved choices; paused preview still supports exchanges, and Reduced Motion overrides resume. Replace both menu entries with localized `Record Appearance…`; remove unused old picker code/tests and localization entries only when no consumer remains.
- [ ] **Step 5:** Run the new chooser suites and existing `RecordDesignTests`, `VinylDesignTests`, `VinylDesignSelectionTests`, `RecordContinuityTests`. Extend the existing continuity fixture to select both preferences through the new chooser at rest/mid-handoff: assert no extra engine load/seek, no queue change, retained outgoing appearance and rotation identity. Update only legitimately changed chooser expectations. Review and commit `feat: combine record settings in one appearance window`.

### Task 5: Native acceptance, whole-change review and cleanup

**Files:** New chooser/model/motion/rendering suites and existing native capture/continuity fixtures as needed; update this plan with actual verification evidence.

**Interfaces:** Consume the Task 1–4 feature. Verification adds no production interface.

- [ ] **Step 1:** Run package and full app suites below. Investigate failures against the spec; preserve valid assertions, existing shader/player coverage and real engine contracts. Capture skips are not native visual proof. Add no unrelated Rust work.
- [ ] **Step 2:** Capture ideal/compact/Retina windows and both uppermost exchanges simultaneously. Inspect full cartridge/stylus clearance, fixed z-order, constant/equal record size, exact plate/font treatment, level handwriting, sharp cloth, readable controls and motor restart. Exercise both pending-choice directions, close/reopen, screen fit, Reduced Motion/Transparency, Increased Contrast, keyboard and VoiceOver. Use actual fixture/capture bridge evidence and enumerate unobservable desktop-dependent behavior.
- [ ] **Step 3:** Verify one shared active clock, no frames after pause deceleration/dismissal/occlusion, no permanent hover animation or per-frame CPU image/font/pixel generation. Use the established native workload/capture approach; investigate visible hitches/excessive work rather than attributing aggregate test-process CPU to production rendering.
- [ ] **Step 4:** Build Debug and signed Release with existing identities/configuration, then verify the signature. If the expected certificate/toolchain is unavailable, report before substituting. Do not change signing, package, install or publish; preserve dependency/toolchain pins.
- [ ] **Step 5:** Remove one-off scripts/harnesses and unused code, retaining regression tests and the approved source-asset bundle. Run `git diff --check`, review the final diff against the spec and obtain whole-change code review through the selected execution workflow. Commit only verification-led fixes with an appropriate Conventional Commit. Record actual results and capture paths here; do not mark complete with material acceptance unverified.

## Verification Commands

Focused suite: substitute the actual suite type for `SUITE`.

```sh
xcodebuild -project Bopify/Bopify.xcodeproj -scheme BopifyAppTests -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/bopify-appearance-tests CODE_SIGNING_ALLOWED=NO -only-testing:BopifyAppTests/SUITE test
```

Full checks:

```sh
swift test --package-path Packages/BopifyCore
xcodebuild -project Bopify/Bopify.xcodeproj -scheme BopifyAppTests -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/bopify-appearance-tests CODE_SIGNING_ALLOWED=NO test
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Debug -derivedDataPath /tmp/bopify-appearance-debug build
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Release -derivedDataPath /tmp/bopify-appearance-release build
codesign --verify --deep --strict --verbose=2 /tmp/bopify-appearance-release/Build/Products/Release/Bopify.app
git diff --check
```

Expected: `TEST SUCCEEDED` / `BUILD SUCCEEDED`, passing package tests, valid signed Release and no whitespace errors. `VinylRenderingFixture.canCapture` must be true for capture acceptance; enumerate skips. For a missing CLI retry with comma per AGENTS.md, without global installs or changes to system accessibility settings. Run Rust setup only if existing required native artifacts are absent or a project-required check demands it; preserve its lock/toolchain.

## Plan Self-Review

- Spec coverage: Tasks 1–2 cover preferences/focus/sequence/state lifecycle; Task 3 covers resources/rendering/type/accessibility variants/layout; Task 4 covers native menu/window/input and player integration; Task 5 verifies fidelity/builds/cleanup/review.
- Interfaces: choice/focus come from Task 1, motion snapshot/geometry from Task 2, view/resource boundaries from Task 3; Task 4 consumes them unchanged. No third saved appearance preference is introduced.
- All five Review Focus risks have owning tests/captures. Native keys and full-arm collisions need integration evidence beyond value-type tests.
- The spec owns appearance/constants; this plan fixes file responsibilities, interfaces, tests, sequence and checks, leaving drawing internals to the builder.

## Approval and Execution

The user approved this plan and native execution on 2026-11-01. Implement in this session with a fresh whole-change review at the end.
