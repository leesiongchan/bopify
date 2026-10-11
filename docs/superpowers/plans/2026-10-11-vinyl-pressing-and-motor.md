# Vinyl Pressing, Sheen, and Motor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each track a stable artwork-coloured pressing, add groove sheen, and make play/pause accelerate and brake while stopping ambient work after settling.

**Architecture:** Keep motor sampling, URI hashing, and palette classification as pure BopifyPlayback values. ArtworkStore computes palettes lazily on its existing decoder actor; RecordPlayerView owns motor lifecycle and displayed pressing identity. VinylRecordView renders the pressing under its existing grooves and label, with screen-fixed sheen above them.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, Core Image, Metal; macOS 14 minimum; existing native AppKit verification runner. No new dependency.

**Spec:** [2026-10-11-vinyl-pressing-and-motor-design.md](../specs/2026-10-11-vinyl-pressing-and-motor-design.md).

**Status:** Approved for Native execution in a new worktree on 2026-10-11. Implementation in progress.

## Global Constraints

- Cruise speed remains π/6 rad/s: one revolution in 12 s. Drive constant is 6 s⁻¹; brake deceleration is (π/6)/0.6 rad/s².
- Use monotonic uptime and closed-form sampling, with continuous angle/speed when changing between drive and brake. Snap and setAngle explicitly zero speed.
- Timeline cap remains 30 fps. Loading, buffering, recovery, engine unavailability, idle, hidden, Reduce Motion, and pointer press snap immediately; mirrored playback never drives the motor.
- Keep the 220° engage kick, existing tilt, layout, label morph, progress ring, scrub math, and accessibility actions.
- Pressing seed is the displayed song's URI, including mirror.trackURI, never queue occurrence identity or Swift's randomized hashing. Shader offset is Float(hash % 4096).
- Palette extraction is lazy for displayed artwork only: approximately 32 px, three KMeans clusters, perceptual enabled, five passes, one reused CIContext. The existing image cache remains capped at 112 entries.
- Marble classification uses a named Oklab chroma threshold initially 0.05. Greyscale, missing artwork, and extraction failure use tinted vinyl; missing/failed artwork uses a neutral tint.
- Crossfade duration is 0.65 s normally and 0.16 s under Reduce Motion. Keep the previous seed and palette together until the replacement is ready.
- Sheen remains screen-fixed. Increased Contrast omits iridescent fringes and retains the existing contrasting rim. Pressings are opaque; the record remains accessibilityHidden.
- Palette computed, failed, and stale-result-discarded logs use BopifyLog.playback.debug without URLs, track metadata, or per-frame messages.
- No tonearm, audio-reactive motion, loading creep, theatrical swap, pressing setting, new data source, or unrelated cleanup.

## Confirmed Stop Policy

The user confirmed immediate stops for loading, buffering, and recovery on 2026-10-11. Retain the other brake causes from the approved design:

| Cause of stopping | Style |
| --- | --- |
| Pause, end, error, losing the active device | Brake |
| Loading, buffering, recovery, engine not ready, idle | Snap |
| Player hidden, Reduce Motion enabled, pointer press on the record | Snap |

Snap takes precedence whenever multiple conditions apply and interrupts any existing brake. For example, engine detachment snaps even if the playback phase is paused or errored. Task 4 observes the stop request independently of the old shouldSpin Boolean so entering loading or recovery during a brake stops immediately.

## Review Focus

1. Hide, Reduce Motion, or pointer press during a brake must override it even though the old shouldSpin Boolean is already false; Task 4 measures immediate stop.
2. A cancelled brake-end task must not stop a resumed drive or a newer brake; Task 4 tests both deadline races in the production view.
3. Palette completion after clear, eviction, or replacement must not restore stale colour; Tasks 3 and 5 suspend extraction and change the owning identity.
4. Repeated URI, shared artwork, empty clusters, and a late artwork URL must produce stable song identity without false saturation; Tasks 2, 3, and 5 cover these boundaries.
5. Fast changes during a dissolve must not flash neutral or apply the next seed to the old palette; Task 5 captures delayed and interrupted transitions.

## File Map

| File | Responsibility |
| --- | --- |
| `Packages/BopifyCore/Sources/BopifyPlayback/RecordRotation.swift` | Closed-form motor and stop deadline |
| `Packages/BopifyCore/Tests/PlaybackTests/RecordRotationTests.swift` | Motor equations, continuity, idempotence, settling |
| `Packages/BopifyCore/Sources/BopifyPlayback/PressingSeed.swift` (new) | Stable FNV-1a URI hash and shader offset |
| `Packages/BopifyCore/Sources/BopifyPlayback/ArtworkPalette.swift` (new) | Sendable RGB colours, weighted classification, neutral fallback |
| `Packages/BopifyCore/Tests/PlaybackTests/PressingSeedTests.swift` and `ArtworkPaletteTests.swift` (new) | Pure seed and classification boundaries |
| `Bopify/Bopify/ArtworkStore.swift` | Lazy palette extraction, coalescing, invalidation, boundary logs |
| `Bopify/Bopify/Views/RecordPlayerView.swift` | Stop reasons, one settling task, displayed pressing identity |
| `Bopify/Bopify/Views/VinylRecordView.swift` | Scheduling gate, pressing placement, fixed sheen |
| `Bopify/Bopify/Views/VinylPressingView.swift` (new) | Static marble/tint rendering and opacity transitions |
| `Bopify/Bopify/Shaders/Pressing.metal` (new) | Static stitchable marble colour effect |
| `Bopify/Bopify/Views/PlayerPreviews.swift` | Adapt the second record caller and native fixtures |
| `docs/superpowers/verification/ArtworkCacheProbe.swift` | Lazy/coalesced extraction and invalidation verification |
| `docs/superpowers/verification/VinylPressingProbe.swift` (new) | Current native composition, visual and motor checks |
| `docs/superpowers/verification/run-monolith-probe.py` | New probe choices, current ambient marker, resource verification |
| `docs/superpowers/verification/2026-10-11-vinyl-pressing-and-motor.md` and assets (new) | Acceptance evidence and GPU comparison |

Xcode uses synchronized source groups; new app files should require no project-file edits. Package targets already discover new Playback sources/tests. Do not modify playback/recovery models, Rust, queue/carousel loaders, or label morph merely to implement this plan. RecordPlayerView already has unrelated queue-direction edits; preserve them and stage only task-owned changes.

## Verification Commands

```sh
swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-pressing-tests
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-pressing-build build
```

For a focused package test, append `--filter RecordRotationTests`, `--filter PressingSeedTests`, or `--filter ArtworkPaletteTests`. Rust artifacts exist in the current checkout; on a fresh checkout run `./scripts/build-rust.sh` first as README requires.

After Tasks 3–4 add the runner choices:

```sh
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-pressing-build --output /private/tmp/bopify-pressing-cache --probe artwork-cache
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-pressing-build --output /private/tmp/bopify-pressing-native --probe pressing --measure-ambient
```

The historical visual/composition probes use outdated production constructors. Use the focused pressing probe rather than claiming those historical commands currently pass or migrating unrelated fixtures.

### Task 1: Closed-Form Motor

**Files:** Modify RecordRotation.swift and RecordRotationTests.swift from the map.

**Interfaces:** Preserve `init()`, `angle(at: TimeInterval) -> Double`, and `setAngle(_: Double, at: TimeInterval)`. Add nested `RecordRotation.StopStyle: Sendable { case brake, snap }`, `speed(at: TimeInterval) -> Double`, `isMoving(at: TimeInterval) -> Bool`, and read-only `stopTime: TimeInterval?`. Extend `setRunning(_ running: Bool, at: TimeInterval, stopStyle: StopStyle = .brake)`.

- [x] **1. Write failing equation and boundary tests.** Initial rest has angle/speed zero and isMoving false. After driving from rest at 0, at 0.5 s speed equals `W * (1 - exp(-3))` and angle equals `W * 0.5 - W * (1 - exp(-3)) / 6`, within 1e-10. Repeat drive at 0.25 s and assert unchanged sampling at 0.5 s. At 3 s, brake from sampled speed v: deadline equals `3 + v / D`, final angle equals `angleAt3 + v * v / (2 * D)`, and speed is zero at the deadline. Immediately before it isMoving is true; at/after it is false and angle holds.
- [x] **2. Add state-change tests and run RED.** Pause at 0.2 s during spin-up, then resume halfway through that brake: both angle and speed are continuous at each anchor. Repeating a brake does not extend its deadline. Snap interrupts both drive and brake with frozen angle, zero speed, and no deadline. setAngle(5, at:) during either mode makes the motor stationary until explicitly driven. Queries before the anchor clamp elapsed time to zero. Replace existing instant-cruise expectations with the approved integral; run the focused command and inspect the failure.
- [x] **3. Implement the motor.** Store anchor angle, speed, time, and mode. Integrate driving analytically with k = 6; braking uses D = W/0.6 and clamps elapsed time at stop duration. Preserve idempotent drive/brake requests, but permit snap to override an existing brake. setAngle leaves a stationary anchor. No timers or per-frame mutation in this type.
- [x] **4. Run GREEN and commit.** Run RecordRotationTests and existing RecordScrubTests; require zero exit status. Commit task-owned files as `Model vinyl spin-up and braking with a closed-form motor`.

### Task 2: Stable Seed and Weighted Palette Values

**Files:** Create PressingSeed.swift, ArtworkPalette.swift, PressingSeedTests.swift, and ArtworkPaletteTests.swift.

**Interfaces:** `public enum PressingSeed` exposes `static func hash(_ uri: String) -> UInt64` and `static func offset(_ uri: String) -> Float`. `public struct ArtworkColor: Sendable, Hashable` contains Double red/green/blue with `init(red:green:blue:)`. `public enum ArtworkPalette: Sendable, Hashable` has `.marble(ArtworkColor, ArtworkColor, ArtworkColor)`, `.tinted(ArtworkColor)`, `static let neutral`, and `static func classify(_ samples: [(color: ArtworkColor, weight: Double)]) -> ArtworkPalette`.

- [x] **1. Write pinned seed tests and run RED.** Assert `hash("spotify:track:abc") == 2443243037788774046` and its offset is 3742; `hash("spotify:track:def") == 4257243709808024385` and offset 2881. Verify UTF-8 rather than character-code hashing with `"spotify:track:é"` yielding 17385341988102125798 and 2278. Repeated calls agree and offsets are integral Floats in 0..<4096. Run PressingSeedTests and inspect the failure.
- [x] **2. Write classification tests and run RED.** Weighted red/green/blue samples with weights 0.6/0.3/0.1 yield marble in descending weight order regardless of input order. Equal weights use ascending lexicographic RGB order. Black/grey/white and a near-neutral sample yield tinted using the dominant valid colour. Saturated zero-weight clusters cannot make a greyscale cover marble. One/two valid clusters are repeated to fill the three-colour ramp; no valid sample yields neutral. Run ArtworkPaletteTests and inspect the failure.
- [x] **3. Implement the pure functions.** Hash UTF-8 octets with FNV-1a offset basis 14695981039346656037, prime 1099511628211, and UInt64 wrapping multiplication. Classify finite positive-weight samples in explicit sRGB, convert gamma-encoded components to linear sRGB before Oklab, and compare chroma against the named 0.05 threshold. Sort by weight with the RGB tie-breaker; tinted uses the dominant colour. Use the existing dark fill RGB (0.035, 0.055, 0.05) as neutral. Do not add a colour framework for this bounded conversion.
- [x] **4. Run GREEN and commit.** Run both focused suites; require all pinned values, ordering, and fallback cases pass. Commit as `Derive stable vinyl seeds and classify artwork palettes`.

### Task 3: Lazy Extraction with Cache Lifetimes

**Files:** Modify ArtworkStore.swift, ArtworkCacheProbe.swift, and run-monolith-probe.py. Consume Task 2 values.

**Interfaces:** Add `private(set) var palettes: [URL: ArtworkPalette] = [:]` and `func loadPalette(_ url: URL) async` to ArtworkStore. Add `func palette(_ image: CGImage) -> ArtworkPalette?` on the existing private ArtworkDecoder actor, using one actor-owned CIContext. Keep `load(_:)` image-only. For the probe, add DEBUG-only `init(session: URLSession, paletteExtractor: @escaping @Sendable (CGImage) async -> ArtworkPalette?)` with a required closure; existing initializers/callers continue to work without ambiguous defaults.

- [x] **1. Extend the native cache probe before implementation.** Normal load of ten thumbnail URLs performs zero extractions. Ten overlapping loadPalette calls for one URL perform one extraction and reuse the cached decoded image without another HTTP request. Gate an injected extraction: clear before releasing it and assert no palette/image is restored; evict its image before releasing it and assert no palette is restored; clear/reload the same URL and ensure the older task cannot remove or overwrite the new one. Failed HTTP/decode/extraction completes without a stuck pending entry. Keep existing image coalescing, 640 px bound, negative cache, and 112-entry assertions.
- [x] **2. Add the artwork-cache runner choice and run RED.** Dispatch the existing ArtworkCacheProbe.swift through the current app-source runner, build, then run the cache command. Initial failure must concern missing palette behavior, not unrelated obsolete fixture APIs. Native probes test our cache/extractor boundary, not Core Image's clustering algorithm.
- [x] **3. Implement extraction/publication.** Await load(url), obtain its already-decoded CGImage on the main actor, and send only that CGImage to the decoder actor. Downsample to a maximum dimension of 32; configure count = 3, perceptual = true, passes = 5. Set inputMeans to a fixed 3×1 opaque black/mid-grey/white seed image. Normalize the thumbnail to sRGB, then read raw RGBAf with outputPremultiplied enabled and no output colour-space conversion: RGB carries encoded sRGB colour and alpha carries cluster weight. Delegate classification to Task 2.
- [x] **4. Bind palette tasks to the cache.** Coalesce by URL and retain request identity plus generation for publication. Before storing, require matching generation/request and an image still in the cache. On image eviction remove its palette, cancel/remove its palette task and failure marker; clear resets all palette work. Cache extraction failure for that image lifetime; completed failures resolve in the record caller to neutral. Log computed/failed/stale discarded without identifying data.
- [x] **5. Run GREEN and determinism verification; commit.** Build and run the cache probe. Add fixed colourful, warm, greyscale, and solid-colour images to its real extraction path, then run it in two separate processes and compare emitted palette components/order for the same inputs. Use tolerances for numerical representation and native pressing captures for visible agreement; fixed inputMeans is a precaution, not a claim Apple guarantees cross-device bit identity. Commit as `Extract displayed artwork palettes within the image cache lifetime`.

### Task 4: Motor Lifecycle and a Current Native Fixture

**Files:** Modify RecordPlayerView.swift, VinylRecordView.swift, PlayerPreviews.swift, and run-monolith-probe.py; create VinylPressingProbe.swift. Consume Task 1.

**Interfaces:** Replace VinylRecordView's `isPlaying: Bool` input with `isMoving: Bool`; retain all gesture/visibility/accessibility inputs. RecordPlayerView owns a coasting flag and one cancelable deadline task. Observe an Equatable local request with drive/brake/snap cases, rather than only shouldSpin. The stop reasons use the confirmed table above.

- [x] **1. Resolve the stop policy before code.** Immediate loading/buffering/recovery stops confirmed on 2026-10-11; the spec and plan now agree on the table and snap precedence. No playback/recovery model change is required.
- [ ] **2. Create the focused native fixture and baseline.** Add the pressing runner choice using `makePreviewEnvironment(.playing, library: .samples)` and current `RecordPlayerView(player:artworkStore:presentation:windowController:).environment(environment)`. Use PlayerModel.applyPreviewEvents for controlled playback states; do not expose the preview engine's private emit. Add assertions that initially fail for pause coasting and safe deadline replacement. Capture the current record at 118/182 pt and record pre-shader GPU frame timing at 182 pt over the actual PlayerSurface/Liquid Glass path.
- [ ] **3. Integrate anchor changes and deadline ownership.** Centralize rotation mutation, coasting updates, and deadline replacement. Sleep until the motor's computed stopTime using the same uptime clock; cancellation and anchor identity prevent an old sleeper clearing a newer coast. Supply `isMoving` from driving/coasting state plus rotation.isMoving(at:). Hide/Reduce Motion/press override braking even when shouldSpin remains false. On disappearance cancel settling and snap after existing gesture cancellation. Scrub release/setAngle still restarts from zero speed when eligible; no phase reset merely because the track changes. Log actual drive/brake/snap changes at debug level without metadata or frame samples.
- [ ] **4. Adapt scheduling and previews.** Timeline pauses on !isMoving plus existing hidden/Reduce Motion/scrubbing gates, keeping 1/30 s minimumInterval. Update both known callers. The preview also terminates a brake with one deadline update. Update the runner's exact ambient marker, requiring exactly one match before injecting the temporary counter; production receives no tick logging.
- [ ] **5. Verify the lifecycle natively and commit.** Require positive steady-playing tick counts, coasting after pause, then zero ticks after deadline + two frame intervals. Resume before the old deadline and verify ticks persist afterward; brake A→resume→brake B must ignore A's deadline. Hide, Reduce Motion, press, disappearance, loading, buffering, and recovery during driving/braking stop immediately. Scrub/release while playing restarts without angle discontinuity and issues only the existing one seek. Test end, error, device loss, and engine detachment against the confirmed stop table, including snap precedence over a simultaneous brake cause. Run RecordRotationTests, RecordScrubTests, app build and pressing probe; commit as `Coordinate vinyl settling with playback and visibility`.

### Task 5: Pressing Rendering, Crossfade, and Groove Sheen

**Files:** Create Pressing.metal and VinylPressingView.swift; modify RecordPlayerView.swift, VinylRecordView.swift, PlayerPreviews.swift, and VinylPressingProbe.swift. Consume Tasks 2–4.

**Interfaces:** Add `pressingSeed: Float` and `palette: ArtworkPalette` plain inputs to VinylRecordView, defaulting to zero/neutral for initial fixtures. `VinylPressingView(seed: Float, palette: ArtworkPalette, diameter: CGFloat)` renders a static pressing. Shader signature: `[[stitchable]] half4 pressing(float2 position, half4 color, float2 size, float seed, half4 c0, half4 c1, half4 c2)`; SwiftUI passes `.float2(size)`, `.float(seed)`, and three `.color(...)` values in that order.

- [ ] **1. Extend native acceptance before rendering.** Pause the record to isolate pressing pixels. Assert repeated URI with different occurrence IDs has the same pressing; two songs sharing a cover use different swirl offsets. Suspend palette B while A is visible and compare captures: A's seed/palette remain together until B completes. Advance A→B→C with B resolving last and assert C remains selected. Cover missing URL, failed extraction, late metadata/artwork URL on the same URI, mirror identity without loaded track metadata, and rapid interruption at 0.2 s. The current flat record must fail the colourful pressing/sheened appearance checks.
- [ ] **2. Implement static marble/tint rendering.** Use size-normalized coordinates, multi-octave value noise, domain warp, reflected stripes, and the ramp c0→c2→c1→near-black→c0. Do not pass time into the shader. Apply the opaque colour effect to a rectangle and clip the result to Circle afterward so pixels outside the record remain transparent. Tinted uses the current dark fill with a faint artwork-colour conic tint. Keep existing grooves/label above this layer and rotate them together.
- [ ] **3. Resolve identity and dissolve ready pressings.** Use a local Equatable request containing URI and artwork URL so late artwork updates retrigger loading. URI comes from mirror.trackURI or the displayed track, while occurrenceID continues to control existing tilt/label behavior. Retain displayed seed/palette until loadPalette completes, check task cancellation/current request before applying, and resolve missing/failed art to explicit neutral. Crossfade keyed static pressing layers with SwiftUI opacity transitions for 0.65/0.16 s; allow SwiftUI to retain interrupted presentation rather than manually dropping the visible old layer. Hidden updates settle immediately and no pressing TimelineView is added. Verify transient layers are released after transitions finish.
- [ ] **4. Add screen-fixed sheen.** Use two screen-blended conic gradients masked outside the label: white bow-tie lobes approximately 20° wide at 15°/195°, peaks 0.26/0.20; red/yellow/cyan/violet fringe bands at about 0.2 opacity along lobe edges. Increased Contrast removes fringe. Preserve spindle/rim layer order and current rim strength. Add a thin dark backing under the orange attention stroke only if warm-cover captures show the attention rim losing distinction.
- [ ] **5. Build and run GREEN; commit.** Verify the built app and separate fixture both contain and load default.metallib; the runner already copies app resources, so add no separate shader build pipeline. Run seed/palette suites, cache probe and native pressing probe. Inspect colourful/warm/greyscale/missing and interrupted captures in both sizes/appearances. Commit as `Render artwork-coloured vinyl with fixed iridescent sheen`.

### Task 6: Native Acceptance and Evidence

**Files:** Create the verification report/assets from the map. Modify task-owned code/probes only to fix findings within this spec.

**Interfaces:** Use production views and controlled fixtures for native evidence; identify live-player, fixture, pure-unit, and unavailable checks separately.

- [ ] **1. Capture and inspect the complete visual matrix.** At 118/182 pt in light/dark appearance capture colourful, warm orange/red with attention rim, black-and-white, missing artwork, and repeated same-song pressings. Compare against Task 4 baseline with the motor paused and other animated layers settled. Include Increased Contrast, Reduce Motion, and Reduce Transparency. Confirm label/grooves/rim remain readable and pressing identity survives a fresh process.
- [ ] **2. Exercise the running player and scheduling.** Use the focused native fixture for play/pause/end/scrub/release, hidden/disappeared states, active-device loss, and Reduce Motion during spin-up/brake. Exercise real app buffering/recovery if the signed-in session permits; otherwise report fixture coverage and the unavailable live boundary. After every finite transition require two separate settled sampling windows with zero ambient ticks, preceded by a positive playing control.
- [ ] **3. Compare GPU frame time.** Use Instruments' available Metal/GPU timing against the same 182 pt surface, appearance, scale, steady playback, and capture duration as Task 4. Record hardware/OS, capture duration, baseline/after statistics, and any practical regression. Do not substitute CPU timing or pure shader math for GPU evidence; if unavailable, mark this acceptance item unverified rather than claiming success.
- [ ] **4. Run final regression checks once fixes are complete.** Run the full package suite, app build, cache probe, and pressing probe with ambient instrumentation. Run scoped git diff --check on task-owned tracked files and inspect new files too. Whole-tree diff checking currently reports unrelated whitespace in the dirty librespot queue patch; record that baseline rather than changing it or asserting the entire workspace is clean.
- [ ] **5. Write the evidence report and obtain independent review.** Map spec acceptance items 1–7 to commands, observed output, captures, and GPU evidence. Identify unavailable checks explicitly; they remain incomplete. Fix review findings within scope, rerun affected checks, and commit as `Verify native vinyl pressings and motor settling`. Follow the selected execution workflow's independent review and branch finishing steps; no merge or publication is authorized by this plan.

## Current References

- [Apple: KMeansFilter](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/kmeans%28%29?language=objc), checked 2026-10-11: output RGB represents cluster colour, alpha its weight; count, passes, and perceptual configure extraction.
- [Apple: CIKMeans.inputMeans](https://developer.apple.com/documentation/coreimage/cikmeans/inputmeans), checked 2026-10-11 and against the local Xcode 27 SDK: accepts an optional image of initial cluster colours; fixed seeds are our determinism precaution.
- [Apple: CIContext](https://developer.apple.com/documentation/coreimage/cicontext), checked 2026-10-11: reuse contexts and avoid sharing mutable filter instances across threads.
- [Apple: CIContextOption.outputPremultiplied](https://developer.apple.com/documentation/coreimage/cicontextoption/outputpremultiplied), checked against the local Xcode 27 SDK: controls bitmap alpha conversion; native boundary measurements require raw readback to preserve cluster centres and weights.
- [Apple: colorEffect(_:isEnabled:)](https://developer.apple.com/documentation/swiftui/view/coloreffect%28_%3Aisenabled%3A%29), checked 2026-10-11: colour effects take position, source colour, then bound uniform arguments.
- [Björn Ottosson: A perceptual color space for image processing](https://bottosson.github.io/posts/oklab/), conversion matrices updated 2021-01-25, checked 2026-10-11: the published conversion consumes linear sRGB; chroma is sqrt(a²+b²).
- [RFC 9923: The FNV Non-Cryptographic Hash Algorithm](https://datatracker.ietf.org/doc/html/rfc9923), checked 2026-10-11: FNV-1a XORs each input octet before multiplying modulo the hash width.

Core Image supplies the clustering implementation. The short FNV loop and published Oklab conversion are bounded pure math; no service client, general-purpose colour library, or procedural-texture dependency is needed.

## Self-Review and Execution Handoff

Coverage: motor equations → Task 1; deterministic seeds/classification → Task 2; lazy extraction/cache/observability → Task 3; lifecycle/timeline → Task 4; pressing/crossfade/sheen/accessibility → Task 5; native matrix/GPU/evidence → Task 6. Each Review Focus condition has an owning verification step. All introduced signatures are defined before consumers and existing callers are accounted for.

The stop policy is resolved and the spec and plan agree. Review the final plan before implementation. Recommend **Native execution**: these six tasks share the cache, record view, and verification fixture, so one implementer can retain their integration context and finish with a fresh whole-change review. Subagent-driven execution supplies independent review after each task at the cost of additional contexts.
