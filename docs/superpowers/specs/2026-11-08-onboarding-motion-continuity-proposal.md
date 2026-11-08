# Onboarding motion continuity — proposed

Status: approved. The user selected the recommended carry-record treatment with “proceed” after reviewing the demo. Native implementation is authorized.

Subsequent user requirement: remove all app Reduce Motion support, its alternate paths and tests. The preference-specific requirement below and the preview's toggle are historical; the app now uses the standard motion path. The visual handoff design otherwise remains in force.

## Requested behavior

The user wants the small library vinyl to remain small through Start listening and Ready to play, with a fluid transition into the main player. Preserve the approved Aurora, glass, artwork, permission list and native player design. The user previously required a demo before visual design changes and only tests related to the change.

## Observed causes

- `StartupView` limits only library steps to 0.55; playback and completion allow 0.88. `StartupWindowLayout.useStep` updates the scale after the step changes, while the view's animation observes the step rather than the resulting scale. The 110-point record can jump to 176 points in a separate transaction.
- `PlayerRootView` inserts a separate player record while fading the whole setup surface. Two different records, sleeves and surfaces are visible together. Matching record centers does not preserve visual identity.
- `PlayerWindowController` seeds the incoming player from its compact layout, then changes its layout, scale and window envelope. Screen bounds may also clamp its destination.
- The root opacity animation, window spring and fixed onboarding cleanup timer run independently. Waiting for the initial record animation, already implemented, does not coordinate this subsequent handoff.

## Treatments demonstrated

1. **Carry the record — recommended.** Keep the record small and anchored through library, playback and completion. After the full completed pose and its brief acknowledgement, retain one visible record. Fade the setup copy, pocket and Aurora away while revealing the player's surface and controls around it. Gently resize the record once to its normal player diameter, using the precomputed destination. Resolve the record material locally at that position, rather than overlapping complete windows.
2. **Quiet fade.** Keep setup compact, fade it out, then reveal the player. Simpler and low motion, but introduces a visual break instead of preserving an object across the transition.

The demo also includes an illustrative reference for the current enlargement and double-record crossfade.

## Native behavior if the recommended treatment is approved

- The welcome may retain its approved larger hero. Library, playback and completion share the compact cap, including direct playback setup and fast returning-user completion. Keep the measured center and size until the final handoff; do not expand solely to acknowledge completion.
- Keep the existing actual-animation settlement gate and brief success acknowledgement. Additional idle time is not the proposed fix.
- Capture the settled source rectangle. Compute and clamp the final player rectangle before revealing it. Freeze the destination during the handoff so attention/layout changes cannot retarget it halfway through.
- One normalized progress coordinates record geometry, setup disappearance and player appearance. Prefer a soft non-bouncing curve, approximately 500–650 milliseconds, tuned by native capture rather than treating this study's timing as an Apple specification.
- The setup and player must never display two full-opacity records simultaneously. Keep the incoming record hidden while the shared record owns the handoff, then transfer ownership at identical geometry.
- Use an invisible native union envelope to avoid clipping. Remove setup and commit final native bounds on actual animation completion, rather than a parallel fixed 650-millisecond timer. Preserve generation guards and bounded recovery for missing or hidden presentations.
- Reduce Motion uses a short stationary crossfade with no scaling, spatial travel or spin. Respect a setting change during a transition, hide/reopen, sign-out and readiness loss.
- Keep dynamic per-step content sizing without scroll, clipped controls, or moving the header unexpectedly. Native checks must distinguish content reflow from an unintended artwork enlargement.

## Demo and checks

`build/demos/onboarding-motion-20261108/index.html` is a local, account-free illustrative preview with Replay, timeline scrubbing, step shortcuts, half speed and Reduce Motion. It reuses `site/assets/vinyl.png`; the remaining UI is an approximation, not a replacement native design. Production Swift source has not changed for this proposal.

Browser verification completed: stable 0.55 record scale at library, playback, connecting and completion; stationary reduced-motion handoff; one visible record during the recommended handoff; alternate treatment selection; keyboard Replay activation; no horizontal overflow at 430 pixels; no JavaScript errors. Accessibility audit reported zero violations and seven SVG text contrast nodes requiring manual review; the desktop screenshots were inspected, but this does not establish native app accessibility. `recommended.mp4` is the validated 12.5-second H.264 recording. Native application checks will follow implementation after approval; no app test suite was run for this preview-only work.

## Research

- [Apple Human Interface Guidelines: Motion](https://developer.apple.com/design/human-interface-guidelines/motion), accessed November 8, 2026: use purposeful, brief feedback, preserve comfort and respect accessibility settings. The proposed timings are local design choices, not prescribed HIG values.
- [WWDC24: Enhance your UI animations and transitions](https://developer.apple.com/videos/play/wwdc2024/10145/): recognizable shared elements strengthen continuity; coordinated animation across AppKit and SwiftUI can preserve motion. Its navigation zoom examples are not a drop-in solution for this custom macOS panel.
- [WWDC23: Wind your way through advanced animations in SwiftUI](https://developer.apple.com/videos/play/wwdc2023/10157/): coordinated phases and tracks suit multi-step effects. One underlying transition progress is sufficient here; no new animation library is needed.
