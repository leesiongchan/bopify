# Vinyl pressing and motor verification

Date: 2026-10-11. Branch: codex/vinyl-pressing-motor, isolated native worktree.

The package suite, macOS build, native cache fixture and native player fixture pass. The visual matrix was captured and inspected. Record-specific GPU frame timing and live Spotify buffering remain unverified; this report does not claim full acceptance of those boundaries. No merge, publication, dependency, playback-model or Rust change.

## Acceptance evidence

| Spec item | Evidence | Result |
| --- | --- | --- |
| 1. Motor equations and transitions | RecordRotationTests: closed-form spin-up/brake, exact deadline, continuous anchors, snap, repeated requests, setAngle, backwards samples | Pass, pure unit tests |
| 2. Seed and classification | Pinned UTF-8 FNV values, weighted ordering/ties, Oklab saturation, sparse/invalid/zero-weight samples | Pass, pure unit tests |
| 3. Tests and build | 175 Playback + 56 Library + 28 Domain + 55 Auth; macOS build exit 0 | Pass, 314 tests |
| 4. Appearance and identity | 118/182 pt × light/dark × colourful/warm attention/greyscale/missing; repeat occurrence and fresh-process pixels | Pass, native fixtures |
| 5. Lifecycle and ambient work | Production RecordPlayerView, controlled PlayerModel events and native pointer handlers | Native fixture pass; live Spotify and buffering transition unverified |
| 6. GPU comparison | Matched 182 pt scene, Metal System Trace and Animation Hitches, 12 s before/after | Record-specific comparison unverified; compositor statistics retained separately |
| 7. Coverage report | Unit, native fixture, SDK fixture inputs and unavailable checks distinguished here | Recorded |

~~~sh
swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-pressing-tests
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-pressing-build build
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-pressing-build --output /private/tmp/bopify-pressing-cache --probe artwork-cache
VINYL_PROBE_COMPARE_DIR="$PWD/docs/superpowers/verification/assets/vinyl-pressing-2026-10-11" python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-pressing-build --output /private/tmp/bopify-pressing-native --probe pressing --measure-ambient
~~~

Saved output: [package](assets/vinyl-pressing-2026-10-11/package-results.txt), [cache](assets/vinyl-pressing-2026-10-11/cache-results.txt), [native](assets/vinyl-pressing-2026-10-11/native-results.txt). Xcode emitted its existing “Supported platforms for the buildables in the current scheme is empty” notice and exited successfully.

## Native visual matrix

Production views run in AppKit windows, captured by ScreenCaptureKit at 2× scale. The preview environment supplies invented tracks and original sample artwork without connecting to Spotify. Both app and fixture contain default.metallib; the native colour assertion verifies shader rendering.

| Artwork | 118 light | 118 dark | 182 light | 182 dark |
| --- | --- | --- | --- | --- |
| Colourful | [capture](assets/vinyl-pressing-2026-10-11/matrix-colourful-118-light.png) | [capture](assets/vinyl-pressing-2026-10-11/matrix-colourful-118-dark.png) | [capture](assets/vinyl-pressing-2026-10-11/matrix-colourful-182-light.png) | [capture](assets/vinyl-pressing-2026-10-11/matrix-colourful-182-dark.png) |
| Warm attention | [capture](assets/vinyl-pressing-2026-10-11/matrix-warm-attention-118-light.png) | [capture](assets/vinyl-pressing-2026-10-11/matrix-warm-attention-118-dark.png) | [capture](assets/vinyl-pressing-2026-10-11/matrix-warm-attention-182-light.png) | [capture](assets/vinyl-pressing-2026-10-11/matrix-warm-attention-182-dark.png) |
| Greyscale | [capture](assets/vinyl-pressing-2026-10-11/matrix-greyscale-118-light.png) | [capture](assets/vinyl-pressing-2026-10-11/matrix-greyscale-118-dark.png) | [capture](assets/vinyl-pressing-2026-10-11/matrix-greyscale-182-light.png) | [capture](assets/vinyl-pressing-2026-10-11/matrix-greyscale-182-dark.png) |
| Missing | [capture](assets/vinyl-pressing-2026-10-11/matrix-missing-118-light.png) | [capture](assets/vinyl-pressing-2026-10-11/matrix-missing-118-dark.png) | [capture](assets/vinyl-pressing-2026-10-11/matrix-missing-182-light.png) | [capture](assets/vinyl-pressing-2026-10-11/matrix-missing-182-dark.png) |

Baseline: [118 light](assets/vinyl-pressing-2026-10-11/baseline-118-light.png), [118 dark](assets/vinyl-pressing-2026-10-11/baseline-118-dark.png), [182 light](assets/vinyl-pressing-2026-10-11/baseline-182-light.png), [182 dark](assets/vinyl-pressing-2026-10-11/baseline-182-dark.png). The flat fill becomes static artwork-coloured marble; greyscale/missing retain dark vinyl. Label, grooves, spindle and rim remain readable. Fixed bow-tie highlights and narrow fringes replace the old reflection. The attention rim blended into warm patches in the [first capture](assets/vinyl-pressing-2026-10-11/warm-rim-before.png); its specified dark backing now separates it from the marble.

[Increased Contrast](assets/vinyl-pressing-2026-10-11/accessibility-increased-contrast.png) removes fringes and strengthens the existing rim. [Reduce Motion](assets/vinyl-pressing-2026-10-11/accessibility-reduce-motion.png) stops automatic rotation and shortens the dissolve. [Reduce Transparency](assets/vinyl-pressing-2026-10-11/accessibility-reduce-transparency.png) keeps the pressing opaque over the existing surface fallback.

Accessibility inputs use writable backing keys exposed by the local Xcode 27 SwiftUI SDK in this separate fixture. Production retains its public environment reads. This tests the rendering branches without changing global preferences; operating-system preference notifications were not verified.

## Identity, cache and scheduling

Annulus comparisons exclude the label and rim. Repeating URI C with a different occurrence produces the [same pressing](assets/vinyl-pressing-2026-10-11/identity-c-repeat.png) as [C](assets/vinyl-pressing-2026-10-11/identity-c.png). [A](assets/vinyl-pressing-2026-10-11/identity-a.png) and C share artwork but have different seeded swirls. All 16 matrix annuli had mean RGB difference **0.0** across two independent processes on this hardware.

While B's extractor is suspended, [A stays visible](assets/vinyl-pressing-2026-10-11/identity-b-pending.png), with its original seed. C remains selected when B finishes late. [B at 200 ms](assets/vinyl-pressing-2026-10-11/dissolve-b-200ms.png) and an [interrupted dissolve](assets/vinyl-pressing-2026-10-11/dissolve-interrupted-200ms.png) retain colour. At least two layers exist during a dissolve and exactly one after settling. Missing URL, extraction/HTTP failure, late URL, late Track metadata with known queue URI and mirror URI without metadata resolve to the expected seed/palette pair.

Cache checks cover image-only thumbnails, one extraction for ten overlapping requests, decoded-image reuse, published/pending palette eviction, clear/replacement races, negative-cache lifetimes, 640 px decoding and the 112-entry cap. Four fixed extraction inputs produced identical values/order in two processes. A solid sRGB fixture pins the readback boundary; it exposed and corrected alpha division and double colour conversion.

Temporary instrumentation observes the production timeline. Playing controls are positive. Pause, end, ordinary error and ownership loss coast, then produce two separate zero-update windows. Resume and a newer brake survive old deadlines. Hide, pointer press, Reduce Motion, loading, detachment and recovery stop immediately during drive and brake. Reduce Motion also stops during spin-up; disappearance stops drive/brake. Native pointer handlers preserve the scrubbed angle, restart at zero speed and issue exactly one seek. No counter or frame logging ships.

**Unavailable:** no live Spotify playback/recovery session was exercised. Buffering has no event path in current PlayerModel, so RecordMotorRequest's buffering snap is checked directly rather than through a native phase transition. Native runtime evidence covers macOS 27.0.1; the macOS 14 deployment target builds, but the older runtime was not exercised.

## GPU evidence and limitation

Mac mini, M4 Pro with 16 GPU cores, 48 GB; macOS 27.0.1 (26A434); Xcode 27.0 (27A266a). Both scenes use steady playback, a 182 pt record in the expanded production PlayerSurface/Liquid Glass path, dark appearance and 2× backing scale. Each recording lasts 12 s; statistics discard the first 2 s.

An initial Instruments launch resolved an older fixture through Launch Services; that failed capture was discarded. Valid recordings attach to the owned fixture PID:

~~~sh
VINYL_PROBE_HOLD_SECONDS=25 /path/to/MonolithProbe.app/Contents/MacOS/MonolithProbe /path/to/output &
vinyl_probe_pid=$!
xcrun xctrace record --template 'Animation Hitches' --time-limit 12s --output /private/tmp/bopify-vinyl-after-hitches.trace --no-prompt --attach "$vinyl_probe_pid"
wait "$vinyl_probe_pid"
xcrun xctrace export --input /private/tmp/bopify-vinyl-after-hitches.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="hitches-gpu"]' --output /private/tmp/bopify-vinyl-after-hitches-gpu.xml
~~~

Metal System Trace was also captured before/after. Its GPU interval tables contain zero fixture-attributed rows. Animation Hitches reports display/surface GPU intervals across two displays without an application ID. These cannot isolate the record's GPU cost. **Spec item 6 remains unverified; there is no shader regression verdict.** Apple describes the render-execute GPU phase in [Understanding hitches in your app](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app), checked 2026-10-11; the attribution limitation is our inference from the exported tables.

Compositor observations only; display labels are local to each trace:

| Capture | Display | Samples | Mean ms | Median ms | p95 ms |
| --- | --- | ---: | ---: | ---: | ---: |
| Before | 2 | 583 | 0.949 | 0.665 | 2.552 |
| Before | 3 | 446 | 2.324 | 1.456 | 7.487 |
| After | 2 | 454 | 1.169 | 1.346 | 1.480 |
| After | 3 | 582 | 1.824 | 1.770 | 2.257 |

[Machine-readable observations](assets/vinyl-pressing-2026-10-11/gpu-compositor.json). These are GPU durations, not CPU timing, but include unrelated desktop work and cannot support an app-specific comparison.

## Execution decisions

1. Normalize the 32 px source to sRGB and read raw KMeans RGBAf with premultiplication enabled and no output conversion. Native fixtures disproved the planned readback. Risk: palette colour shifts if this boundary is wrong.
2. Treat ready inactive idle as ownership-loss braking because PlayerModel folds loss into idle; local idle and explicit snap gates snap. Risk: up to 0.6 s unintended coasting on inactive idle.
3. Initially added a default-false Reduce Motion app override for testing. Initial risk: preview input could differ from the system environment. It was subsequently removed.
4. Check buffering policy directly because no model event produces that phase. Risk: the live buffering transition remains unverified.
5. Use the displayed queue URI while Track metadata is absent; mirror URI has priority. Risk: a neutral pressing takes a pending song seed before metadata confirms it.
6. Replace the app override with fixture-only SDK backing keys; NSAppearance alone did not change contrast. Risk: the fixture may need adaptation to a future SDK; no underscored API ships.

Whole-worktree diff checking is clean. The original checkout's unrelated changes were preserved; its earlier whitespace baseline does not apply here.

Independent whole-branch review is pending. Live Spotify buffering/recovery and attributable record GPU timing remain acceptance follow-ups.
