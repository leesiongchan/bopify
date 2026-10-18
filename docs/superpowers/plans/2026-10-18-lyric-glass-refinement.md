# Lyric glass refinement implementation plan

> Execute inline using the approved design and native app verification.

**Goal:** Keep the compact three-row ribbon, with a full overlapping record, tinted native glass, balanced lyric spacing, and reachable passive dragging.

**Architecture:** Reuse the main player's drag region and screen clamping. Use native SwiftUI glass and spring animation; retain the existing TextKit reader and seeking boundary.

**Constraints:** Preserve passive focus, selection, timed seeking, reduced motion/transparency, and the 448 × 156 normal footprint. No new dependencies. Preserve the user's project/catalog edits. Commit and push to main.

1. Add failing native glyph-spacing and border-drag/drop regressions in `LyricReaderTests.swift` and `LyricRibbonWindowTests.swift`. Run the app tests and inspect failures.
2. Adjust native font baselines in `LyricRibbonLayout.swift`; generalize `PlayerBackgroundDragRegion` with passive-focus and drag callbacks while preserving main-player defaults. Apply whole-surface tinted glass and full front record in `LyricRibbonView.swift`.
3. Add guarded spring-back positioning to `LyricRibbonWindowController.swift`, using the existing clamp and the main player's spring parameters. Check display changes, interruption, hide, and reduced motion.
4. Run Debug/Release app suites and core tests. Capture the actual native view against owned light/dark backdrops, verify optical gaps, border/record dragging, manual Sync and seeking. Remove capture hooks and rebuild.
5. Request independent review, resolve findings, update research/validation evidence, commit only task files and push to main.
