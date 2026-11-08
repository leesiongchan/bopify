# Restore library onboarding continuity

The user explicitly requested main's compact library vinyl and access list, removal of visible library-sign-in cancellation, completion only after the full record animation, and continuous sign-in/permission redirection. Preserve the established artwork, glass, dynamic sizing and Soloist-only playback. Run only related tests. Do not restart the user's app, inspect credentials or exercise their Spotify session.

## Implementation

- Restore the four permission rows and the library record's 0.55 scale cap. Keep measured content sizing, reserving outgoing space through the shrink animation so the form cannot clip.
- Remove library cancellation from the status menu and onboarding, including its unused localized menu title. Preserve internal cancellation for lifecycle safety and unrelated playback authorization cancellation.
- Give each completion a UUID. The record signals when lift, flip, tilt and upright rotation have settled; only then start the success pause and player handoff. Ignore stale callbacks. Hidden views and Reduce Motion finish without waiting for invisible animation. A bounded three-second recovery prevents a missing callback from trapping setup.
- Prepare library consent for any saved Client ID needing access, including first approval; continue in the Spotify sign-in tab. Recheck session/client generations before handing URLs onward. Passive restore never opens consent.
- Client ID field placement remains unchanged pending the user's answer. A user without a Client ID must still register it before library consent can be constructed.
- Final review reproduced a hidden first-half flip leaving the reopened record edge-on. Hiding/disappearing now atomically resolves the intended face and invalidates the interrupted callbacks; a mounted native geometry regression fails before this repair and passes after it.

## Verification

- Animation gate regression failed before implementation; focused motion/animation checks pass (22 tests).
- Consent continuity regression failed before implementation; authorization suite passes (20 tests).
- Layout/library checks: 16 tests passed after awaiting the observable resize and expressing the exact 421-point target as a CGFloat. No geometry expectation was relaxed.
- Final combined run: 77 tests in eight related suites passed (`/tmp/bopify-continuity-final.log`). Native library/help layout passed separately (`/tmp/bopify-continuity-native.log`); its early handoff-position assertion was corrected to measure at the actual handoff boundary, after the requested full entrance finishes.
- Actual native completion: animation settled at 13:13:55.467; handoff began at 13:13:55.817 and completed at 13:13:56.470. The native case did not use timeout recovery. The timeout message later in the combined log belongs to its deliberate missing-callback regression.
- Inspected captures: library and help in `build/test-artifacts/onboarding-composited/B4546DF2-EB3D-4D02-BDF9-7FFF1A143273`; completion/handoff/player in `build/test-artifacts/onboarding-composited/27D1AF58-A7C4-4CF8-8967-901A66B1E705`. Native fixtures omit the production app's Metal library and some player localization resources; they establish layout and transitions, not full production resource fidelity.
- Interrupted-flip follow-up: 23 focused record/motion checks passed (`/tmp/bopify-hidden-record-flip-green.log`), including the new actual native geometry regression. The earlier 77 checks passed before this final lifecycle repair.
- Final native completion recheck passed after the interruption repair (`/tmp/bopify-continuity-final-native-check.log`); actual record callback still precedes handoff by 350 milliseconds, without timeout recovery.
- Final release build 1.6.0 (467) and strict signature verification passed: `build/onboarding-continuity-final-20261108/Build/Products/Release/Bopify.app`. No automatic launch or running-app replacement occurred. Browser continuity is verified through the real authorization interfaces with test callbacks; no live Spotify approvals were exercised. Final diff check passed.
