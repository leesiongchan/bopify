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

- [x] **Step 1:** Add failing tests `catalogUsesExistingStableIDs`, `openingAndFocusWriteNothing`, `activationSavesOnlyItsFamily`, `invalidIDsUseExistingFallbacks`, `sameChoiceDoesNotRewrite`, `recreationKeepsBothPreferences`, `focusTraversesGroupsAndClamps`. Include `drift` fallback and unrelated defaults. Observe writes for the no-op test, not only final strings. Representative assertions:

  ```swift
  defaults.set("carnival", forKey: VinylDesign.preferenceKey)
  let model = RecordAppearancePickerModel(defaults: defaults)
  model.move(.right)
  #expect(defaults.string(forKey: RecordDesign.preferenceKey) == nil)
  model.activateFocused()
  #expect(defaults.string(forKey: RecordDesign.preferenceKey) == "glass")
  #expect(defaults.string(forKey: VinylDesign.preferenceKey) == "carnival")
  ```

- [x] **Step 2:** Run `RecordAppearancePickerModelTests` with the focused command below; establish failure from the missing API. Implement the model with existing resolvers, no write on initialization/refresh, resolved same-choice guards and only stable-ID selection logs through `BopifyLog.playback`. Do not reference an audio engine or persist preview pause.
- [x] **Step 3:** Add `externalDefaultsRefreshDoesNotSave` and `motionFocusActivatesOnlyPreviewPause`. Implement focus navigation: Left/Right/Home/End within a family, Up/Down between families at the same clamped index, stable material-then-pattern catalog order. Native Tab traversal comes in Task 4.
- [x] **Step 4:** Run the new model suite plus `RecordDesignTests`, `VinylDesignTests`, `VinylDesignSelectionTests`; expect no failures. Review and commit `feat: model unified record appearance choices`.

### Task 2: Deterministic exchange and geometry

**Files:** Create `Bopify/Views/RecordAppearanceMotion.swift`, `Bopify/Views/RecordAppearanceGeometry.swift`, `BopifyAppTests/RecordAppearanceMotionTests.swift`, `BopifyAppTests/RecordAppearanceGeometryTests.swift`.

**Interfaces:**
- Consume Task 1's choice/family types. Produce value-type `RecordAppearanceMotion`, `typealias Instant = SuspendingClock.Instant`, `init(material: RecordDesign, pattern: VinylDesign, at: Instant)`; mutating `select(_ choice: RecordAppearanceChoice, at: Instant)`, `advance(to: Instant)`, `setPaused(_ paused: Bool, at: Instant)`, `setReducedMotion(_ reduced: Bool, at: Instant)`, `setVisible(_ visible: Bool, at: Instant)`, `settle(material: RecordDesign, pattern: VinylDesign, at: Instant)`.
- Expose `snapshot: Snapshot`, `needsFrames: Bool`. Snapshot has per-family deck state (`phase`, optional `mounted`, `desired`, `labelChoice`, `armAngle`, `needleLift`, `speed`) and one `RecordFrame` per catalog choice (`choice`, `from`, `to`, `progress`, `travelAngle`, `motorAngle`, `lift`, `zIndex`). `Placement` is `.edge`, `.extracted` or `.platter`; choice supplies family/slot. Phase is `.play`, `.prepare`, `.swap`, `.settle`, `.restore`, `.lower`, plus a bounded cancellation-return stage if needed. Durations are named constants.
- `RecordAppearanceGeometry(sceneWidth: CGFloat)` exposes `deckFrame: CGRect`, `sceneHeight: CGFloat`, `recordDiameter: CGFloat`; `platterCenter(in: RecordAppearanceFamily) -> CGPoint`, `tonearmPivot(in: RecordAppearanceFamily) -> CGPoint`, `home(for: RecordAppearanceChoice) -> CGPoint`, `extracted(for: RecordAppearanceChoice) -> CGPoint`, `pose(for: RecordAppearanceMotion.RecordFrame, peek: Bool) -> Pose`. Pose contains centre, angle, lift and scale fixed at 1.

- [x] **Step 1:** Write failing explicit-clock tests: `needleClearsBeforeSwap`, `bothRecordsCrossTogether`, `mountedLabelChangesAfterDocking`, `loweringRestartsBothEqualMotors`, `sameChoiceHasNoFlight`, `lastSelectionWinsDuringPrepare`, `lastSelectionWinsDuringSwap`, `returningToMountedDuringPrepareIsSafe`, `selectingOutgoingDuringSwapLeavesExactlyOneMounted`, `familiesExchangeIndependently`. Initialize with a fixed `start` and call `setVisible(true, at: start)` before flight tests; advance with `start.advanced(by:)`, not sleeps. Assert phase ordering and final identity invariants; do not duplicate easing implementation in tests.
- [x] **Step 2:** Run the motion suite to establish failure, then implement independent decks using the exact stage durations, quintic smootherstep, approximately 55° extraction / 180° total travel, raised-needle restore and continuous lift/shadow input. Preserve angles and direct crossing. Integrate elapsed time for both motors, coalesce requests, catch up across a long frame interval, and keep motor restart eligible for a frame after lowering finishes.
- [x] **Step 3:** Add `pauseStopsCruiseButAllowsExchange`, `reducedMotionDuringEveryPhaseSettlesLatest`, `hiddenDuringFlightSettlesWithoutFrames`, `resizeSettlementCancelsOldFlight`, `reopenUsesLatestSavedChoices`, `longFrameGapDoesNotLoseSelection`. Hidden/reduced means `needsFrames == false`; settled latest choices and labels agree. Re-showing retains pause intent, Reduced Motion always wins, and settling never writes defaults.
- [x] **Step 4:** Write failing geometry tests at scene widths 758 and 898 for exactly half-visible homes, fully visible extraction, proportional platter alignment, equal/constant diameter, fixed z-order and direct straight-path exchange. Implement from the accepted 1509 × 1042 source: deck width `min(604, sceneWidth * 0.68)`, diameter `deckWidth * 570 / 1509`, deck y=10, centred x, calibrated source centres/pivots from the spec, arm length `0.86 * diameter`. Scene height is `ceil(max(deckHeight + 24, diameter * 1.85 + 24))`; first home y `0.80 * diameter + 4`, last y `sceneHeight - diameter / 2 - 14`, equal catalog spacing. Extract centre `diameter * 0.54 + 4` from either edge; peek at most 8 pt.
- [x] **Step 5:** Sample both full arm/cartridge silhouettes against uppermost crossing discs at both widths; require at least 8 pt clearance for the native silhouette. Resolve any necessary few-pixel spacing correction without changing approved proportions or direct travel. Run motion, geometry and Task 1 suites; review and commit `feat: animate physical record exchanges in settings`.

### Task 3: Native scene, resources, typography and controls

**Files:** Create `Bopify/Views/RecordAppearancePicker.swift`, `RecordAppearanceScene.swift`, `RecordAppearanceDeck.swift`, `RecordAppearanceResources.swift`, `RecordAppearanceOptionLayout.swift`, `BopifyAppTests/RecordAppearanceRenderingTests.swift`; add `Bopify/Resources/RecordAppearance/`. Modify `Bopify/Localizable.xcstrings`; extend `BopifyAppTests/VinylRenderingFixture.swift` only for reusable comparisons actually needed.

**Interfaces:**
- Consume Tasks 1–2, `VinylPressingView`, `RecordMaterialSheen` and existing palette behavior. Produce `RecordAppearancePicker(model: RecordAppearancePickerModel, onClose: @escaping () -> Void = {})`, `RecordAppearanceScene(model: RecordAppearancePickerModel)`, `RecordAppearanceDeck(geometry: RecordAppearanceGeometry, snapshot: RecordAppearanceMotion.Snapshot)` as native Views. The scene owns one motion value; saved selections remain in the model.
- `RecordAppearanceOptionLayout: Layout` wraps horizontal buttons in stable catalog order.
- `@MainActor enum RecordAppearanceResources`: `static func prepare()`, `static func image(named: String) -> NSImage?`, `static var deck: NSImage?`, `static var corduroy: NSImage?`, `static func plateFont(compact: Bool) -> Font`, `static func recordFont(compact: Bool) -> Font`. Use the module's `Bundle(for:)` marker, including tests; register fonts once at process scope through CoreText and verify their PostScript names. The image properties use the shared lookup; a missing name returns nil for a readable view fallback.

- [x] **Step 1:** Add failing built-bundle tests for exact image sizes/alpha, both font identities and both licenses. Copy only `sunburst-deck.png`, `corduroy-crisp.png`, `Allura-Regular.ttf`, `Allura-OFL.txt`, `IBMPlexSansCondensed-Medium.ttf`, `IBMPlexSansCondensed-OFL.txt` from the approved review bundle into app resources. Do not ship reference photos, old fonts, prompts, screenshots or browser code.
- [x] **Step 2:** Implement the resource boundary: process-local font registration and native sizes; a once-only existing-category error log plus plain readable fallback for missing resources instead of a crash. Missing/bad required resources remain failing packaging tests. Do not rely on installed system fonts or remove licenses.
- [x] **Step 3:** Add failing native rendering/layout tests mounting saved Glass/Bloom choices at ideal/compact sizes. Assert all nine accessible choices, one selected per group, fitted horizontal/wrapped rows, visibly transparent Glass and opaque Nacre using existing shaders. Implement the scene/deck/options with chooser seed 42, existing colorful palette, a muted `.tinted` sample, 0.43 label ratio and native sample label art. No classifier changes or artwork requests.
- [x] **Step 4:** Compose image/background below fixed-z records, then native arms/cartridges/spindles above them. Resolve positions through Task 2 geometry; keep stationary sheen. Clipped edge artwork is a pointer shortcut, not a duplicate keyboard/accessibility control. Save through the model, and render mounted names from `snapshot.labelChoice`.
- [x] **Step 5:** Match the spec's resource and UI details: square 625-pt cloth tiles below the title region, horizontal repeat only, no blur/stretch; small metal screw-mounted laser plate; level Allura names; dark detailed gimbaled arms and hardware; 32-pt buttons with 8-pt corners, checkmarks and focus outline. Add localized unified title/menu/help/group/summary/motion/accessibility strings, reusing existing choice names. Keep the main-player surface and its glass/blur behavior unchanged.
- [x] **Step 6:** Use one `TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !motion.needsFrames))`, calling `advance(to: SuspendingClock.now)` from a view update callback, never mutating state during body evaluation. Route selection, pause, Reduce Motion and visibility to the motion methods. Use short implicit animation only for hover/focus nudge, not engine travel. Geometry changes settle current saved choices. Propagate Reduce Transparency to the renderer and preserve readable selected/focus treatment under Increased Contrast.
- [x] **Step 7:** Test a deliberately long localized name in the wrapping layout, a missing image lookup returning nil, and opaque reduced-transparency Glass with unchanged saved choice/label. Inspect the plain view fallback branch during review without removing a real bundled resource to force failure. Capture real WindowServer/Metal ideal/compact/Retina results and compare to the approved screenshot, including exact fonts, cloth, hardware and clipping. Run Task 1–3 suites and existing material rendering tests; review and commit `feat: render unified turntable appearance settings`.

### Task 4: Menu, native input and window lifecycle

**Files:** Create `Bopify/MenuBar/RecordAppearanceWindowController.swift`, `BopifyAppTests/RecordAppearancePickerTests.swift`; modify `Bopify/MenuBar/StatusItemController.swift` and `Bopify/Localizable.xcstrings`. Remove obsolete `RecordDesignWindowController.swift`, `VinylDesignWindowController.swift`, `Views/RecordDesignPicker.swift`, `RecordDesignPickerModel.swift`, `VinylDesignPicker.swift`, `VinylDesignPickerModel.swift` and their two old picker UI test suites after replacing coverage. Preserve catalogs, rendering, preference selection and player continuity.

**Interfaces:** Consume `RecordAppearancePicker(model:onClose:)` and the model. Produce `@MainActor final class RecordAppearanceWindowController` with `init(defaults: UserDefaults = .standard)`, `show()`, `close()`. Its private NSWindow subclass/delegate routes unmodified navigation/activation/Escape and visibility/occlusion into the model. Status menu owns one controller and one `showRecordAppearance(_:)` action.

- [x] **Step 1:** Write failing native tests `oneWindowIsReused`, `savedChoicesAppearOnOpenWithoutWrites`, `realKeysFocusBeforeSaving`, `motionButtonSpaceDoesNotActivateLastChoice`, `modifiedKeysUseNormalWindowRouting`, `escapeClosesAndRetainsChoices`, `closedDefaultsChangesAppearOnReopen`, `closeDuringCrossingReopensSettled`, `occlusionStopsPreviewWork`. Reuse existing accessibility traversal and capture conventions. Identify choices by existing `record.design.*` / `vinyl.design.*` IDs. Include Tab/Shift-Tab, family transfer, Home/End, Enter and Space.
- [x] **Step 2:** Run the new suite to establish failure, then implement one reusable titled/closable full-size-content window, `record-appearance` identifier, fit-to-screen sizing and draggable title/background. Use actual window controls and the spec's 38-pt title region. Refresh selections before showing, no stale replay; add no general window-size preference.
- [x] **Step 3:** Synchronize FocusState with `RecordAppearanceFocus`. Leave Tab to normal native traversal; route unmodified arrows/Home/End/activation to the focused target only and preserve modified shortcuts. Expose selected state per family and effective preview motion state. Mark duplicate artwork, mounted sample labels and hardware decorative. Escape/close stops work without reverting preferences.
- [x] **Step 4:** Route close/visibility/occlusion callbacks to `isPreviewVisible`. Re-show uses latest saved choices; paused preview still supports exchanges, and Reduced Motion overrides resume. Replace both menu entries with localized `Record Appearance…`; remove unused old picker code/tests and localization entries only when no consumer remains.
- [x] **Step 5:** Run the new chooser suites and existing `RecordDesignTests`, `VinylDesignTests`, `VinylDesignSelectionTests`, `RecordContinuityTests`. Extend the existing continuity fixture to select both preferences through the new chooser at rest/mid-handoff: assert no extra engine load/seek, no queue change, retained outgoing appearance and rotation identity. Update only legitimately changed chooser expectations. Review and commit `feat: combine record settings in one appearance window`.

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

## Native verification — 2026-11-04

- Full `BopifyAppTests` through `scripts/test-vinyl-rendering.py --all --derived-data-path /tmp/bopify-appearance-tests`: **298 tests / 415 parameterized runs passed, 0 failures, 0 skipped**. Result: `/tmp/bopify-appearance-tests/Logs/Test/Test-BopifyAppTests-2026.11.04_22-28-14-+0800.xcresult`.
- `swift test --package-path Packages/BopifyCore`: **460 tests passed** (210 playback, 119 library, 36 domain, 95 core).
- Foreground native keyboard host: arrows, Home/End, Enter/Space, Tab/Shift-Tab, preview-only motion activation, Escape and window reuse passed. No user keyboard/accessibility settings were changed.
- WindowServer/Metal Retina captures inspected at 760×631 and 900×655: `/tmp/bopify-vinyl-validation/appearance-native-{760,900}-{mounted,crossing,settled,motor-resumed}.png`. Also `appearance-{760,900}.png`. Both uppermost records exchanged simultaneously; full cartridges cleared, records kept their diameter/layers, names stayed on the wood, and motor restart changed the rendered record.
- Native Glass transparency/opaque fallback and player label/rotation/handoff continuity passed through the capture bridge. Core Reduce Motion, pause, cancellation and hidden/resize/reopen behavior passed explicit-clock tests. One shared TimelineView; process-cached resources/fonts; no per-record clocks or per-frame pixel generation.
- Debug build with unchanged project signing: passed.
- Direct Xcode Release using the project’s Developer ID setting: no usable Developer ID Application certificate/private-key pair for team `6RS6K2N242` was found. This does not establish that a private key was lost. Unsigned Release compilation passed. The normal release script overrides that setting with ad-hoc signing; a subsequent Release build using its signing flags and `codesign --verify --deep --strict` both **passed**. No project signing configuration changed.
- Actual VoiceOver speech and whole-window system Reduce Motion/Transparency/Increased Contrast variants were not manually exercised. Native AX choice names, independent selected values, focus/activation and effective motion values were verified; read-only system environment propagation remains intact.
- Existing framework QoS diagnostic in `MusicBrowserTests.swift` appeared in the test result; no test failed and that subsystem was not changed.

## Execution decisions

1. Conservative full-cartridge geometry initially required an 18-pt upward pivot adjustment; native capture then showed counterweight overhang. The final correction is a **6-pt upward pivot adjustment and 18-pt lower first edge slot**, with smaller counterweights. Full-silhouette clearance remains ≥8 pt. This changes edge-stack spacing slightly from the study; source y=876 keeps mounted names on the lower sunburst.
2. SwiftUI's accessibility contrast/transparency environments are read-only on this SDK. Existing real renderer override tests verify opaque Glass; actual system variants and VoiceOver speech are reported as unverified rather than changing user settings.
3. Explicit edit focus alone did not make native Tab traverse the hosted custom buttons. This window routes Tab/Shift-Tab across the fixed catalog and motion control, while synchronizing native FocusState. Modified shortcuts retain normal routing. New controls must be added to that order.
4. The optional Developer ID signing check lacked a usable local identity. The existing distribution flow uses ad-hoc signing (`scripts/release.sh`), which does not need that identity; the Release app’s ad-hoc signature was subsequently verified. Packaging and publishing were not performed.

## Final independent review and fix verification

A fresh reviewer found two Important issues: scene-sized record pointer targets and clipping at intermediate window widths. Both were reproduced and fixed in one pass:

- Foreground native mouse checks failed for both visible edge discs and blank deck space with the original modifier order. They passed after attaching circular hit areas/handlers to the diameter-sized sample before positioning it. The harness waits for the new pointer window to be active and key.
- Native AX bounds failed at 850×655, 820×631 and 760×580. The picker now allocates wrapped control height first, then fits proportional deck/record geometry in the remaining scene height. All controls retain ≥30-pt accessible targets and remain in the window. Full parked silhouettes retain ≥8-pt clearance at the adaptive sizes.
- Additional inspected Retina captures: `/tmp/bopify-vinyl-validation/appearance-fit-{900x655,850x655,820x631,760x580}.png`.
- Final full app result: **299 tests / 421 parameterized runs passed, 0 failures, 0 skipped**. Result: `/tmp/bopify-appearance-tests/Logs/Test/Test-BopifyAppTests-2026.11.04_23-10-33-+0800.xcresult`.
- Final package rerun: **460 passed**. Final Debug and unsigned Release builds: **passed**. `git diff --check`: passed.
- The combined runner's foreground host had one startup activation timeout after its app suite passed. The same input harness subsequently passed standalone with all keyboard, pointer, blank-space and real preview-visibility checks. Failure diagnostics now report activation policy, active Space and key-window state. A live interactive desktop remains required for this fixture.
- Animation captures explicitly control preview visibility because a background XCTest process can be on an inactive Space while its backing window remains capturable. The foreground input harness separately verifies real AppKit visibility; lifecycle tests retain hidden/close coverage.
- No Critical findings or declined-to-judge items. No second review was dispatched; both Important fixes have RED→GREEN evidence and a passing full app suite.

Resolved on 2026-11-05: the previously deferred Reduce Motion keyboard issue is fixed. Tab/Shift-Tab skip the disabled motion control, and Space/Enter cannot change preview pause intent while Reduce Motion is enabled. Record choices remain available.

The local implementation is preserved on `feat/record-appearance`. Ad-hoc Release signing and signature validation passed using the existing release workflow’s flags. Developer ID signing remains unavailable locally; it is not required by the current release workflow. Manual VoiceOver/full-window system accessibility variants remain unverified.

## Signing clarification — 2026-11-04

The earlier report that “Release signing remains blocked” was too broad. `README.md` and `scripts/release.sh` specify an ad-hoc-signed, non-notarized release. The release script sets `CODE_SIGN_IDENTITY=-`, `CODE_SIGN_STYLE=Manual`, and an empty `DEVELOPMENT_TEAM`, overriding the Xcode project’s default Developer ID setting.

Verified the Release app with those existing flags using `/tmp/bopify-appearance-release` derived data: **BUILD SUCCEEDED**. `codesign --verify --deep --strict --verbose=2 /tmp/bopify-appearance-release/Build/Products/Release/Bopify.app` reported **valid on disk** and **satisfies its Designated Requirement**. Logs: `/tmp/bopify-appearance-release-adhoc.log` and `/tmp/bopify-appearance-release-signature.log`. This validates the app build/signature, not the complete DMG packaging or publication workflow.

## Reduce Motion keyboard follow-up — 2026-11-05

The native keyboard route now reads the current accessibility setting on every Tab or activation event. The model excludes the disabled motion control from traversal and ignores activation from stale motion focus. Existing pause/resume intent survives Reduce Motion changes; activation of record choices is unaffected.

Regression tests failed before the guard/traversal fix and passed afterward. Model tests cover both pause intents, forward/reverse wrapping, stale focus and record activation. A native window key-event test uses a controlled accessibility reader to exercise Space, Enter, Tab, Shift-Tab and turning Reduce Motion off without changing system accessibility preferences.

Full native validation through `scripts/test-vinyl-rendering.py --all --derived-data-path /tmp/bopify-appearance-tests`: **304 tests / 427 parameterized runs passed, 0 failures, 0 skipped**. The foreground keyboard/pointer harness also passed. Result: `/tmp/bopify-appearance-tests/Logs/Test/Test-BopifyAppTests-2026.11.05_00-22-15-+0800.xcresult`; log: `/tmp/bopify-reduced-motion-full.log`.

The updated ad-hoc Release build and `codesign --verify --deep --strict` both passed. Logs: `/tmp/bopify-reduced-motion-release.log` and `/tmp/bopify-reduced-motion-signature.log`. `git diff --check` passed.
