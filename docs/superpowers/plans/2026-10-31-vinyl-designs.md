# Selectable Vinyl Designs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add six native generated vinyl designs and a visual chooser, with a saved global selection, cover-adapted colors, and the existing muted fallback.

**Architecture:** Keep the catalog and palette policy in small app-local value types. Extend `VinylPressingView` with fixed-work Metal functions, carry style through existing appearance snapshots, and use a UserDefaults preference shared by the player and a native chooser opened from the status menu. Preserve the existing renderer, artwork pipeline, and playback state machines.

**Tech Stack:** Existing Swift 6, SwiftUI, AppKit, Metal stitchable shaders, UserDefaults, Swift Testing, and Xcode app tests; macOS 26/Apple silicon as already required by the project. No dependency or toolchain changes.

**Spec:** `docs/superpowers/specs/2026-10-31-vinyl-designs-design.md` (approved 2026-10-31). Read the spec and this plan together; the spec contains the geometry equations and composition constants.

## Global Constraints

- The choice applies globally across songs; each song supplies its own cover palette.
- Muted covers bypass every decorative design and retain the existing subtly tinted record.
- Keep the existing appearance available and preserve it as the default for existing and new installations.
- Preserve cover-driven colors, center artwork, existing rotation, scrubbing, cover loading, and outgoing-record continuity.
- Stable IDs/order: `original`, `undertow`, `drift`, `strata`, `bloom`, `rhapsody`, `carnival`; preference key `player.vinylDesign`; missing/unknown IDs resolve to Original.
- No audio-reactive effects, per-album overrides, manual color controls, an asset download service, dependencies, Rust changes, or a general settings redesign.
- Follow the existing `.marble`/`.tinted` classification before vivid conversion. Only Bloom/Rhapsody/Carnival expand saturation. Original and the first three preserve their specified palette treatments.
- For vivid chromatic slots use HSL saturation at least 0.78 and lightness `clamp(0.76L,0.45,0.62)`; achromatic slots remain neutral accents. Never recolor the center cover.
- Use fixed shader work rather than unbounded per-frame CPU construction or thousands of particle iterations per fragment. Hidden views and chooser thumbnails gain no animation clocks.
- No product code or new dependencies are authorized until this plan is reviewed and the execution method is selected. At execution, use the worktree skill to choose an isolated workspace; preserve all unrelated changes.

## Review Focus

1. A colorful palette containing gray/white or repeated slots must not manufacture unrelated red accents or invalid colors (Task 1).
2. Selecting several styles while artwork is loading, then replacing/canceling that load, must retain captured records and eventually apply only the latest saved selection (Task 4).
3. Hidden or signed-out players must retain the preference without retaining old artwork or starting new rendering work (Tasks 4–5).
4. A muted/missing cover must leave chooser thumbnails distinguishable while its actual record keeps the tint fallback (Tasks 2–3 and 5).
5. Fine patterns at compact size must remain readable without shimmer or excessive rendering work; unchanged Original must keep its baseline appearance (Tasks 2–3 and final validation).

## File responsibilities

| Path | Responsibility |
| --- | --- |
| `Bopify/Bopify/Views/VinylDesign.swift` (new) | Stable catalog, preference key, invalid-ID fallback. |
| `Bopify/Bopify/Views/VinylDesignPalette.swift` (new) | Pure raw/vivid palette resolution and neutral-slot handling. |
| `Bopify/Bopify/Shaders/VinylContours.metal` (new) | Undertow, Drift, Strata. |
| `Bopify/Bopify/Shaders/VinylArtistic.metal` (new) | Bloom, Rhapsody, Carnival. |
| `Bopify/Bopify/Views/VinylPressingView.swift` | Style-aware rendering dispatch and appearance identity. Preserve Original/tint/nil branches. |
| `Bopify/Bopify/Views/VinylRecordView.swift` | Style input and crossfade identity; retain existing motor/label transforms. |
| `Bopify/Bopify/Views/RecordPlayerView.swift` | Shared preference observation and handoff ownership. |
| `Bopify/Bopify/Views/PlayerPreviews.swift` | Explicit visual fixtures and style previews. |
| `Bopify/Bopify/Views/VinylDesignPicker.swift` (new) | Static representative thumbnails and accessible selection UI. |
| `Bopify/Bopify/MenuBar/VinylDesignWindowController.swift` (new) | One reusable native chooser window. |
| `Bopify/Bopify/MenuBar/StatusItemController.swift` | Menu entry and controller ownership. |
| `Bopify/Bopify/Localizable.xcstrings` | English source strings using the existing catalog convention. |
| `Bopify/BopifyAppTests/VinylDesignTests.swift` (new) | Catalog/palette behavior. |
| `Bopify/BopifyAppTests/VinylRenderingFixture.swift` (new) | Reusable real-window capture and annulus sampling, shared by rendering/integration tests. |
| `Bopify/BopifyAppTests/VinylRenderingTests.swift` (new) | Shader availability and native visual invariants. |
| `Bopify/BopifyAppTests/RecordContinuityTests.swift` | Style/cover/rotation lifecycle regressions. |
| `Bopify/BopifyAppTests/VinylDesignPickerTests.swift` (new) | Chooser persistence, selected state, and window behavior. |

Xcode uses synchronized source folders for app and app-test targets. Add files in these directories; do not hand-edit `project.pbxproj` unless a real target-membership failure demonstrates the need. No `AppEnvironment` or package/FFI changes are planned.

## Verification commands and prerequisites

Commands below are intended results, not checks already run. Run from the chosen execution worktree. Verify Xcode/Metal are available and `artifacts/BopifyCoreFFI.xcframework` exists; if the artifact is absent, use the existing `./scripts/build-rust.sh` before Swift/Xcode checks. If a CLI is missing, retry with `,` rather than installing global tools.

Use this native test command, replacing `SUITE` with the exact suite type named in each task:

```sh
xcodebuild -project Bopify/Bopify.xcodeproj -scheme BopifyAppTests -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/bopify-vinyl-tests CODE_SIGNING_ALLOWED=NO -only-testing:BopifyAppTests/SUITE test
```

Real GPU captures follow the existing `PlaybackFeedbackTests` precedent: host in an actual `NSWindow` and run `/usr/sbin/screencapture -x -l WINDOW_NUMBER OUTPUT.png` while the window is visible. Check `CGPreflightScreenCaptureAccess()` and the command's exit status. Cached AppKit bitmap rendering is not a substitute for shader captures. If desktop lock/permission prevents capture, report that condition and do not claim visual acceptance from shader-function existence alone. Do not change system accessibility/motion preferences without authorization; use view-level motion overrides where supported.

### Task 1: Stable catalog and cover palette policy

**Files:** Create `Views/VinylDesign.swift`, `Views/VinylDesignPalette.swift`, and `BopifyAppTests/VinylDesignTests.swift` at the paths mapped above.

**Interfaces:**
- `enum VinylDesign: String, CaseIterable, Sendable` with the seven ordered cases, `static let preferenceKey = "player.vinylDesign"`, `static func resolve(_ rawValue: String?) -> VinylDesign`, and `var nameKey: String` returning `vinyl.design.<rawValue>`.
- `struct VinylDesignPalette: Equatable, Sendable` with `let primary, secondary, accent, paper: ArtworkColor` and `static func resolve(_ source: ArtworkPalette, design: VinylDesign) -> VinylDesignPalette?`.
- Palette resolution returns nil for `.tinted`/`.neutral`; for `.marble`, `paper` is the original third slot, the first four designs retain all raw slots, and the final three convert chromatic slots only. Classify a slot as achromatic when max-minus-min RGB is at most `1e-6`; preserve that slot's original channels. Hue/finite-value tolerances in tests must accommodate floating-point conversion.

- [ ] **Step 1: Add failing catalog and palette tests.** Include `stableIDsAndFallback`, `tintedPalettesBypassDesignColors` parameterized across all cases, `originalAndContoursPreserveExtractedColors`, `artisticColorsPreserveHueAndExpandSaturation`, `neutralSlotsStayNeutral`, and `repeatedSlotsRemainFiniteAndRelated`. Pin the order and resolver assertions:

```swift
#expect(VinylDesign.allCases.map(\.rawValue) == ["original", "undertow", "drift", "strata", "bloom", "rhapsody", "carnival"])
#expect(VinylDesign.resolve(nil) == .original)
#expect(VinylDesign.resolve("removed-style") == .original)
#expect(VinylDesign.resolve("bloom") == .bloom)
```

Use the approved warm palette `(0.9333,0.5098,0.4510)`, `(0.7255,0.8392,0.7608)`, `(0.9569,0.8745,0.6078)`, plus exact gray/white and a repeated saturated red. Assert chromatic output follows the specified HSL bounds; Original is equal to its input; gray/white keep equal RGB channels; all output channels stay finite in `0...1`.
- [ ] **Step 2: Run `VinylDesignTests` and observe failure because the new types do not exist.** Distinguish a toolchain/artifact failure from the intended test failure.
- [ ] **Step 3: Implement the two value types.** Keep classification in the existing artwork pipeline; do not modify `ArtworkPalette.classify` or introduce a new color library.
- [ ] **Step 4: Rerun `VinylDesignTests`.** Expected: all catalog/palette assertions pass.
- [ ] **Step 5: Commit only these files:** `feat: define vinyl designs and cover color policy`.

### Task 2: Native contour designs and baseline capture

**Files:** Create `Shaders/VinylContours.metal`, `BopifyAppTests/VinylRenderingFixture.swift`, and `BopifyAppTests/VinylRenderingTests.swift`; modify `Views/VinylPressingView.swift`.

**Consumes:** Task 1 catalog/palette types and existing `PressingSeed`, `ArtworkPalette`, and bundle lookup in `VinylPressingView`.

**Produces:**
- `VinylPressingView` gains `var design: VinylDesign = .original`; preserve all old initializer call sites using the default.
- Metal function `vinylContours(float2 position, half4 color, float2 size, float seed, half4 c0, half4 c1, half4 c2, float style) -> half4`; style values 0/1/2 mean Undertow/Drift/Strata. ShaderLibrary arguments after implicit position/color use exactly this order.
- `@MainActor enum VinylRenderingFixture` with `static func capture<Content: View>(_ content: Content, size: CGSize, to url: URL) async throws -> NSBitmapImageRep` and `static func differingAnnulusFraction(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Double`. Compare normalized radii `0.5...0.95`, beyond the label, using RGB channel difference over `8/255` to mark a changed pixel. Put capture artifacts under `/tmp/bopify-vinyl-validation/`.

- [ ] **Step 1: Add the native capture fixture and record pre-change Original/muted baselines.** Use existing `VinylPressingView(seed: 42, palette: ..., diameter: 182)` before changing rendering dispatch. Capture warm/cool `.marble` palettes and `.tinted` gray, retain baselines outside git, and ensure they contain the actual visible GPU layer.
- [ ] **Step 2: Add failing `contourFunctionIsAvailable`, `contourStylesRenderDistinctly`, `contoursFollowCoverColors`, and `allDesignsKeepTheMutedBaseline` tests.** Require the Metal function from the test resource bundle; for the three contours require pairwise changed-annulus fraction above 0.10 at diameter 182; compare warm/cool output for a fixed style/seed; compare muted outputs with a same-run Original/tinted reference. Supply the same window/background/scale for all comparisons. Add `defaultDesignMatchesExplicitOriginal` to preserve old initializer behavior. Saved pre-change captures are manual compatibility evidence only; permanent tests must not depend on pre-existing files under /tmp.
- [ ] **Step 3: Run `VinylRenderingTests`.** Expected: missing-function/style-dispatch failures, with baseline captures available. Permission-based skips must be listed separately.
- [ ] **Step 4: Implement contour rendering and Swift dispatch.** Use the spec's field/polar equations with fixed-cost analytic contour masks and derivative-based antialiasing. Normalize positions; seed only small translation/orientation offsets. Keep the existing `pressing` shader and the `.tinted`/nil rendering branches intact. Until Task 3, the unimplemented three artistic cases may explicitly route to Original; they are not yet exposed in product UI.
- [ ] **Step 5: Rerun the suite and visually inspect normal/compact captures at diameters 182 and 118, including available Retina backing.** Expected: distinct reference-matching contour families, unchanged Original and muted captures, no opaque rectangular margins or subpixel sparkle. Use at least the warm palette and a cool pink/cyan/pale palette.
- [ ] **Step 6: Commit the contour renderer and reusable regression coverage:** `feat: add cover-colored contour vinyl designs`.

### Task 3: Colorful Bloom, Rhapsody, and Carnival

**Files:** Create `Shaders/VinylArtistic.metal`; modify `Views/VinylPressingView.swift`, `Views/PlayerPreviews.swift`, and `BopifyAppTests/VinylRenderingTests.swift`.

**Consumes:** Task 1 vivid palette and Task 2 native fixture/dispatch boundary.

**Produces:** Three stitchable functions, `vinylBloom`, `vinylRhapsody`, `vinylCarnival`, each returning `half4` and taking `(float2 position, half4 color, float2 size, float seed, half4 c0, half4 c1, half4 c2, half4 paper)` in that order. Map the resolved palette's four colors to these arguments. All seven `VinylPressingView` cases now have their intended final rendering.

- [ ] **Step 1: Add failing `artisticFunctionsAreAvailable`, `artisticStylesRenderDistinctly`, `artisticStylesFollowCoverHues`, `artisticStylesFillMostOfTheAnnulusWithColor`, and `sameSeedAndPaletteRenderStably` tests.** Check shader names, pairwise changed-annulus fraction over 0.10, warm/cool differences, and stable repeated capture within the same-device channel tolerance. For each artistic style require more than half the sampled annulus to have RGB chroma (max-minus-min channel) above 0.15. Extend the unchanged muted-baseline test to all seven designs. This catches the rejected sparse-colored-lines-on-black direction.
- [ ] **Step 2: Run `VinylRenderingTests`.** Expected: artistic-function/appearance assertions fail while earlier contour coverage remains passing.
- [ ] **Step 3: Implement the three functions from the spec's accepted geometry.** Bloom uses layered filled petals plus a fixed small curve set. Rhapsody evaluates the warped field per pixel and uses a local deterministic grain hash near seams, not the browser's 13,000-particle loop. Carnival uses the four fixed split-disc groups and a bounded number of hatches/marks. Preserve large colored areas, source hues, and the center label boundary; use original paper color for pale accents.
- [ ] **Step 4: Add DEBUG previews using all seven styles and both representative colorful palettes.** Use the shared native renderer and fixed seed; keep these fixtures explicit rather than adding new player behavior.
- [ ] **Step 5: Rerun native rendering tests, inspect captures against the approved Bloom/Rhapsody/Carnival compositions, and repeat compact-size captures.** Expected: colorful, recognizable families and stable antialiasing. Save annotated comparison evidence outside the repo; do not treat numeric coverage as a substitute for visual review.
- [ ] **Step 6: Commit:** `feat: add vivid artistic vinyl designs`.

### Task 4: Global selection and record continuity

**Files:** Modify `Views/VinylPressingView.swift`, `Views/VinylRecordView.swift`, `Views/RecordPlayerView.swift`, `Views/PlayerPreviews.swift`, and `BopifyAppTests/RecordContinuityTests.swift`.

**Consumes:** Catalog preference key, native renderer with `design`, existing artwork request fences and outgoing-record snapshot.

**Produces:**
- `PressingAppearance` gains `var design: VinylDesign = .original`, included in its synthesized Hashable identity. Existing `.neutral` stays compatible.
- `VinylRecordView` gains `var design: VinylDesign = .original` and passes it to the pressing and its appearance/crossfade identity.
- `RecordPlayerView` reads `@AppStorage(VinylDesign.preferenceKey) private var designRawValue = VinylDesign.original.rawValue`; computed `selectedDesign` resolves invalid strings. Add `@State private var handoffDesign: VinylDesign?` and `private func applySelectedDesign()`.
- `applySelectedDesign()` returns while `coverLaunch != nil`; otherwise it changes only `displayedPressing.design` to the latest selection. It neither reloads artwork nor resets motor/rotation.
- Capture `handoffDesign` when an accepted animated load begins; resolve a loaded incoming pressing with `handoffDesign ?? selectedDesign`. Keep the captured outgoing appearance. `finishCoverLoad()` clears the handoff and then applies the latest saved choice. Existing cancellation/session-reset paths continue releasing artwork.

- [ ] **Step 1: Add failing continuity tests using isolated UserDefaults suites and existing player/cover-load fixtures.** Name cases `globalStyleUpdatesWithoutChangingLabelOrMotor`, `mutedThenColorfulRestoresSavedStyle`, `latestStyleWaitsForCoverHandoff`, `replacingOrCancelingLoadKeepsCapturedStyle`, and `sessionResetReleasesArtworkButRetainsDesign`. Change the preference through Bloom→Drift→Carnival during an active load; capture the existing records before completion and assert only Carnival reaches the settled record. Include actual label samples/record-region comparisons rather than testing only a duplicate state model.
- [ ] **Step 2: Run `RecordContinuityTests`.** Expected: assertions fail because the player does not yet observe the preference/carry design identity. Keep the existing label phase/scale regressions passing.
- [ ] **Step 3: Wire the style through every pressing call site and snapshot.** Include outgoing record, settled face, previews, and appearance identity. Observe the raw preference independently of artwork requests. Initial/session-reset loading resolves from the current global preference. Do not add design to the artwork request identity or refetch a cover on selection.
- [ ] **Step 4: Implement capture/defer/apply behavior at existing load-start and `finishCoverLoad()` boundaries.** Handle replacement loads with the latest selection for the replacement, while retaining the previous snapshot correctly. On errors/hide/reduced motion, use existing finish/cancel paths and settle the latest choice. Preserve the existing 0.65-second appearance crossfade and 0.16-second Reduced Motion opacity treatment.
- [ ] **Step 5: Run `RecordContinuityTests`, `PlaybackFeedbackTests`, and `VinylRenderingTests`.** Expected: new style/transition tests and existing motor/label tests pass; switching styles leaves the cover label/angle and playback state intact. Inspect an actual rotating window for discontinuities and update-while-hidden behavior.
- [ ] **Step 6: Commit:** `feat: persist vinyl style across songs and transitions`.

### Task 5: Native visual chooser and status-menu entry

**Files:** Create `Views/VinylDesignPicker.swift`, `MenuBar/VinylDesignWindowController.swift`, and `BopifyAppTests/VinylDesignPickerTests.swift`; modify `MenuBar/StatusItemController.swift` and `Localizable.xcstrings`.

**Consumes:** Catalog, shared preference key, and fully implemented `VinylPressingView`.

**Produces:**
- `struct VinylDesignPicker: View`, using the same AppStorage string/resolver as the player, with Original first and a three-column/two-row grid for the six designs. Use `VinylPressingView` thumbnails at fixed seed 42 and the Task 1 warm sample palette; no clocks or artwork requests.
- `@MainActor final class VinylDesignWindowController` with `init(defaults: UserDefaults = .standard)`, `func show()`, and `func close()`. Reuse one retained native `NSWindow`, identifier `vinyl-design`, wrapping the picker in `.defaultAppStorage(defaults)`. Follow the existing `KeyboardShortcutsWindowController` auxiliary-window conventions.
- `StatusItemController` owns the chooser controller and adds `@objc private func showVinylDesign(_ sender: Any?)`; put **Vinyl Design…** immediately after Artwork Background in `showMenu()`.
- Localization keys: `vinyl.title` = `Vinyl Design`, `menu.vinylDesign` = `Vinyl Design…`, `vinyl.paletteHelp` = `Colors adapt to each cover. Previews use a sample palette.`, `vinyl.mutedHelp` = `Muted covers keep a subtle tint.`, and the seven `vinyl.design.<id>` values from the catalog. Add any accessibility copy through the same catalog, not hard-coded view strings.

- [ ] **Step 1: Add failing `windowReopensAsOneInstance`, `selectionIsImmediateAndPersistsAcrossWindowRecreation`, `invalidPreferenceSelectsOriginal`, `thumbnailsStayDistinctWithoutArtwork`, and `keyboardAndAccessibilityExposeSelectedDesign` tests.** Use isolated defaults; mount the real picker/window; activate a choice through its actual control; assert preference and selected accessibility state agree, only one selection exists, closing does not revert it, and reopening/recreating reads the same ID. Verify labels/selection with accessibility and standard activation rather than testing SwiftUI's storage implementation in isolation.
- [ ] **Step 2: Run `VinylDesignPickerTests`.** Expected: missing-window/view/control failures before implementation.
- [ ] **Step 3: Build the picker and reusable window.** Immediate selection keeps the window open, Escape/close dismisses, normal keyboard traversal and activation work, and each thumbnail has an accessible name/selected state. Do not add a separate Apply/Cancel state or expose hover as a saved choice.
- [ ] **Step 4: Add menu wiring, localized copy, and a selection diagnostic.** Log only the stable style ID, once per genuine user selection, using the existing playback logger; keep pure palette/rendering logic free of logging. The chooser is available when no song/cover is loaded; a sign-out does not clear the preference.
- [ ] **Step 5: Run picker tests and manually verify the real status menu opens the window.** Verify live global updates with a colorful song, then a muted one, sign-out/relaunch retention, keyboard focus, selection contrast, and a repeated menu activation reusing the same window. Confirm no playback command is sent by chooser selection.
- [ ] **Step 6: Commit:** `feat: let users choose a vinyl design visually`.

## Final integration and acceptance

- [ ] Run `swift test --package-path Packages/BopifyCore` and `./scripts/test-native.sh` (project-required Rust/Clippy/locked dependency checks); no Rust source changes are intended.
- [ ] Run the full native suite, dropping `-only-testing` from the shared `xcodebuild` command. Expected: zero failing tests; enumerate any conditional capture skips explicitly.
- [ ] Build the app with `xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/bopify-vinyl-release ARCHS=arm64 CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build` and run `codesign --verify --deep --strict /tmp/bopify-vinyl-release/Build/Products/Release/Bopify.app`. Expected: successful build and signature verification. No DMG, publication, or dependency update is required.
- [ ] Capture the actual chooser and seven record designs at normal/compact sizes, two cover palettes, and muted/no-artwork conditions. Compare Original with pre-change captures and artistic styles with the approved compositions. Check label, rim, dust, rotation, scrubbing, Reduce Motion, and selected-cover handoff in motion.
- [ ] Measure optimized native Original versus each new style on the same machine/backing scale, at rest, steady rotation, hidden, and during repeated handoff. Use a standalone visible native rendering workload or the built app; record duration, CPU/GPU observations, and whether background work stops when hidden. Do not use XCTest process CPU as a shipping performance claim. Investigate material regressions before completion.
- [ ] Remove any task-created temporary probes/harnesses; retain reusable native regression fixtures. Keep evidence under `/tmp/bopify-vinyl-validation/`, not the source tree. Rerun affected checks after cleanup.
- [ ] Review `git diff --check`, changed-file scope, selected IDs/localization, and the full diff against the spec. Obtain a fresh whole-branch code review and resolve findings. Update plan checkboxes and record actual validation/remaining limits; do not imply planning checks establish implementation success.

## Execution handoff

Plan execution has not started. Recommend **Native** execution: these five tasks share the renderer, palette, and appearance identity, so keeping implementation in one session reduces interface handoffs; one fresh whole-branch reviewer can check the completed integration. **Subagent-driven** execution remains available if the user prefers independent implementation/review gates per task. Review this plan and select the execution method before modifying product code.
