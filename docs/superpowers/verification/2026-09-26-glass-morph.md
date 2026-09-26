# Liquid Glass window and artwork morph verification

Approved scope: a native translucent window surface; a 420 ms artwork lens morph;
204 pt center artwork with 64 pt adjacent previews and 6 pt gaps; remaining time
on the middle progress ring; a hold-activated luminous radial scrub gradient.
The existing 250 ms holds, 94% artwork shrink, left-release skip threshold,
22 pt scrubber, bottom-origin progress and two-ring system remain in place.

## Implementation

Expanded and queue layouts have one rounded native regular-glass window surface.
Compact mode retains its existing glass capsule. The visible shared artwork
uses a Metal distortion shader, a restrained highlight, and an opaque image blend.
On interruption, the current lens phase survives and the undistorted image blend
is flattened at 2× resolution; only two live images are retained. Side previews
yield outward during dragging and do not travel through the current cover.
The progress ring has a short visual gap behind the remaining-time label while
its full circular hit region remains available.

## Results

- Command-line macOS build: exit 0, including compilation of ArtworkLens.metal.
- Complete Swift suite: 102 tests pass (40 Playback, 12 Library, 18 Domain, 32 Auth).
- ArtworkMorphProbe: opaque base, midpoint blend, rendered color and lens-phase
  continuity, final image cleanup, missing/delayed art and unchanged art pass.
- 100-interruption stress probe: no more than two retained artwork layers.
- Native pointer probe: seeks `[75000, 50000, 75000, 90000]`, exactly one skip.
  Quick clicks, unheld/short/right album drags, control loss, duration updates,
  metadata-before-queue replacement and cancellation behave as expected.
- Native ScreenCaptureKit own-process captures inspected for expanded 410,
  light 390, increased-contrast appearance, compact 340, queue, intermediate
  morphs, interruption, held/released scrubber and held/dragged/released artwork.
- `git diff --check`: clean.

The deformation-continuity and bounded-layer assertions both failed before
their fixes. The initial morph probe first failed to compile because its new
state type did not exist; this was not an assertion failure. Visual inspection
also caught and fixed the glow enlarging the ring's layout: the glow is now a
background and the progress diameter remains 274 pt at the default scale.
The native gesture sequence passed on final runs; an earlier standalone run
failed its final assertion without flushed detail, so it was rerun with live
output and then rerun after the ring-layout fix.

## Reproduce

The ignored Rust framework must already exist in `artifacts/`. Xcode needs its
Metal compiler component (`xcodebuild -downloadComponent MetalToolchain`).

```sh
swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-morph-tests
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-morph-build build
swiftc -parse-as-library -swift-version 6 \
  docs/superpowers/verification/ArtworkMorphProbe.swift \
  Bopify/Bopify/Views/ArtworkMorphState.swift Bopify/Bopify/Views/ArtworkView.swift \
  -o /private/tmp/bopify-morph-state-probe
/private/tmp/bopify-morph-state-probe
/private/tmp/bopify-morph-state-probe --stress
python3 docs/superpowers/verification/run-glass-morph-probe.py \
  /private/tmp/bopify-morph-build /private/tmp/bopify-morph-repro
/private/tmp/bopify-morph-repro/GlassProbe.app/Contents/MacOS/GlassProbe \
  /private/tmp/bopify-glass-morph-captures
```

The native probe runs on macOS 26+ and opens only fixture windows; it does not
start Spotify or request authentication. It captures its own process through
`SCShareableContent.currentProcess`. AppKit bitmap captures omit composited
glass; the saved before-geometry image documents layout only. Final images in
`assets/glass-morph/` include the native glass composition.

## Visual evidence and limits

[Expanded](assets/glass-morph/00-expanded.png),
[mid-morph](assets/glass-morph/01-morph.png),
[interrupted morph](assets/glass-morph/02-interrupted.png),
[light/narrow](assets/glass-morph/07-light-390.png),
[active scrub](assets/glass-morph/gesture-01-held-scrubber.png),
[released scrub](assets/glass-morph/gesture-02-released.png),
[held drag](assets/glass-morph/gesture-04-album-dragged.png).

The before/after geometry shows overlapping side artwork becoming separated,
and the time moving from below the outer perimeter onto the progress path.
The active-scrub capture shows the luminous connection from artwork to outer
boundary; the release capture has neither glow nor ball. Curved lines inside
the fixture cover are part of its artwork, not additional UI rings.

Live Spotify/audio, older-macOS material fallback, arbitrary desktop wallpaper
legibility, and actual system Increase Contrast/Reduce Motion/Reduce Transparency settings were
not exercised. The contrast capture uses a named NSAppearance, not a system preference change. SwiftUI exposes those accessibility environment values read-only;
the attempted probe override did not compile and was removed. Reduce Motion
uses a 160 ms dissolve with deformation disabled; those branches were reviewed.
Rust code was not changed and Rust tests were not rerun for this UI task.

## API references

- [Apple: Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)
- [Apple: distortionEffect](https://developer.apple.com/documentation/swiftui/view/distortioneffect(_:maxsampleoffset:isenabled:))
- [Apple: current-process shareable content](https://developer.apple.com/documentation/screencapturekit/scshareablecontent/getcurrentprocessshareablecontent(completionhandler:))

Native APIs supply the glass and pixel distortion. Inferno's shader collection
was reviewed; no dependency was added because its stock transitions did not
match this restrained circular lens behavior.
