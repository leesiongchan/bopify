# Vinyl pressing, sheen, and motor physics

Date: 2026-10-11

Status: Design approved in sections on 2026-10-11; written spec awaiting review.

## Intent and approved scope

Make the record feel more physical and give each song its own look, without new data sources or layout changes. The user chose three directions from a researched shortlist, each validated against interactive mockups:

1. **Direct-drive motor.** Spin up quickly on play and brake firmly on pause instead of starting and stopping instantly.
2. **Iridescent groove sheen.** A screen-fixed bow-tie highlight with faint diffraction fringes replaces the flat reflection.
3. **Marbled per-track pressing.** Each song's record is marbled vinyl coloured from its artwork, with a swirl seeded from its track URI so the same song always looks the same.

Out of scope: tonearm, audio-reactive motion, theatrical record-swap transitions, a setting to disable pressings, and any change to the 12 s cruise speed. No motion is added while loading, buffering, or recovering; the existing rule in the [refinement spec](2026-09-27-monolith-refinement-design.md) ("stop ambient scheduling when paused, buffering, loading…"), the [original Monolith spec](2026-09-26-monolith-player-design.md), and the [playback recovery spec](2026-10-04-playback-recovery-design.md) stays in force. A loading "creep" was mocked and explicitly rejected.

Success means play and pause read as a physical deck starting and stopping, songs are recognisable by their pressing across launches, nothing renders once the record has settled, and Reduce Motion behaves exactly as today.

## Evidence from the current implementation

- `VinylRecordView` draws a flat dark fill, 18 groove strokes, and the `MorphingArtworkView` label inside one rotating stack, with a screen-fixed `AngularGradient` reflection, spindle, and rim on top (`VinylRecordView.swift:24-48`). Its `TimelineView` runs at most 30 fps and pauses on `!isPlaying || !isVisible || reduceMotion || isScrubbing`.
- `RecordRotation` is a constant-speed clock: angle is phase plus elapsed running time at π/6 rad/s (`RecordRotation.swift`). `RecordPlayerView` toggles it with `setRunning(shouldSpin, …)` and uses `setAngle` on scrub release (`RecordPlayerView.swift:106-107, 136-140, 270-281`).
- `ArtworkStore` decodes thumbnails up to 640 px, caches up to 112 images keyed by URL, and has a generation counter cleared on `clear()`. It extracts no colour.
- Deployment target is macOS 14.0. The repo has no `.metal` files and no shader effects yet.
- The Swift side has no audio sample access, and Spotify's audio-features and audio-analysis endpoints are closed to apps created after 2024-11-27, which is why audio-reactive work is excluded.

## Motor physics

Extend `RecordRotation` into a closed-form motor. It records the angle, angular speed, and time at each state change (the anchor), plus whether the motor is driving or stopping. Angle and speed at any time are exact functions of the anchor, so there is no per-frame integration and the type remains a pure, testable value.

Let W = π/6 rad/s (the existing cruise speed), τ = time since the anchor, ω₀ = speed at the anchor.

- **Driving:** ω(τ) = W + (ω₀ − W)·e^(−kτ) with k = 6 s⁻¹ (about 95% of cruise in 0.5 s, effectively at cruise by 0.7 s). Angle is the exact integral: θ₀ + Wτ + (ω₀ − W)(1 − e^(−kτ))/k.
- **Braking:** constant deceleration D = W / 0.6 s from the anchor speed. ω(τ) = max(0, ω₀ − Dτ). The angle integrates until stop time τₛ = ω₀ / D and then holds.
- **Snap stop:** speed becomes zero immediately, angle frozen at its current value.

State changes re-anchor at the current angle and speed, so angle and speed are continuous across any sequence of play, pause, and resume, including play during a brake (spins up from the current speed) and pause during spin-up (brakes from the current speed). `setAngle` re-anchors at the given angle with zero speed.

`setRunning(false, …)` takes a stop style chosen by the caller:

| Cause of stopping | Style |
| --- | --- |
| Pause, end, loading, buffering, error, losing the active device, engine not ready | Brake |
| Player hidden, Reduce Motion enabled, pointer press on the record | Snap |

A press snaps because a hand on a real record stops it instantly, and the scrub needs a stationary surface. Releasing a scrub calls `setAngle` (zero speed) and then `setRunning(shouldSpin)`, so a playing record spins up from rest. Mirroring another device never spins, as today, because spinning still requires the active device.

The motor exposes `isMoving(at:)` (driving, or braking with time remaining) and the brake's stop time. `VinylRecordView`'s `TimelineView` pauses on `!isMoving` instead of `!isPlaying`, keeping the existing `!isVisible`, Reduce Motion, and scrubbing conditions and the 30 fps cap. Because `isMoving` changes with time, `RecordPlayerView` holds a coasting flag set when a brake starts and cleared by a single task that sleeps until the computed stop time; replacing the anchor cancels that task. Once the brake ends, ambient ticks drop to zero, as the existing specs require.

The 220° engage kick stays a separate animated rotation layer, unchanged.

## Marbled pressing

### Seed

`PressingSeed` in BopifyPlayback computes a 64-bit FNV-1a hash of the track URI string and passes `hash % 4096` as a `Float` noise-space offset to the shader. The key is the track URI, from the mirror's track URI when mirroring or the displayed track's URI otherwise, never `occurrenceID`, so repeat plays of a song share a pressing. `String.hashValue` and `Hasher` must not be used: they are randomly seeded per launch.

### Palette

`ArtworkStore` gains `palettes: [URL: ArtworkPalette]` and `loadPalette(_ url: URL) async`. Palettes are computed lazily, only for artwork the record displays, never for every queue or Cover Flow thumbnail. Computation happens off the main actor from the already-decoded `CGImage`: downsample to about 32 px, run `CIFilter.kMeans()` with count 3, perceptual enabled, and 5 passes, using one reused `CIContext`, and read the three resulting colours. Palette entries follow the image cache: they are removed when their image is evicted and discarded on `clear()` or a generation change, so a late result from an earlier session cannot be stored.

A pure classification function in BopifyPlayback turns the three colours into an `ArtworkPalette`:

- `.marble(c0, c1, c2)`, ordered by visual weight, when at least one colour has Oklab chroma (√(a² + b²)) of at least 0.05; the threshold is a named constant tuned against the native screenshots.
- `.tinted(color)` when every colour is below the threshold (greyscale or near-monochrome covers).

A track with no artwork, or whose palette fails, uses `.tinted` with a neutral colour.

### Rendering

Add `Bopify/Bopify/Shaders/Pressing.metal` with a `[[stitchable]]` colour effect that takes the view size, seed, and three colours. It evaluates multi-octave value noise to warp the domain, converts the warped coordinate into reflected stripes, and maps the stripe position onto the ramp c0 → c2 → c1 → near-black → c0, matching the approved mock. The output is opaque.

In `VinylRecordView`, the flat dark `Circle` fill inside the rotating stack is replaced by the pressing layer: the shader-filled circle for `.marble`, or the existing dark fill with a faint artwork-colour conic tint for `.tinted`. Grooves, label, and the screen-fixed layers stay in their current order above it. The view gains the pressing inputs (seed and palette) as plain values.

### Track changes

When the displayed track changes, the new pressing crossfades in over 0.65 s, matching the label morph and running during the existing tilt. Until the new palette is available, the previous pressing stays visible, so a track change never flashes black. With Reduce Motion the crossfade lasts 0.16 s, matching the label. The marble is static artwork and is not otherwise affected by Reduce Motion.

## Sheen

Replace the single reflection `AngularGradient` (`VinylRecordView.swift:39-46`) with two static, screen-fixed conic gradients composited in screen blend mode and masked to exclude the label:

- **Bow-tie:** two white lobes about 20° wide, centred near 15° and 195°, peaking around 0.26 and 0.20 opacity.
- **Iridescent fringe:** thin red, yellow, cyan, and violet bands hugging each lobe edge at about 0.2 opacity.

Concentric grooves make an anisotropic highlight invariant under rotation, so fixed gradients over the spinning record read correctly without a shader. Under Increase Contrast, omit the fringe and keep the existing high-contrast rim stroke.

## Accessibility

- Reduce Motion: no automatic spin, snap stops, short crossfades. Unchanged from the current behaviour.
- Increase Contrast: rim stroke as today; no iridescent fringe.
- Reduce Transparency: no change needed; the pressing is opaque.
- The record remains `accessibilityHidden`; no new accessible elements.
- The orange attention rim (`RecordPlayerView.swift:189-193`) must remain distinguishable on warm marbles. If native screenshots show it failing, add a thin dark backing stroke beneath it.

## Observability

Use `BopifyLog.playback` at debug level for palette computed, palette failed, and stale palette discarded. Log no URLs, track metadata, or per-frame information.

## Verification and acceptance

1. Unit tests in `RecordRotationTests`: spin-up speed and angle against the closed form, brake duration and final angle, continuity of angle and speed across pause during spin-up and play during braking, snap stop, `setAngle` zeroing speed, and `isMoving` turning false exactly at the stop time.
2. Unit tests for `PressingSeed` (fixed URIs map to pinned values; different URIs differ) and palette classification (saturated colours yield `.marble` with stable ordering; greyscale yields `.tinted`).
3. Build the macOS app and run the package tests.
4. Native screenshots at 118 pt and 182 pt, light and dark appearance, for a colourful cover, a warm orange or red cover with the attention rim visible, a black-and-white cover, missing artwork, and the same song played twice (identical pressing).
5. In the running app, exercise play, pause, buffering, end of track, scrub and release while playing, hide during a brake, and toggle Reduce Motion during spin-up and brake. Confirm with a temporary tick counter or Instruments that the record's timeline stops ticking once the brake ends and when hidden.
6. Compare GPU frame time for the record at 182 pt over Liquid Glass before and after the shader.
7. Report which checks were run natively and which were covered only by unit tests or previews.

## Research

- [Stereophile: Technics SL-1200GME specifications](https://www.stereophile.com/content/technics-sl-1200gmesl-1210gme-turntable-specifications), accessed 2026-10-11: direct drive reaches 33⅓ rpm in 0.7 s, the basis for the spin-up constant.
- [HiFi News: Roksan Attessa lab report](https://www.hifinews.com/content/roksan-attessa-turntable-package-lab-report), accessed 2026-10-11: belt drive takes 4–5 s to reach speed (the rejected belt-drive option).
- [3dRender glossary: Anisotropic shading](https://3drender.com/glossary/anisotropic.htm), accessed 2026-10-11: highlights stretch perpendicular to grooves; records are a classic example.
- [Standard Vinyl: Coloured vinyl](https://standardvinyl.com/vinyl-pressing/coloured-vinyl/), accessed 2026-10-11: marbled records mix two or more colours before pressing and need an opaque component to show structure.
- [Hacking with Swift: Metal shaders with layer effects](https://hackingwithswift.com/quick-start/swiftui/how-to-add-metal-shaders-to-swiftui-views-using-layer-effects), accessed 2026-10-11: `[[stitchable]]` functions exposed through `ShaderLibrary`, available from macOS 14.
- macOS 27.0 SDK `CoreImage/CIFilterBuiltins.h`: `KMeansFilter NS_AVAILABLE(11_0, 14_0)`, available on the macOS 14 deployment target.
- [Techzine: Spotify restricts developer API access](https://www.techzine.eu/news/applications/126612/spotify-is-restricting-developers-api-access/), accessed 2026-10-11: audio features and analysis are unavailable to apps created after 2024-11-27.
- [Thomas Park: Needledrop](https://thomaspark.co/?p=13148) and [Framer DiscPlayer](https://www.framer.com/marketplace/components/discplayer/), accessed 2026-10-11: tonearm patterns considered and deferred.
