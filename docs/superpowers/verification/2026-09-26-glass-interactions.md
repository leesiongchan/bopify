# Two-ring Liquid Glass player verification

Checked 2026-09-26 on macOS 27 / Xcode 27. Branch `feat/glass-interactions`, based on `main` at `c1a5587`.

## Implemented

- Outer clear-glass perimeter and inset progress track only; removed decorative grooves and artwork outlines.
- Clockwise progress from six o’clock; remaining time only, centered below the outer perimeter.
- Previous/next artwork horizontally behind the center album, with clear glass and reduced opacity.
- Removed the opaque canvas, ambient gradients, enclosing card, and unused artwork-color extraction. Compact controls use one clear-glass capsule. Older systems retain an ultra-thin material fallback; accessibility contrast/transparency fallbacks remain.
- Album transitions shortened from 720 to 420 ms, with lateral travel; mode/window transitions from 550 to 360 ms.
- Scrubber hidden until a 250 ms stationary hold; a 22 pt ball appears, updates while dragging, commits one seek on release, then fades away in place.
- Album hold of 250 ms shrinks to 94%; elastic dragging left by at least a quarter of its diameter commits one next command on release. Short/rightward/unheld drags do not advance.
- Gesture identity includes both track URI and queue occurrence. Track, duration, or device changes cancel active scrubbing; track/control changes prevent stale album skips.

## Verification

- Full Swift suite: **102 passing** (40 Playback, 12 Library, 18 Domain, 32 Auth). The bottom-origin test first failed at all four cardinal points, then passed. Added leftward-release threshold coverage; the new helper was initially absent.
- Command-line app build: exit 0 using `xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-glass-build build`. Xcode emits its supported-platform discovery message; no compiler errors.
- Native pointer probe: [GlassInteractionProbe.swift](GlassInteractionProbe.swift), run in `PlayerPreviews.swift` context. Quick ring click yields no seek; held right commits 75000 ms on a 100000 ms track; left-to-top drag commits 50000 ms. Disabled control or replaced track cancels. Unheld/right/short album drags do not skip; one held left release produces exactly one callback. Replacement metadata before queue and lost control during hold do not skip.
- Review reproduced two regressions: an idle duration/control update swallowed the next hold, and track metadata arriving before its queue allowed a stale album skip. Before the fix, the pointer probe reported missing seeks and two skips; afterward it reports seeks `[75000, 50000, 75000, 90000]`, one skip, and `PASS=true`.
- Artwork cache probe passes coalescing, image publication, 640 px downsampling, failure caching, 112-entry eviction, and clear/reload after palette removal. A temporary assertion-edit typo was corrected back to the existing 112-entry limit before passing.
- Native render previews inspected in dark/light appearance and increased contrast, at expanded 390/410 widths, compact 340, loading without artwork, and queue with 80 rows. Fixed expanded content to fit its existing 560 pt window.
- Native motion captures inspected for next, interrupted next, previous, and expanded/queue handoff. Current artwork remains a single shared overlay.

## Visual evidence

[Light](assets/glass-interactions/light.png), [increased contrast](assets/glass-interactions/increased-contrast.png), [before](assets/glass-interactions/before.png), [expanded after](assets/glass-interactions/expanded.png), [390 pt](assets/glass-interactions/expanded-390.png), [compact](assets/glass-interactions/compact.png), [queue](assets/glass-interactions/queue.png), [missing artwork](assets/glass-interactions/missing-artwork.png).

[Scrubber held](assets/glass-interactions/01-held-scrubber.png), [scrubber released](assets/glass-interactions/02-released.png), [album held](assets/glass-interactions/03-album-held.png), [album dragged](assets/glass-interactions/04-album-dragged.png), [album released](assets/glass-interactions/05-album-released.png).

Xcode preview window backgrounds/title bars are host UI, not the borderless player. Own-process gesture bitmap captures omit composited glass and are evidence of geometry/interaction only; RenderPreview captures establish material appearance. Original vector artwork is fixture content, not extra UI rings.

## Limits

Live Spotify command/audio acceptance, older macOS rendering, actual system Reduce Motion/Reduce Transparency settings, and varied desktop wallpaper readability were not exercised in this pass. The native probe validates the real SwiftUI gesture-to-command callback boundary, not a Spotify session. Rust code is unchanged on this branch and its tests were not rerun.

## References

- [Apple: Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views), checked 2026-09-26.
- [Apple: Composing SwiftUI gestures](https://developer.apple.com/documentation/swiftui/composing-swiftui-gestures), checked 2026-09-26.
