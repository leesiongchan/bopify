# Vinyl live acceptance — 2026-10-11

Status: Partial. The profiling evidence was merged into `main` at `d230991`. A fresh build of the actual menu-bar app exercised saved Spotify authorization and locally enabled controls. This pass does not close the acceptance checklist in the [design spec](../specs/2026-10-11-vinyl-pressing-and-motor-design.md#verification-and-acceptance).

## Verified observations

| Check | Evidence |
| --- | --- |
| Native app build | `xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-vinyl-merged-build build` exited 0. |
| Package regression suite | All 314 tests passed before and after the merge: 175 playback, 56 library, 28 domain, 55 authentication. The post-merge run used `--skip-build`; package and production sources were unchanged by the documentation merge. |
| Live session restoration | The actual app restored a paused session. Play, Previous, and Next were enabled before playback commands; the driver required this local-control guard. |
| Play/Pause | Accessibility actions changed the UI phase to Playing and back to Paused. A later paused position of seven seconds corroborated position advancement; audio output was not independently recorded. |
| Paused record | Two window screenshots taken one second apart after settling were byte-identical. This verifies the captured appearance stayed still, without measuring timeline callbacks. |
| Pointer scrub while paused | A quarter-turn drag followed by release advanced the displayed position by 15 seconds. The reverse gesture restored the starting position exactly. |
| Hide/show | The owned panel disappeared from the on-screen window list when hidden, both paused and playing. Reopening during playback retained the displayed track identity and Playing phase. |
| Session cleanup | A separate final check confirmed Paused at 0:00, matching the initial paused position. The supervised test app was then terminated. |

The compact and expanded player screenshots were inspected visually. The pressing, artwork label, spindle, grooves, and expanded transport controls rendered. Screenshots and dynamic track/account text remain outside the repository; the [retained results](assets/vinyl-live-2026-10-11/results.json) contain control states, position deltas, failures, and screenshot hashes only.

## Limits and remaining checks

The temporary accessibility/event driver did not complete its whole sequence. Keyboard seeking timed out. Expanded controls were intermittently absent after focus or state transitions, and one follow-up control was attempted while track loading still disabled Play. These failures do not establish an app defect. Native Accessibility and event-posting permission checks both returned true. The record's `AXFocused` attribute was not settable, so that alternative could not retain focus.

Next changed the displayed track identity and Previous returned it to the initial title, but the driver did not verify completed loading before continuing. Treat confirmed Next/Previous playback as unverified. A later retry stopped at its local-control guard without issuing another track command. The hide/show run also timed out while waiting for expanded controls after Pause; the separate final restoration check confirmed the paused position.

Still unverified in the real app: scrub and release while playing, end of track, hiding during a brake, system Reduce Motion changes during spin-up/braking, and actual timeline tick termination. Live buffering/recovery also remains open: there is no isolated connection-loss hook in the actual app, and the playback model does not currently receive a real buffering phase event. The existing physical recovery procedure requires a real network interruption and sleep/wake. Neither whole-machine action was performed while other probes were running.

No production behavior changed. Record-specific GPU timing remains subject to the attribution limits in the [GPU report](2026-10-11-vinyl-gpu-profile.md); this UI pass adds no GPU timing claim. The [hitch diagnosis](2026-10-11-vinyl-hitch-diagnosis.md) remains inconclusive about the scheduling cause.
