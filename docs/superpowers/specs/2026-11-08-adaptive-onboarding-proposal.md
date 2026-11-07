# Adaptive windows and a shared onboarding journey

Status: proposed. The user requested dynamic sizing, richer vinyl motion, and a consistent first-time/returning experience. The isolated preview is ready; the entry point for returning users is still an open behavior choice. Application source is unchanged from 5d224e5.

Preview: `build/onboarding-adaptive-demo/index.html`. It includes first-time/returning simulation, full-flow playback, per-step inspection, two motion options, a short-screen mode and Reduce Motion. This is browser approximation, not native Liquid Glass or live Spotify behavior.

## Proposed window behavior

Keep the width, top edge and vinyl size stable. Measure the current form's natural content height and animate the bottom edge to fit, with consistent padding and no scrolling. Expanding windows make room before new controls fade in; shrinking follows removal of outgoing content. Short-lived automatic statuses should be coalesced rather than repeatedly resizing the window. Timings in the preview are illustrative, not extra waits to impose on real readiness.

The current fixed 680 pt request/minimum and mode-only update guard need to be replaced together. Measure inside the existing native host before its filling frame; allocated window height must never be fed back as content height. One window owner applies the result, rejects stale stage measurements and ignores sub-point differences. Keep PlayerWindowController responsible for the final handoff.

Vinyl scale must come from available screen constraints rather than the changing step height. Otherwise shorter steps would shrink the artwork again. Continue to bound the root to its true viewport and retain the previous source frame only during handoff.

## Vinyl motion options

1. Recommended physical treatment: a restrained light sweep over the grooves, slight pointer-responsive lean/idle poise, gradual spin-up while work runs, then an upright settle. Keep the original artwork and readable foreground still.
2. Quieter idle treatment: retain the light sweep, omit idle poise and pointer tilt. Work-related spin remains purposeful feedback. Both modes have a static reduced-motion alternative.

The preview retains a single record DOM instance through every step and into the illustrative player. Decorative motion stays outside form measurement. The native implementation should pause work while hidden and preserve the existing stable record anchor.

## First-time and returning users

Use the same visual components, motion, step hierarchy and automatic completion. Saved grants, Client ID, Soloist key and SDK session are reused; valid steps advance without repeat entry. Shared presentation must not cause browser consent on launch, relax account/device proof, interrupt playback or reinstall a usable SDK.

Open choice: show the brief shared automatic check on every returning launch, or invoke the shared journey only when setup needs attention/is reopened. The preview can demonstrate returning presentation under either entry policy; it does not decide startup behavior.

Existing interactive returning sign-in combines previously approved consent in one browser visit. That authentication optimization can remain while presentation is shared; making the visuals consistent does not require repeating consent.

## Research, 2026-11-08

- [Apple Motion](https://developer.apple.com/design/human-interface-guidelines/motion): use purposeful, precise feedback and provide reduced-motion behavior. The proposed reflection/lean and inertial spin are design choices, not Apple-prescribed effects.
- [Apple Windows](https://developer.apple.com/design/human-interface-guidelines/windows): respect window placement and the surrounding multitasking workspace. Preserving the top edge avoids repositioning the header and artwork as content changes.
- [Apple Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding): keep onboarding quick and contextual. Reuse valid setup and advance on actual readiness rather than imposing delays for animation.

## Observed preview checks

The initial measurement pass covered nine stages. Heights ranged from 412 to 643 px; vinyl width stayed 224 px and the window top stayed 124 px in the browser viewport. Every form fit without scrolling. Both simulated full flows retain the same record instance and complete automatically. Reduce Motion was verified to remove poise/sheen animations, stop queued disc frames, hold the disc upright, and disable window transitions. At a 380 px browser viewport, all nine short-screen scenes and their controls fit; artwork width stayed 126 px and window heights ranged 292–523 px. No browser errors were reported.

No application source, credentials, network pairing or real playback is touched; no application/package/Rust tests or new signed build are part of this proposal-only pass. Native sizing, event-driven restoration and motion need focused verification after the behavior choice is resolved.
