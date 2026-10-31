# Selectable vinyl designs

Status: proposed design, awaiting user approval. Implementation is not authorized by this document alone.

## Intent and agreed direction

Let users choose the artwork surrounding a record's cover label. The choice applies globally across songs; each song supplies its own cover palette. Muted covers bypass every decorative design and retain the existing subtly tinted record. The saved choice returns when a colorful cover plays.

The user chose native mathematically generated patterns over recolorable artwork templates. The nine-record photograph is inspiration, not a catalog to reproduce. After the initial contour studies, the user requested three additional, more creative designs, then asked for stronger color and artistry. They accepted the revised Bloom, Rhapsody, and Carnival studies, including expanded saturation based on the cover's hues.

This is a feature spanning rendering, preference state, and a small native chooser, rather than a single shader edit.

## Goals, limits, and failure conditions

- Offer six explored designs with recognizable, distinct compositions and immediate visual selection.
- Preserve cover-driven colors, center artwork, existing rotation, scrubbing, cover loading, and outgoing-record continuity.
- Keep appearance stable for a song rather than randomizing on redraw. Persist the global choice across relaunches.
- Preserve muted classification and tint rendering exactly; no decorative pattern or forced vivid hue on a muted record.
- Keep the existing appearance available and preserve it as the default for existing and new installations (author's proposed compatibility choice).
- Do not add audio-reactive effects, per-album overrides, manual color controls, an asset download service, dependencies, Rust changes, or a general settings redesign.
- Failure includes restoring the rejected thin, mostly black treatment for the three new designs; recoloring the center cover; shimmer from tiny lines; resetting rotation on style changes; or losing the saved style on muted covers.

## Approaches

1. **Native generated patterns — selected by the user.** Extend the existing SwiftUI/Metal pressing renderer. This reuses cover extraction and record transforms, scales to different diameters, and allows direct palette application. It requires translating the browser compositions into native drawing/shader calculations.
2. **Recolorable templates — not selected.** Fixed multilayer illustrations give direct compositional control but require more assets for variation and a separate recoloring path.

The browser canvases were throwaway visual studies, not production architecture. The native implementation must reproduce their visual character without copying their expensive full-canvas CPU loops into the application.

## Catalog and visual rules

Stable persistence identifiers and order are proposed as follows; displayed names are localized.

| Identifier | Name | Composition |
| --- | --- | --- |
| `original` | Original | Current marble shader for colorful artwork and current tint for muted artwork. Unmodified default. |
| `undertow` | Undertow | Dense, warped contours on a dark ground, with alternating fine color lines and occasional broader pale ribbons. |
| `drift` | Drift | Broad irregular nested ribbons centered around the label, with dark gaps and finer contrasting accent lines. |
| `strata` | Strata | Interlocking filled contour regions with narrow contrasting outlines. |
| `bloom` | Bloom | Full-surface floral color layers with sevenfold petal geometry, fine interwoven curves, and small rim details. |
| `rhapsody` | Rhapsody | Warped standing-wave fields rendered as vivid flowing color pools, with narrow dark seams and pale grains. |
| `carnival` | Carnival | Four offset groups of split circular bands, bold color blocks, short hatches, and scattered small graphic marks. |

The first three preserve the initial accepted contour direction. Bloom, Rhapsody, and Carnival use the final, more colorful accepted revision, not the earlier Filigree/Resonance studies.

Normalize geometry to the disc so composition survives scaling. Use screen-space antialiasing and reduce subpixel detail as necessary at the actual compact size. Fine accents must remain secondary to large shapes. Retain the existing center label ratio (normally 0.43), label treatment, spindle, clipping, rim, dust, and existing transformations.

### Reconstructing the accepted geometry

These equations describe the studies without making the ignored browser-session files a build dependency. Constants may be tuned by the builder for antialiasing and visual fidelity; changing the recognizable composition is not a routine tuning decision.

- **Undertow/Strata:** in coordinates `x,y` spanning approximately `[-1.4,1.4]`, define `u=x+0.34 sin(3.3y+sin(1.8x))+0.13 sin(6.1y+2x)` and `v=y+0.30 sin(3.2x-0.6y)+0.13 cos(5.4x+3.1y)`. The field is `F=0.60 sin(3.9u+1.4v)+0.49 cos(3.4v-0.9u)+0.18 sin(7u+4.2v)`. Undertow uses about 34 contour levels spaced 0.076 apart from -1.25; every seventh line is broader. Strata uses broad discrete color regions from this field and narrow contrasting boundaries.
- **Drift:** use nested polar curves. The study used radii `b+28 sin(3a+0.008b)+20 sin(5a-0.006b)+10 sin(9a+0.004b)` at nine base radii from 146 in steps of 35 on a 720-unit canvas. Stroke broad color ribbons with a pale interior and dark core, plus fine offset accents. Scale all units to the native disc.
- **Bloom:** sevenfold layers use `r=b+A cos(7a+phase)+7 sin(3a+0.8)` on the same 720-unit canvas. Layer `(b,A,phase)` values are `(346,13,0.3)`, `(319,25,0.45)`, `(285,35,0.8)`, `(250,36,1.1)`, `(220,31,1.6)`, and `(192,23,1.9)`. Add 18 finer phase-shifted curves near base radius 260/amplitude 69, plus sparse contrasting rim dots. Use large filled color areas, not lace on black.
- **Rhapsody:** in disc-radius coordinates, warp `u=x+0.12 sin(4.3y)`, `v=y+0.09 sin(5.1x)`. Compute `F=cos(3πu)cos(4πv)-cos(4πu)cos(3πv)`. Cycle the three expressive colors with `t=3(0.5+0.5 sin(2.2F+0.6u-0.3v))`, with narrow dark seams near `F=0` and sparse pale grains nearby. This is an artistic field, not a circular-plate physics simulation or audio analysis.
- **Carnival:** compose four groups of six nested split discs near `(100,115)`, `(592,147)`, `(128,595)`, and `(585,588)` with outer radii 270, 218, 230, and 269 on the 720-unit canvas. Rotate the combined composition by about `-π/7`, alternate the colors on opposite halves, and add short hatches and a sparse diagonal cluster of small marks. Broad colors dominate; dark areas act as accents.

Use the existing URI-based `PressingSeed` for small deterministic offsets/orientations while preserving these compositions. Seed changes must not change the chosen style or produce a totally different visual family. No time-based evolution is added; the existing record rotation supplies movement.

## Palette and fallback

Continue using `ArtworkStore.loadPalette`, `ArtworkPalette.classify`, and their existing caches and session fencing. The decision to show a pattern occurs before any vivid-color conversion.

- `.tinted` and `.neutral`: existing tint path, irrespective of saved design.
- `.marble` plus Original: existing marble shader and unmodified palette.
- `.marble` plus Undertow/Drift/Strata: extracted cover colors with their original contour treatment.
- `.marble` plus Bloom/Rhapsody/Carnival: preserve each chromatic color's hue and expand saturation/tonal contrast as in the accepted revision. The study used HSL saturation at least 0.78 and lightness `clamp(0.76L,0.45,0.62)`, with original lighter cover colors available for pale accents. Dark ink is permitted for contrast. Apply this only to the surrounding pressing.

Handle genuinely achromatic palette slots as neutral ink/paper accents rather than giving zero-saturation colors an arbitrary red hue. Repeated slots from sparse palettes remain related colors; tonal variation may improve separation but must not invent unrelated hues. The builder should settle small numeric tolerances and color-space handling, keeping results finite and in gamut.

Missing or failed cover extraction uses the existing neutral record. Preserve last-confirmed artwork/appearance while a new request resolves; keep the existing cancellation and session-reset behavior.

## Choosing and saving a design

**Author's proposed UI:** add **Vinyl Design…** next to Artwork Background in the existing status-item menu. Open one small, reusable native window using the existing auxiliary-window conventions. No new permanent player toolbar control.

The window presents Original as a compact first option, then the six artistic styles in a three-column, two-row grid with circular thumbnails, names, and an unmistakable selected state. Thumbnails use the same native renderer, not separate illustrations. Use a fixed representative cover palette and seed for all chooser thumbnails; explain that the colors adapt to the playing cover. This deliberate preview choice keeps patterns distinguishable while the playing cover is muted or absent and avoids additional artwork requests.

Selecting an option applies and saves it immediately; there is no Apply/Cancel transaction. The window remains open for comparison and has normal close/Escape dismissal. Reopening focuses the existing window. Choosing a style must not change playback, queue position, rotation angle, or artwork. Closing does not revert a selection.

Use one app-wide UserDefaults preference, proposed key `player.vinylDesign`, with stable string IDs. Missing/unknown IDs resolve to Original. Do not persist indices or localized names. Treat this as a device-local visual preference like Artwork Background; it survives sign-out. No account/cloud synchronization.

Provide accessible names and selected state, keyboard focus, standard activation, and a predictable grid traversal. Localize menu text, title, design names, and the short palette explanation through the existing localization system. Native window sizing, spacing, focus implementation, and layout tuning are builder decisions.

## Native integration and transitions

Keep the preference definition and style catalog simple; no plugin registry or extensibility framework. `VinylPressingView` remains the rendering boundary and dispatches Original or one of the six generated styles. Share palette conversion and normalized geometry helpers where they remove real duplication. Use fixed shader work rather than unbounded per-frame CPU construction or thousands of particle iterations per fragment.

Include design identity in `PressingAppearance` alongside the seed and palette. Carry it through `RecordPlayerView`, `VinylRecordView`, previews, and outgoing snapshots. Every visible pressing honors the saved global choice; snapshot the resolved appearance when a record becomes outgoing so a later change does not mutate its already-captured geometry unexpectedly.

For an ordinary style change, crossfade the current pressing at its current rotation using the existing short appearance transition, without rebuilding the motor or center label. During an active cover-loading handoff, preserve captured outgoing/incoming appearances until that handoff completes, then apply the latest saved choice to the settled record. Repeated selections settle on the latest preference without queued animations. Reduced Motion uses the existing short opacity treatment; no extra rotation or travel.

The chooser thumbnails are static. Hidden views do not gain animation clocks. Pattern generation has no audio, network, file, or session side effects. Follow existing logging conventions for a style selection using only its stable identifier; do not log covers or track identifiers.

## Verification and acceptance

- Cover stable-ID persistence, default/invalid-value fallback, global propagation, and retention through muted covers and sign-out.
- Keep existing classification tests. Verify `.tinted` bypasses all decorative shaders, Original remains visually unchanged, and vivid conversion handles neutral/repeated slots without NaNs or unrelated hues.
- Validate all seven native shader/rendering paths with actual Metal-backed window captures. Compare six native designs against the accepted compositions at normal, compact, and Retina scales with at least two colorful palettes and one muted palette. Browser mockups alone do not establish native fidelity.
- Exercise the chooser with pointer and keyboard: immediate updates, selected state, relaunch persistence, single-window reuse, close/Escape behavior, and no playback side effects. Inspect accessible names and selection state.
- Exercise next/previous, pause/resume, scrubbing, cover handoffs, selection during loading, reduced motion, missing artwork, late palettes, and session reset. Preserve outgoing artwork and rotational continuity.
- Measure comparable native Original/new-design workloads during steady rotation and handoff. Investigate material regressions and excessive GPU work before calling the feature complete; reuse the repository's demonstrated native measurement approach rather than attributing XCTest process CPU to shipping rendering cost.
- Run relevant package/app suites, project-required formatting/checks, native shader compilation, signed app build and signature checks. Record actual results and any unverified desktop-dependent behavior.

## Evidence and remaining builder choices

Browser studies were checked for distinct patterns, palette switching, rotation controls, and identical muted fallbacks. This verifies only the throwaway studies. No product code has been changed.

The accepted reference studies currently live in the ignored `.superpowers/brainstorm/9484-1793431098/content/` directory: `vinyl-contours.html` and `vinyl-expressive-v2.html`. Their algorithms and appearance requirements are captured above so the design remains usable without that directory.

The author proposes, rather than attributes to the user: Original as the default seventh choice; the status-menu entry and thumbnail window; fixed-palette chooser thumbnails; preference key/IDs; keeping original palette treatment for the first three designs; and deferring style changes through an active handoff. These are reviewable decisions in this document. Exact shader organization, safe color tolerances, small geometry tuning, localization implementation, and meaningful test organization remain with the builder.

Research informing the new compositions:

- [V&A: Guilloché enamelling](https://www.vam.ac.uk/articles/how-was-it-made-guilloch%C3%A9-enamelling) — ornamental interlaced geometry translated into Bloom's layered rosettes.
- [University of Colorado Boulder: Chladni figures](https://physicslabs.colorado.edu/demos/oscillations-and-waves/instruments/resonance-in-plates-bars-solids/chladni-figures/) — standing-wave nodal patterns informing Rhapsody's artistic field.
- [The Met: Sonia Delaunay, Colored Rhythm](https://www.metmuseum.org/art/collection/search/485826) — geometric color and rhythm informing Carnival's original offset-arc composition.

## Approval

Pending user review of this written design. After approval, the next step is the implementation plan, not immediate implementation.
