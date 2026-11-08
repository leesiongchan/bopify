# Ready-to-play handoff investigation

User reported being stuck at “Ready to Play” and asked what to do next. Preserve the current visual design, credentials, running playback and earlier uncommitted work; run only related checks.

## Evidence and distinction

The title is ambiguous: both the large onboarding confirmation and the idle main player use “Ready to play.” The player with transport controls/library tabs expects a song selection; the large “Setup is complete” screen must transition automatically. Asked the user which screen they saw. Their process had exited before a read-only current-window inspection, so the actual reported screen is not confirmed.

Safe logs from build 464 show real profile HTTP 429 at the streaming-account stage. Metadata failures remain `servicesUnavailable`; both ready and limited-services states preserve usable local playback. No evidence connects those rate limits to repeated completion resets. Do not modify credentials/scopes or treat a 429 as an authentication failure.

## Reproduced bug and repair

- [x] Regression: arm setup when usable playback is already true, with no view readiness/auth change. Current implementation failed to auto-complete after three seconds.
- [x] Move readiness observation into `AppEnvironment`: watch arming, auth, lifecycle guards and Soloist readiness; re-register before reconciling. View now only updates the Reduce Motion preference.
- [x] Keep the existing confirmation/handoff timing and library-edit behavior. Add safe lifecycle diagnostics for confirmation, handoff and completion.
- [x] Add a companion-rate-limit regression proving that usable playback still completes setup.
- [x] Change the native handoff test to wait for automatic completion instead of manually triggering readiness.
- [x] Final read-only review: no blocking findings in observation, cancellation, quit handling or unfinished library editing.

## Verification

- RED: `/tmp/bopify-ready-handoff-red.log`, one regression test failed as expected.
- GREEN: `/tmp/bopify-ready-handoff-green.log`, 14 tests in three related suites passed.
- Native: `/tmp/bopify-ready-native-handoff.log`, one handoff test passed. Three actual fixture-window captures visually inspected: completion, handoff and player in `build/test-artifacts/onboarding-composited/99B77007-2EEB-445C-BC9F-293D16230DE6/`.
- Test host lacks the app’s default Metal library/localization resources; captures establish the automatic native transition and anchored record, not production localization/shader fidelity.
- Release build and `codesign --verify --deep --strict` passed. Artifact: `build/onboarding-handoff-fix-20261108/Build/Products/Release/Bopify.app`, version 1.6.0 build 465.
- No real playback command, credential read/reset, or automatic app replacement was performed. Final diff check passed.

The repaired lifecycle race is demonstrated independently. Whether it caused this particular report remains pending the screen clarification. If the user was already in the player, guide them to select a song; do not claim they were blocked by onboarding.
