# Muted Record Materials Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add Classic, Glass, and Nacre as an independent saved choice for muted records, with genuine Glass transparency at 50% smoke density.

**Architecture:** Extend the existing SwiftUI/Metal record boundary with a small record-material enum, two bounded shaders, and stationary material lighting. Carry the independent preference through existing appearance snapshots and cover handoffs; reuse native chooser conventions for a separate three-card window. Keep the six colorful-style paths and existing default appearance intact.

**Tech Stack:** Existing Swift 6, SwiftUI, AppKit, Metal stitchable functions, UserDefaults, Swift Testing, and Xcode app tests; macOS 26/Apple silicon. No new dependencies, toolchain changes, or Rust changes.

**Spec:** `docs/superpowers/specs/2026-10-31-muted-record-materials-design.md` (approved 2026-10-31).

## Global Constraints

- Add two selectable materials to the record used for muted covers: Glass and Nacre.
- Preserve the current dark record as the default, provisionally named Classic.
- These are independent of the six colorful vinyl styles.
- Glass: the accepted clear/smoked study at **50% smoke density**, permanently fixed in the product.
- Persist independently under `player.recordDesign`, with stable IDs `classic`, `glass`, and `nacre`.
- Preserve artwork classification, cover artwork, label proportions, playback, rotation, scrubbing, and loading transitions.
- There is no product smoke slider, background selector, per-song override, or new player toolbar control.
- With Reduce Transparency enabled, render Glass using an opaque smoked fallback; keep the preference saved.
- Keep unrelated startup/sign-in record illustrations unchanged.

## Review Focus

1. The shader is transparent but the complete record's backing/shadow obscures the background: Task 2 captures complete records on contrasting backgrounds.
2. Rapid material changes during a replaced/cancelled cover flight mutate the outgoing record: Task 3 tests frozen snapshots and latest-choice settlement through actual player handoffs.
3. A missing cover or transition through a colorful cover loses the muted-material preference: Task 3 covers neutral fallback, both preferences, and session reset.
4. Reduce Transparency or Reduce Motion changes while Glass is visible: Task 2 verifies native fallback/label stability and Task 3 verifies retained preference and motor behavior.
5. Chooser thumbnails hide transparency or keyboard selection changes the colorful-style preference: Task 4 uses contrasting backgrounds and tests real window controls and independent saved state.

## File Responsibilities

Create:
- `Bopify/Bopify/Views/RecordDesign.swift`: catalog, stable IDs, names, density constant, effective-material policy.
- `Bopify/Bopify/Shaders/RecordMaterials.metal`: Glass and Nacre body functions, no clock.
- `Bopify/Bopify/Views/RecordMaterialSheen.swift`: stationary annulus lighting for new materials only.
- `Bopify/Bopify/Views/RecordDesignSelection.swift`: independent preference/handoff snapshot, following `VinylDesignSelection`.
- `Bopify/Bopify/Views/RecordDesignPickerModel.swift`, `RecordDesignPicker.swift`: immediate saved selection and three native previews.
- `Bopify/Bopify/MenuBar/RecordDesignWindowController.swift`: single reusable window and native keyboard routing.
- `Bopify/BopifyAppTests/RecordDesignTests.swift`, `RecordMaterialRenderingTests.swift`, `RecordDesignPickerTests.swift`: policy/persistence, full native rendering, and chooser behavior respectively.

Modify:
- `Bopify/Bopify/Views/VinylPressingView.swift`: add material identity to `PressingAppearance`; dispatch new materials only in the muted path.
- `Bopify/Bopify/Views/VinylRecordView.swift`: coordinate backing/material fade, keep artwork separate, place stationary lighting outside rotating content.
- `Bopify/Bopify/Views/RecordPlayerView.swift`: read independent saved material; preserve it across handoffs and outgoing snapshots.
- `Bopify/Bopify/MenuBar/StatusItemController.swift`: separate Record Design menu item/controller.
- `Bopify/Bopify/Localizable.xcstrings`: new chooser/menu/design copy.
- `Bopify/BopifyAppTests/VinylRenderingFixture.swift`: optional capture background and reusable pixel comparisons as needed.
- `Bopify/BopifyAppTests/RecordContinuityTests.swift`: real player integration coverage.

The Xcode project uses filesystem-synchronized source groups. Do not add redundant explicit project-file entries.

## Verification Commands

Run a focused native suite using the actual suite type in place of `SUITE`:

```sh
xcodebuild -project Bopify/Bopify.xcodeproj -scheme BopifyAppTests -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/bopify-record-tests CODE_SIGNING_ALLOWED=NO -only-testing:BopifyAppTests/SUITE test
```

Expected: `TEST SUCCEEDED`, with no failed tests. Native shader fidelity requires WindowServer/Metal captures via `VinylRenderingFixture`; enumerate capture-related skips rather than treating them as passes. Use the existing host capture bridge if available. Do not weaken assertions or claim visual verification from `NSView.cacheDisplay` when it omits Metal content. On Nix, retry a missing CLI with `,`; do not install tools or modify user settings.

### Task 1: Independent material policy and shader dispatch

**Files:** Create `Views/RecordDesign.swift` and `BopifyAppTests/RecordDesignTests.swift`; modify `Views/VinylPressingView.swift` (all paths relative to `Bopify/Bopify` except the explicitly named test directory).

**Interfaces:** Produce `enum RecordDesign: String, CaseIterable, Sendable` with `.classic`, `.glass`, `.nacre`; `static let preferenceKey = "player.recordDesign"`; `static let glassSmokeDensity: Float = 0.50`; `static func resolve(_ rawValue: String?) -> Self`; `var nameKey: String`; `func resolved(for palette: ArtworkPalette?) -> Self`. Add defaulted `recordDesign: RecordDesign = .classic` to `PressingAppearance` and `VinylPressingView`. `resolved(for:)` returns the saved choice only for `.tinted`; `.marble` and `nil` return `.classic`, preserving unrelated standalone illustrations.

- [x] **Step 1:** Write failing `stableIDsAndInvalidFallback` assertions: raw IDs equal `["classic", "glass", "nacre"]`; nil/unknown resolve to Classic; valid IDs round-trip; density equals `Float(0.50)`; preference key differs from `VinylDesign.preferenceKey`. Add `materialsApplyOnlyToMutedPalettes`: neutral and tinted preserve each material, colorful and nil resolve to Classic. Add `appearanceSnapshotsIncludeMaterial`: changing only `recordDesign` changes `PressingAppearance` equality while an earlier copy remains unchanged.
- [x] **Step 2:** Run the focused `RecordDesignTests` command; confirm failure is the missing material API.
- [x] **Step 3:** Implement the enum and defaulted fields. Preserve all existing call sites through default values; rendering dispatch is added with the shaders in Task 2. Retain Classic's existing tint path exactly, including nil's existing vinyl shader and every colorful path.
- [x] **Step 4:** Run `RecordDesignTests`, `VinylDesignTests`, and `VinylDesignSelectionTests`; expect all policy tests passing and no changed colorful/muted-default contract.
- [x] **Step 5:** Review the task diff and commit with `feat: add independent muted record materials`, explaining preference independence in the body. Include only this task's files.

### Task 2: Native Glass/Nacre materials and correct compositing

**Files:** Create `Shaders/RecordMaterials.metal`, `Views/RecordMaterialSheen.swift`, and `BopifyAppTests/RecordMaterialRenderingTests.swift`; modify `Views/VinylPressingView.swift`, `Views/VinylRecordView.swift`, and `BopifyAppTests/VinylRenderingFixture.swift`.

**Interfaces:** Consume Task 1's `RecordDesign` and defaulted view argument. Add `recordDesign: RecordDesign = .classic` to `VinylRecordView`. Produce stitchable `half4 recordGlass(float2 position, half4 color, float2 size, float seed, float density, float opaque)` and `half4 recordNacre(float2 position, half4 color, float2 size, float seed)`. Produce `RecordMaterialSheen(design: RecordDesign, diameter: CGFloat, labelRatio: CGFloat)` as a stationary, noninteractive View. Extend the fixture's content capture with a trailing defaulted `background: Color = .black` argument, leaving existing consumers unchanged.

- [x] **Step 1:** Capture pre-change Classic/full-record and colorful baselines with the existing fixture. Add failing shader-availability and native rendering tests. For complete `VinylRecordView`s at diameters 118 and 182, use a fixed opaque red label and fixed rotation angle. On black versus white backgrounds, assert Glass changes more than 50% of annulus samples by at least `8/255`, while Nacre changes fewer than 1% (allowing antialiased edges by sampling radius `0.50...0.93`). Label-interior samples excluding the spindle must stay red within `8/255` for both backgrounds. Capture Classic and both new materials pairwise; require more than 10% differing annulus samples. Exercise all colorful styles with every saved material and compare with Classic material: zero differing annulus samples. Extend fixture helpers only for comparisons these tests require.
- [x] **Step 2:** Run `RecordMaterialRenderingTests`; establish actual rendering failures, not solely unavailable declarations. Keep native capture requirements visible.
- [x] **Step 3:** Implement bounded procedural shaders. Reconstruct Glass's smoke field from normalized coordinates: `F=sin(5x+1.3sin(4y))+0.42sin(9y-3x)+0.21sin(14x+8y)`, smoke `=(0.5+0.5sin(2F+0.4a))^4`, base alpha `0.50*(0.65+0.9*smoke)` plus the study's restrained groove, wisp, and rim accents, capped at `0.8` before edge coverage. Return premultiplied color. Render an opaque smoked body when `opaque=1`. Nacre uses warped radial layers `w=r+0.055sin(3a+9r)+0.026sin(7a-12r)+0.022sin(9x+4y)` and the accepted low-chroma tonal treatment. Seed only modest deterministic orientation/phase offsets. Filter groove frequency with pixel derivatives at small sizes; avoid subpixel sparkle and per-frame CPU pixel construction.
- [x] **Step 4:** Coordinate the backing and body within one material transition identity, with Glass using a translucent thickness/rim instead of the full dark backing. Keep opaque artwork and spindle outside that transition; keep rotation driven by the existing motor. Position the annulus sheen outside rotating content, cut out the label, preserve the reveal mask and label scaling, and disable hit testing/accessibility on decoration. Preserve Classic's existing layer appearance and all colorful rendering. Apply Reduce Transparency only to Glass's body/backing fallback.
- [x] **Step 5:** Add `reduceTransparencyMakesGlassOpaqueWithoutChangingLabel`: black/white captures with the accessibility environment enabled must differ in fewer than 1% of annulus samples. Add deterministic same-seed captures; verify Classic matches its pre-change native appearance and each new material stays distinct/recognizable at compact size. Run the rendering suites and inspect normal/compact native captures against the accepted browser study at 50% density. Verify stationary lighting at two rotation angles and no opaque rectangle or silhouette beneath Glass.
- [x] **Step 6:** Review the task diff and commit with `feat: render glass and pearl muted records`, describing genuine transparency and the accessibility fallback.

### Task 3: Saved material propagation and record continuity

**Files:** Create `Views/RecordDesignSelection.swift`; modify `Views/RecordPlayerView.swift`, `BopifyAppTests/RecordDesignTests.swift`, and `BopifyAppTests/RecordContinuityTests.swift`.

**Interfaces:** Produce `struct RecordDesignSelection` with `init(rawValue: String? = nil)`, read-only `selected: RecordDesign`, `appearance: RecordDesign`, and mutating `select(rawValue: String?)`, `beginHandoff()`, `finishHandoff()`, following existing `VinylDesignSelection` semantics. Consume the Task 1/2 `recordDesign` properties in both active and outgoing records. Read `@AppStorage(RecordDesign.preferenceKey)` separately from the existing colorful-style preference.

- [x] **Step 1:** Add failing handoff tests: initialize Glass, begin handoff, select Nacre then Classic, assert appearance remains Glass until finish and then Classic; replacement snapshots latest selected material; finish/cancel retains the preference. Add real `RecordPlayerView` fixtures, reusing `RecordContinuityTests`' engine/store/window setup: `materialUpdatesWithoutChangingLabelOrPlayback`, `mutedColorfulMutedRestoresBothPreferences`, `neutralRecordUsesSavedMaterial`, `latestMaterialWaitsForCoverHandoff`, and `sessionResetRetainsBothPreferences`. Use isolated defaults; verify no additional engine load/seek commands and stable label samples, not just a duplicate selection model.
- [x] **Step 2:** Run `RecordDesignTests` and `RecordContinuityTests`; verify missing propagation/handoff behavior fails.
- [x] **Step 3:** Wire material initialization/change handling, load-time appearance resolution, and active/outgoing `VinylRecordView` arguments. Begin/end the material snapshot at the same boundaries as the existing style snapshot, including replacement, cancellation, and session reset. Apply the latest saved material after handoff settlement. Do not clear preferences during sign-out. Material changes must not reset occurrence identity, artwork rotation offset, or the motor.
- [x] **Step 4:** Add native coverage for selecting Glass during an active load and for switching accessibility preferences while it is visible. Verify preference retention, unchanged label/motor, and settled transparent/opaque behavior. Run the continuity, selection, and rendering suites; manually inspect play/pause, scrubbing, next/previous, focus resizing, and both reduced-accessibility modes in the actual native player.
- [x] **Step 5:** Review the task diff and commit with `feat: retain record material across playback transitions`, explaining frozen outgoing records and latest-choice settlement.

### Task 4: Independent native Record Design chooser

**Files:** Create `Views/RecordDesignPickerModel.swift`, `Views/RecordDesignPicker.swift`, `MenuBar/RecordDesignWindowController.swift`, and `BopifyAppTests/RecordDesignPickerTests.swift`; modify `MenuBar/StatusItemController.swift` and `Localizable.xcstrings`.

**Interfaces:** Produce `@MainActor @Observable final class RecordDesignPickerModel` with `init(defaults: UserDefaults = .standard)`, `focused: RecordDesign`, `move(_ direction: Direction)`, `activate()`, and `select(_ design: RecordDesign)`. Its nested Direction supports left/right/up/down; left/right clamp within three cards and up/down keep current focus. Produce `RecordDesignPicker(model: RecordDesignPickerModel = .init(), onClose: @escaping () -> Void = {})` and `RecordDesignWindowController.init(defaults: UserDefaults = .standard)`, `show()`, `close()`. Window ID is `record-design`; card accessibility IDs are `record.design.<stable-id>`.

- [x] **Step 1:** Write failing tests using existing native chooser-test conventions: focus movement changes no saved preference until activation; selecting Glass immediately saves `"glass"` only under `player.recordDesign`; an existing `"carnival"` colorful preference stays unchanged; recreating the chooser preserves Glass; invalid saved material selects Classic; exactly one accessible card is selected; repeated show/close/show reuses the window. Exercise real control activation, Enter/Space and Escape routing, and all three localized labels.
- [x] **Step 2:** Run `RecordDesignPickerTests` and confirm failures are missing native chooser behavior.
- [x] **Step 3:** Implement a one-row, three-card chooser using the same native record renderer at a static rotation and muted sample palette/label. Place a restrained contrasting pattern beneath the thumbnails so Glass's alpha is visible, without adding background controls. Use existing titlebar, auxiliary-window, and immediate-save conventions. Log selection through `BopifyLog.playback` using only stable material ID; no cover or track data. Implement scoped native key routing, focus/accessibility state, single-window reuse, close/Escape, and no animation clock for thumbnails.
- [x] **Step 4:** Add localized keys `menu.recordDesign` = `Record Design…`, `record.title` = `Record Design`, `record.help` = `Choose the material used for muted covers.`, `record.design.classic` = `Classic`, `record.design.glass` = `Glass`, `record.design.nacre` = `Nacre`; use localized selected-state copy following existing conventions. Add the independent menu entry/controller next to the existing vinyl entry without changing its catalog or preference.
- [x] **Step 5:** Run both chooser suites, then verify the real status menu, keyboard focus/activation/dismissal, selected-state contrast, native thumbnails, reopen persistence, and relaunch persistence. Capture the actual chooser. Confirm selecting a material changes no playback or colorful-style preference.
- [x] **Step 6:** Review the task diff and commit with `feat: add a muted record design chooser`, describing the three independent material choices.

### Task 5: Final verification and review

**Files:** Final task-owned sources/tests plus this plan and the approved spec. No new product interfaces.

- [x] **Step 1:** Run `swift test --package-path Packages/BopifyCore` and `./scripts/test-native.sh`; expected zero failures and Clippy warnings. Run the complete native suite by dropping `-only-testing` from the shared Xcode command. Record actual counts, failures, and conditional skips; do not treat skipped GPU captures as native validation.
- [x] **Step 2:** Build the native app and verify signing. Preserve the repository's Apple Development identity for local builds: `xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/bopify-record-release CODE_SIGN_IDENTITY='Apple Development' CODE_SIGN_STYLE=Automatic build`; then `codesign --verify --deep --strict /tmp/bopify-record-release/Build/Products/Release/Bopify.app`. Expected successful build (including shader compilation) and signature verification. If the configured identity is unavailable, report it before choosing a substitute. Do not package, install, publish, or change signing configuration.
- [x] **Step 3:** Compare complete native records before/after at 182px and 118px, Retina backing where available, paused and rotating, over light/dark/patterned backgrounds. Verify label opacity, transparent Glass at the fixed `0.50` smoke parameter, opaque Nacre, readable grooves, stationary sheen, default compatibility, and all accessibility fallbacks. Exercise cover failures, rapid/replaced handoffs, and material changes while loading; preserve native capture evidence under `/tmp/bopify-record-validation/`.
- [x] **Step 4:** Measure comparable existing Classic/new-material rotation and handoff workloads using the project's demonstrated native capture/measurement approach. Investigate excessive GPU work or material regressions; do not equate the XCTest process's aggregate CPU with production rendering cost. Browser studies remain visual references only.
- [x] **Step 5:** Remove task-created one-off verification scripts/harnesses and unused code; keep meaningful regression tests and reusable fixture extensions. Run `git diff --check`, rerun checks affected by cleanup, inspect the final diff against the approved spec, and obtain whole-change code review following the selected execution workflow. Preserve unrelated user changes. Record completed steps and verification evidence in this plan without broadening claims beyond observed results.

## Plan Self-Review

Checked against every spec section: Task 1 owns default/fallback/independence, Task 2 owns material fidelity/compositing/accessibility, Task 3 owns persistence propagation and continuity, Task 4 owns selection/localization, and Task 5 owns native acceptance/build/performance evidence. Every Review Focus item has native or integration coverage in its owning task. Interfaces use one `RecordDesign` name and one `recordDesign` property throughout. Product smoke remains fixed; preview tuning does not become a setting. Implementation is complete; verification evidence and limits are recorded below.

## Execution Handoff

The user approved this plan and native execution on 2026-10-31. Implemented on `feat/muted-record-materials` in `.worktrees/muted-record-materials`; independent whole-change review completed, with findings addressed in one correction pass. The user selected a local merge into `main`; merged-checkout verification passed.


## Verification evidence — 2026-10-31

- Final full native suite, run through `scripts/test-vinyl-rendering.py --all --derived-data-path /tmp/bopify-record-tests`: **263 passed, zero failures, zero skips**. Both active-application keyboard hosts passed focus, Space/Return activation, Escape dismissal, and window reuse checks.
- Swift package suites: **460 tests passed** (210 playback, 119 library, 36 domain, 95 auth). `./scripts/test-native.sh` passed Rust library/doc tests and Clippy; its existing ignored test remains ignored.
- Final Release build and `codesign --verify --deep --strict` succeeded using the existing Apple Development identity and explicitly supplied repository team. No app installation, publication, account access, or playback against live Spotify was performed.
- Native WindowServer captures cover the complete record, including backing, over black/white backgrounds at 118/182pt and Retina backing. Glass reveals the background; its artwork label remains unchanged. Nacre stays opaque. The real chooser and rotating checkerboard workload were visually inspected. Classic and all colorful styles retain baseline coverage.
- Added actual native acceptance coverage for material changes while playing (measured label phase follows the existing motor), material selection during a handoff, replaced handoffs that settle or cancel, neutral artwork, session reset, and restored colorful/muted preferences.
- Mounted native accessibility coverage toggles the existing renderer override inputs without remounting: Glass becomes opaque and returns to transparent; motion pauses/resumes without changing material. User-wide macOS accessibility settings were not modified.
- The independent reviewer identified an angular branch-cut seam in the accepted Glass formula. The new seam-sensitive native test failed before correction and passed afterward. Glass smoke and the related Nacre overtone now use periodic angular modulation. The reviewer also requested the mounted/playing/interrupted-handoff coverage listed above; it passed. No review findings remain deferred.
- `git diff --check` passed. The Release compiler emitted an actor-isolation warning in unchanged `CoverFlowView.swift` during the initial clean build; that unrelated code was left untouched.

Evidence is under `/tmp/bopify-record-validation/`, including `final-native-results.json`, `review-regressions.json`, native PNGs, `performance.json`, and `gpu-summary.json`. Test/build logs are `/tmp/bopify-record-*.log`.

### Rendering cost

Optimized complete native records at 182pt/Retina, measured for three seconds per scenario; values are percent of one CPU core, not whole-app energy or battery measurements:

| Material | Rotation | Repeated palette/label handoff | Rest | Hidden |
| --- | ---: | ---: | ---: | ---: |
| Classic | 4.57% | 7.42% | 0.04% | 0.01% |
| Glass | 4.72% | 9.47% | 0.06% | 0.02% |
| Nacre | 5.39% | 10.68% | 0.01% | 0.02% |

The finishes add expected shading/compositing work during animation; hidden/resting samples remain near idle. Short Metal traces contain 4/6/6 app-owned GPU intervals for Classic/Glass/Nacre, with maximum intervals 0.189/0.259/0.380ms respectively. These are initial/cached rendering-stage observations, not frame time or GPU utilization; subsequent compositing may be attributed to the system. `xctrace` returned status 54 after reporting that each recording was saved; exports succeeded and contained the app-owned intervals, so the traces are retained as limited observations rather than described as clean profiler-command passes.

### Implementation decisions and tradeoffs

These are the executor's recorded rulings, in order:

1. SwiftUI's Reduce Transparency environment value is read-only. Follow the existing Reduce Motion override pattern for deterministic native capture while retaining the system preference as an input. Risk if wrong: override propagation could differ from system behavior; full-record mounted tests cover propagation, but no global OS setting was changed.
2. Extend the existing native capture helper's source list and suite selection instead of creating a second one-off runner. Risk if wrong: helper compatibility; both old and new active-app keyboard hosts passed.
3. Native screenshot conversion maps the red fixture to displayed RGB `(1, 0.1491, 0)`. Compare label samples with same-run Classic within `8/255` instead of testing the vendor's numeric color conversion. Risk if wrong: shared label changes could affect both references; explicit red-dominance assertions and existing artwork coverage remain.
4. Package resource bundles do not inherit the target's development team during the local Release command. Pass the repository's configured team explicitly while preserving Apple Development signing. Risk if wrong: signing compatibility; the final app built and its signature verified. No project signing settings changed.
5. Regrade misleading existing muted-help copy as a user-facing Important issue and explain the separate Record Design selection. Risk if wrong: wording only; this is a necessary consumer update.
6. Correct the accepted study's angular discontinuity with periodic sine modulation in Glass and the related Nacre overtone, preserving density `0.50` and material character. Tradeoff: a small smoke-layout change from the throwaway study; native seam regression and visual captures verify continuity.

No additional review pass was dispatched; the independent review's fixes were verified through the new regressions and final full suite.


## Local integration — 2026-10-31

The user selected local integration. `main` fast-forwarded from `28cddab` to `f4c757b`; no remote update or push was performed. The complete native suite was rerun from the main checkout using `/tmp/bopify-record-merged-tests`: **263 passed, zero failures, zero skips**, followed by passing active-application keyboard checks for both choosers. The **460 Swift package tests** also passed from main. The temporary feature worktree and merged branch are approved for cleanup.

Merged verification artifacts: `/tmp/bopify-record-validation/merged-native-results.json`, `/tmp/bopify-record-merged-native.log`, and `/tmp/bopify-record-merged-package.log`.
