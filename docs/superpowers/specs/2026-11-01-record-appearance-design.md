# Unified record appearance settings

Status: approved by the user on 2026-11-01, following approval of the final visual study and the request to proceed. Native implementation is authorized; execution and verification evidence is recorded in the implementation plan.

Builder check: a fresh macOS engineering reviewer read this design and the relevant integration context on 2026-11-01 and reported no important unanswered planning questions. The user subsequently approved this written design.

## Intent and scope

Replace the separate Record Design and Vinyl Design choosers with one continuous **Record Appearance…** settings window. Keep the muted-cover material and colorful-cover pattern independently selectable and independently saved. Reproduce the approved sunburst turntable study with two platters, records partially clipped at the window edges, sharp olive corduroy, and a deliberate physical exchange.

The app is native SwiftUI/AppKit with existing Metal record rendering. This work changes the chooser and its menu integration. It does not redesign the main player, alter artwork classification, add new record materials/patterns, change playback, or add Rust/network dependencies.

## Approach

**Native SwiftUI controls and record rendering, with bundled decorative artwork, is the approved implementation approach.** Reuse `VinylPressingView` and `RecordMaterialSheen` for the actual selectable records. Bundle the exact approved turntable and corduroy images; construct moving tonearms, spindle overlays, nameplate, lettering, and controls natively. A small deterministic state machine drives both preview decks.

A WebView could reuse the throwaway page but would introduce a second renderer and a JavaScript/native settings bridge. Rebuilding the approved photographic wood and textile entirely with procedural drawing would introduce unnecessary visual uncertainty. Neither provides a useful benefit for this native settings feature. The browser code remains a reference, not shipped runtime code.

The original separate choosers/controllers/models become obsolete once the combined window and their test coverage are replaced. Remove those consumers as part of the change; retain the existing catalogs, preference resolvers, and player continuity logic.

## Preserved preferences and main-player behavior

- Muted covers: `RecordDesign`, key `player.recordDesign`, IDs `classic`, `glass`, `nacre`; names Classic, Glass, Nacre.
- Colorful covers: `VinylDesign`, key `player.vinylDesign`, IDs `original`, `undertow`, `strata`, `bloom`, `rhapsody`, `carnival`; names Marble, Undertow, Strata, Bloom, Rhapsody, Carnival. Keep Marble's `original` ID.
- Preserve all existing saved values and existing fallback behavior: missing/unknown material resolves to Classic; missing/unknown/removed `drift` style resolves to Marble. Do not overwrite a missing or invalid preference merely by opening the window. The study's initial Glass/Bloom choices are illustrative and must not reset existing preferences or replace the product defaults.
- Activating a choice saves immediately through the same UserDefaults keys. Moving focus or hovering does not save. Re-selecting the mounted choice does not start an exchange or emit a duplicate save/log event.
- Close does not revert choices. Selections remain device-local and survive relaunch and sign-out, as they do today.
- Reuse the existing player preference observers and outgoing appearance snapshots. Do not replace the player's appearance-change/handoff policy with the chooser's decorative exchange. Neither preview motion nor its pause control affects actual playback, queue state, seeking, or player rotation.

## Window and controls

Replace the two adjacent status-menu entries with one localized **Record Appearance…** entry, opening one reusable native auxiliary window with identifier `record-appearance`. Preserve normal close, Escape dismissal, activation, dragging by the title/background, and refocusing an already open window.

Use an ideal content size near **900 × 655 pt**, with the demonstrated compact layout near **760 × 631 pt**. Fit within the available screen. At 760 pt there must be no horizontal scrolling or clipped controls. Horizontal resizing between the compact and ideal layouts is a builder choice; do not require a large general-purpose settings shell.

The visible content is:

1. Native window title **Record appearance**.
2. One brief explanation: **Choose a material for muted artwork and a pattern for colorful artwork.**
3. The clipped record/turntable scene.
4. Two labeled option groups, **Material** and **Pattern**. Buttons are in horizontal rows and wrap when necessary. All six colorful options fit in one row at the ideal width and two rows at the compact width, matching the study.
5. A compact footer showing the selected material/pattern and **Pause motion** / **Resume motion**.

Use the existing localization system for menu, title, instructions, group headings, choice names, summary formatting, motion control, and accessibility copy. Do not ship the browser-only preview note, simulated traffic-light circles, motion-stage narration, decorative slogans, or extra marketing text.

Use the native system UI font: title approximately 13 pt, group headings 22 pt semibold with restrained tight tracking, buttons 12 pt, footer 11 pt. Buttons have 32 pt minimum height, 8 pt corners, subtle material/bevel treatment, a clearly distinct selected fill and border, and visible keyboard focus. Preserve readable contrast over the cloth. These ordinary controls do not use the decorative deck fonts.

## Approved visual assets and lettering

The durable review bundle is `docs/superpowers/specs/assets/record-appearance/`. Its images and fonts are the accepted source assets, not placeholders. `approved-preview.png` is the normal-scale visual reference; `materials.json` and `typography.json` retain prompts, origins, and font provenance. The product implementation must bundle its own resources and have no runtime dependency on `.superpowers`, a local server, or the documentation directory.

### Turntable

Use `sunburst-deck.png` (1509 × 1042, transparent outside the body): a true overhead twin-platter interpretation of the MoFi × Fender American Vintage. Preserve the fine alder grain, amber/russet/near-black sunburst, satin lacquer, matte black platter rims, exposed belt/pulley details, black pickguard-style button surrounds, and small metallic fittings. The photographed pulleys are motors, not tonearm mounts; keep the native animated tonearms separately mounted near the top centre.

The two platter records have equal diameter at all times. Their sizes remain constant through hover, extraction, exchange, and docking: no scaling or perspective enlargement. At ideal width their diameter is approximately 228 pt, with the image's black playing surface calibrated as 570 source pixels. Use the same diameter for the edge candidates and both mounted records.

Source-image coordinates for the native geometry are platter centres **(428, 504)** and **(1082, 504)** and tonearm pivots **(635, 165)** and **(874, 165)**. Tonearm length is approximately **0.86 × record diameter**. The left arm plays at +3° and parks at +90°; the right plays at −3° and parks at −90°, measured clockwise from downward. Preserve cartridge, stylus, gimbal, counterweight, arm rest, cue-lever and shadow details; neutral dark hardware with restrained polished highlights, not flat featureless lines.

Below each platter, print the name of the **mounted** record in **Allura Regular**, in title case, warm pale metal/ink colour. Use approximately 24 pt at ideal width and 22 pt at compact width. The lettering's baseline is horizontal: no rotation transform or artificially slanted layout. Update it when the incoming record has mounted, not at the start of the flight. These names are actual localized choice names, not a second catalog.

At the top centre, retain the small black metal **BOPIFY** plate with a fine pale-metal border and two recessed screw heads. Its dimensions are **54 × 18 pt** at ideal width and **48 × 16 pt** at compact width. Use **IBM Plex Sans Condensed Medium**, uppercase, approximately **7 pt** / **6.2 pt**, with restrained tracking and flat silver-grey colour **#cbd0c6**. No text shadow, glow, embossing, or script font on the plate. The exact font files and OFL licenses are included. Register the bundled fonts process-locally before presenting the window; do not install fonts into the user's system. Keep the plate clear of both tonearm bases at compact width.

### Corduroy

Use `corduroy-crisp.png` (1254 × 1254) at two source pixels per point: a **592.5 × 627 pt** native tile at Retina scale, cropped at source x=33…1217 dark-furrow centres. Render it in a viewport-sized Canvas with nearest sampling and alternating mirrored edges, anchored at the leading edge below the 38-pt title region. This preserves the approved cotton pile, raised ribs and recessed woven channels without fractional 1254→1250 pixel resampling or mismatched repeated edges. The canvas has no intrinsic image-stack width, so it cannot expand/recenter the background. Apply the existing subtle dark tint for UI contrast. Preserve readable fallback colour if the image is unavailable.

The user requested removal of the visible centre join and softness on 2026-11-05. The original study’s repeated 625-pt tiles are superseded by this native sampling correction; the source bitmap remains unchanged.

### Records

Use the actual native material/pattern renderer with a fixed representative sample label, palette and deterministic seed, so choices remain distinguishable even when playback is muted, absent, or signed out. Reuse the existing muted/colorful chooser palette and a 0.43 label ratio; there is no artwork/network fetch in this window. Match the study's simple sample-label character without copying its JavaScript pixel renderer.

Material records appear on the left, colorful records on the right. At rest each candidate's centre lies exactly on its respective scene boundary, showing **half the record**. Distribute the choices vertically in stable catalog order; the mounted record occupies its platter and is absent from its edge slot. Preserve gaps between the edge records and the deck body. Clip to the scene/window, not the circular platter. Hover or focus slides an edge record inward by at most 8 pt and reverses on exit/blur. Use a fixed layer order derived from family/catalog identity: hovering, clicking and mounting do not raise a record above its peers.

## Exchange and motor behavior

Use independent per-family mounted/desired/incoming/outgoing state. The selected preference updates immediately, while the physical preview catches up. Simultaneous changes to the two families are allowed; a change to one family must not reset the other motor.

The accepted single exchange is approximately **1.84 seconds** (observed browser result about 1.86 seconds):

| Stage | Duration | Behavior |
| --- | --- | --- |
| Prepare | 0.46 s | Needle lifts over 0.14 s, then the arm parks over 0.26 s. Motor decelerates over 0.38 s. In parallel, the incoming candidate spins approximately 55° and slides fully inside the window. |
| Swap | 0.86 s | After the needle has cleared, old and new records exchange simultaneously along direct straight paths. Incoming completes approximately 180° total travel rotation and docks; outgoing returns to its own edge slot. |
| Settle | 0.08 s | Record is seated; mounted-name lettering updates. The arm remains parked. |
| Restore | 0.28 s | Arm returns to its play angle while the needle stays raised. |
| Lower | 0.16 s | Needle lowers, then the motor resumes its gentle cruise. |

Use quintic smootherstep `6t^5 − 15t^4 + 10t^3` for travel/arm positioning, with eased lift/lower and motor changes. Add only a small continuous lift/shadow change through the swap, not a curved sideways detour, scaling, sudden shadow switch, spring bounce or overshoot. Records must not cut through either parked tonearm/cartridge. The study's measured upper-row moving-record clearance was over 11 pt; verify full native silhouettes rather than relying only on a mathematical arm segment.

Both settled records cruise at **45 degrees per second**, not 45 RPM. Their speeds are equal. Preserve their angles continuously rather than restarting rotation when SwiftUI recomputes a view. The final frame of lowering must schedule the motor restart: the study previously exposed a stopped-clock bug here, which was corrected.

While a family is exchanging, new activations replace its desired choice. Coalesce to the latest value without an unbounded queue; finish an already crossing pair safely, then exchange again only if necessary. If a pending preparation is cancelled by returning to the already mounted choice, return the candidate safely before lowering the arm. At every settled point there is one mounted record per platter and each remaining record is in its correct edge slot. Names, buttons, and persisted selection agree with the final desired value.

The motion button controls preview motor rotation only; choosing another record still works while paused. It never controls audio. Reduce Motion overrides the preview motor and exchange: settle directly to the latest saved records, with no travel, arm sweep, or ongoing spin. Reflect the effective motion state accessibly. Reduced Transparency uses the existing Glass opaque fallback and sufficiently opaque readable controls while retaining the selected material. Increased Contrast must preserve labels, selected states and focus visibility.

Stop continuous work when the window is hidden, closed or fully occluded. Closing or resizing during an exchange invalidates stale animation work and settles to the latest saved preferences. Reopening restores those preferences in a stable mounted state, without replaying a stale flight. Hovering/focusing does not wake permanent clocks once its transition settles. Reuse the existing schedule/lifecycle conventions where appropriate; do not create one independent timer per record.

## Keyboard and accessibility

Expose the two option groups as native accessible controls with localized names and one selected item in each group. The clipped record art is a pointer shortcut to the same choices; avoid duplicate keyboard/VoiceOver controls for every decorative record. Keep the mounted sample labels and nameplate decorative to prevent repetitive announcements.

Tab/Shift-Tab moves between choices in material-then-pattern order and the motion control. Left/Right and Home/End navigate within a family without saving; Up/Down moves between families and clamps the index to the available count. Enter/Space activates the focused choice. Escape closes the window. Focus must be visible and synchronized between native keyboard routing and SwiftUI focus; do not intercept modified shortcuts or steal keys from unrelated windows. Automatic wrapping must not scramble the logical catalog traversal.

## Acceptance and verification

- Deterministic tests cover both existing preference keys/IDs, fallback values, independent changes, no writes on hover/focus/open, immediate activation, same-choice no-op, and recreation/sign-out retention.
- State-machine tests use an injected/explicit time source, not long wall-clock sleeps. Cover each phase boundary, both families at once, early cancellation, reselecting outgoing/incoming records, rapid changes, final motor restart, exact equal cruise speeds, pause/resume, and close/resize/reduced-motion changes mid-exchange. Assert no duplicate/missing records and final mounted-name agreement.
- Native window tests replace the obsolete separate-picker tests: one reusable menu/window, pointer and keyboard activation, focus-only arrows, wrapping at 760 pt, localized/accessible selected state, Escape, lifecycle and saved-state restoration.
- Capture the actual Metal-backed native chooser at ideal and compact widths and Retina backing. Compare it with `approved-preview.png`, especially sharp unstretched corduroy, sunburst grain/hardware, exact typefaces, plate size, flat laser lettering, level Allura names, half-visible edges, constant record size, and fixed layer order. Check native full-arm/cartridge clearance during the uppermost exchanges and both families crossing simultaneously. A browser capture or offscreen SwiftUI snapshot alone is not sufficient.
- Exercise actual main-player selection at rest and during cover handoff, confirming that both saved choices apply independently without playback/queue/rotation side effects. Retain existing player continuity/rendering tests; change them only if the chooser integration requires a legitimate expectation update.
- Run `swift test --package-path Packages/BopifyCore`, relevant native suites followed by the full `BopifyAppTests` scheme, shader compilation/build, `git diff --check`, and the established signed Release build/signature checks. Reuse `VinylRenderingFixture` and the project's native capture bridge where available. Report screen-capture skips and any checks blocked by the environment explicitly. No installation, packaging, publishing, signing-setting changes, or release is included in this request.

## Research and ownership

- [MoFi American Vintage](https://www.mofielectronics.com/products/mofi-electronics-x-fender-american-vintage-turntable) and the [user's review reference](https://futureaudiophile.com/mofi-electronics-x-fender-american-vintage-turntable-reviewed/) informed the sunburst alder, dark platter/belt, black hardware and pickguard details. The earlier PrecisionDeck's ash construction is a different model; the chosen visual reference is American Vintage.
- [IBM Plex typeface notes](https://raw.githubusercontent.com/google/fonts/main/ofl/ibmplexsans/DESCRIPTION.en_us.html) informed the small instrument-label treatment; the chosen file is Sans Condensed Medium.
- [Allura typeface notes](https://raw.githubusercontent.com/google/fonts/main/ofl/allura/DESCRIPTION.en_us.html) informed the restrained calligraphic mounted names. Preserve font licenses in bundled resources.

The user approved the appearance, independent families, edge presentation, physical sequence, final fonts and small laser-style BOPIFY plate. Native composition, bundling, compatibility/default policy, menu consolidation, lifecycle handling and test organization originated as the author's proposals and were approved with this document. Exact Swift file boundaries, localized translations, safe asset-loading fallback, and small pixel/spacing corrections remain builder decisions, provided they preserve the approved appearance and behavior.

Implementation plan: `docs/superpowers/plans/2026-11-01-record-appearance.md`. The user approved the plan and native inline execution; see that plan for actual verification evidence and execution decisions.
