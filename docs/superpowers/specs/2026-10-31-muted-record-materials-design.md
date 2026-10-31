# Muted record materials

Status: approved by the user on 2026-10-31. The user accepted the Glass and Nacre visual studies, requested 50% smoke density for Glass, and approved this written design. Implementation planning is authorized.

## Intent and scope

Add two selectable materials to the record used for muted covers: Glass and Nacre. Preserve the current dark record as the default, provisionally named Classic. These are independent of the six colorful vinyl styles. Preserve artwork classification, cover artwork, label proportions, playback, rotation, scrubbing, and loading transitions.

This is a small extension of the established record renderer and native chooser conventions. The selection UI, persistence details, and accessibility behavior below are author proposals for approval.

## Approaches

Native SwiftUI/Metal rendering is recommended as the only practical fit for the existing renderer: it supports genuine alpha, resolution-independent grooves, stable per-song geometry, and the current rotation and handoff system without dependencies. Raster textures would add assets and filtering constraints; a separate renderer would duplicate established lifecycle and transition handling. Neither offers a useful benefit for this change.

## Appearance

- **Classic:** existing muted rendering and subtle cover tint, unchanged. Missing/unknown saved choices resolve to Classic.
- **Glass:** the accepted clear/smoked study at **50% smoke density**, permanently fixed in the product. This is the study's density parameter, not uniform 50% view opacity: smoke, grooves, and rim vary in opacity. Keep the annulus genuinely translucent and the artwork label opaque. Retain fine concentric grooves, restrained wisps, a polished thicker rim, and low-chroma smoke.
- **Nacre:** the accepted opaque silver-ivory study with broad organic shell layers, fine grooves, and restrained sage/warm-gray overtones. Its composition rotates with the record; a restrained lighting layer stays fixed relative to the player. Do not introduce vivid colors or time-varying procedural animation.

Both materials use normalized geometry and the existing deterministic song seed. Follow the accepted study's material character at both 182px and compact sizes; reduce detail below pixel scale to avoid shimmer.

Reference: `.superpowers/brainstorm/13908-1793450159/content/muted-record-materials-50-smoke.html` is an ignored throwaway browser study. Reconstruct its bounded procedural fields natively; do not ship its CPU pixel loop or rely on that file at runtime. Glass's density is `0.50`, with a baseline alpha modulated by the study's smoke field, groove/rim accents, and edge coverage. Nacre uses warped radial growth bands with low-chroma tonal changes and concentric groove detail.

## Choosing and saving

Add a separate **Record Design…** status-menu entry and a small reusable native window containing one row of three labeled previews: Classic, Glass, Nacre. Follow the existing auxiliary-window conventions, immediate selection, accessible names and selected state, arrow-key focus, Enter/Space activation, and Escape dismissal. Localize visible copy. Use a fixed muted sample label and a contrasting preview background so Glass's transparency is visible.

Persist independently under `player.recordDesign`, with stable IDs `classic`, `glass`, and `nacre`. The preference is device-local and survives relaunch and sign-out. Selecting it changes muted records globally; colorful covers continue to use the existing colorful-style preference. Returning to a muted cover restores the saved record design. There is no product smoke slider, background selector, per-song override, or new player toolbar control.

## Rendering and continuity

Resolve the material in the existing muted (`.tinted`) rendering path. Apply the preference to missing-artwork neutral records as well; keep unrelated startup/sign-in record illustrations unchanged. This fallback policy is an author's proposal.

Remove or replace the full opaque backing only when the resolved record is Glass. Preserve a subtle translucent edge/thickness treatment without filling the annulus with black. The background visible through Glass is whatever the player actually composites beneath it: desktop where the window is clear, or player surface/content where present. Do not add backdrop capture, refraction, or change the player's existing surface material.

Carry record-material identity through appearance snapshots alongside the existing style and palette. Keep outgoing records stable; defer preference changes during an active cover handoff until it settles, then apply the latest choice. Changing material must not restart the motor or recolor/fade the label. Coordinate annulus and backing transitions so an opaque old backing does not remain behind settled Glass.

Use bounded Metal work and existing paused/hidden animation behavior. Reduced Motion retains the existing short opacity transition. With Reduce Transparency enabled, render Glass using an opaque smoked fallback; keep the preference saved. Preserve contrast treatment, hit testing, and the opaque label/spindle.

## Verification

Verify persisted selection/default/invalid-ID behavior and independence from the colorful-style preference. Capture real native Metal-backed records on contrasting backgrounds at normal/compact sizes: Glass must reveal background changes through the annulus while its label stays opaque; Nacre must remain opaque and distinct. Verify Classic and all colorful-style paths retain their existing appearance.

Exercise native chooser pointer/keyboard operation, single-window reuse, relaunch persistence, muted/colorful transitions, outgoing handoffs, rapid selection changes, scrubbing, rotation continuity, Reduce Motion, and Reduce Transparency. Compare native Glass/Nacre captures with the accepted browser studies. Run affected app/package tests, required formatting/build checks, shader compilation, and the established signed-build checks; report actual results and unverified behavior.

## Research

- [Precision Record Pressing: multi-color effects](https://www.precisionpressing.com/blog/guide-multi-color-vinyl-effects-explained): clear/translucent bases, smoke blends, and shimmer inform Glass's material treatment.
- [Smithsonian National Museum of Asian Art: iridescence](https://asia.si.edu/explore-art-culture/art-stories/materials-techniques/iridescence/): layered nacre and its restrained tonal sheen inform Nacre; the proposed shader is an artistic approximation, not an optical simulation.

## Approval

The user approved this written design on 2026-10-31. The implementation plan is `docs/superpowers/plans/2026-10-31-muted-record-materials.md`; execution awaits plan review and selection of an execution method.
