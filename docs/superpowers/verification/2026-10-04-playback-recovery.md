# Playback recovery verification

Verified on macOS arm64 with Xcode/Swift 6.4; final live network, sleep/wake, device-handoff, and test checks completed on 2026-10-11. The presentation/stress probe uses invented tracks, in-memory credentials, and fake managed engines. The separate live probe uses the saved playback grant and real Spotify sessions. Neither changes system networking.

## Results

| Check | Result | Evidence |
| --- | --- | --- |
| `./scripts/prepare-librespot.sh` | Passed: pinned patch verified | Tool output |
| `cargo test --manifest-path rust/Cargo.toml` | 52 passed | `/private/tmp/bopify-network-boundary-green.log` |
| `cargo test --manifest-path .build/librespot-939dc5e/Cargo.toml -p librespot-connect -p librespot-playback` | 46 Connect + 4 playback unit tests + 1 doctest passed; 103 native tests including wrapper | `/private/tmp/bopify-recovery-final-native-tests.log` |
| `cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings` | Passed; pinned upstream authentication lint expectation warning remains | `/private/tmp/bopify-audio-recovery-clippy.log` |
| `./scripts/build-rust.sh` | Passed: static framework and generated C header rebuilt | `/private/tmp/bopify-network-boundary-build-rust.log` |
| `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-recovery-tests` | 294 passed: playback 155, library 56, domain 28, auth 55 | `/private/tmp/bopify-recovery-terminal-swift-green.log` |
| Debug app build | Passed | `/private/tmp/bopify-recovery-app-baseline.log` |
| Release app build, code signing disabled | Passed | `/private/tmp/bopify-recovery-release.log` |
| Recovery app probe | Passed: lifecycle, presentation, and stress checks | `/private/tmp/bopify-recovery-final-probe.log` |
| One-row presentation regression and recovery stress | Passed after observing old-layout failures | `/private/tmp/bopify-recovery-polish-green.log` |
| Physical network loss/return and sleep/wake | Passed: 50-second outage, automatic resume 3 seconds after wake, settings restored | `/private/tmp/bopify-live-recovery-detached.log` |
| Final live device-handoff and secondary-owner cleanup | Passed; process exited zero | `/private/tmp/bopify-live-recovery-final-handoff.log` |
| Long live observation beyond initial grant expiry | Seven unrequested losses recovered to matching local playing in 3–4 seconds over 13 hours | `/private/tmp/bopify-live-recovery-detached.log` |

App build commands:

```sh
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-recovery-build build
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-recovery-release build CODE_SIGNING_ALLOWED=NO
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-recovery-build --output /private/tmp/bopify-recovery-final --probe recovery
```

## Exercised behavior

The coordinator tests use a fake monotonic clock. They verify immediate replacement, retry jitter bounds and cap, 20-second readiness timeout, 60 uninterrupted seconds before resetting backoff, offline/sleep suspension, coalesced retry/network/wake signals, and no rebuild on healthy wake. They suspend token lookup, native create, readiness, and shutdown independently. They verify late-create destruction, one forced refresh after rejection, retention of that budget through network retries, and terminal authorization/capability errors.

Final review regressions reproduce and verify four state transitions: remote readiness clears the old terminal error and enables explicit Play here, including a trackless foreign owner; network changes preserve rejected-credential and Premium errors; confirmed explicit playing/paused events clear unavailable restoration and replace the obsolete interruption snapshot; and repeated ready-then-dead sessions back off even when every creation succeeds. Each regression was observed failing before its fix, then passed with the full Swift suite.

Native fixtures verify foreign ownership even with no reported track, unavailable restoration without fallback, paused restoration, matching occurrence requirements, one automatic resume with confirmed playback before readiness, preservation of raw provider/UID/queue data, delayed autoplay context overlay, and ownership changes before activation. These are offline boundary fixtures, not live Spotify acceptance results.

App composition checks keep the same player object, presentation mode, artwork cache, library contents, and library grant across engine loss. Radio requests route to the replacement. Initial network failure retries cold launch without opening a browser. Sign-out and quit reject late native creation. Quit cancels pending browser consent while retaining saved grants; sign-out clears both stores.

The stress probe performs 100 successful replacements and 10 failed creates, using Retry now to accelerate the lifetime checks. Automatic delay behavior is verified separately by fake-clock tests. It records maximum one live fake managed engine and one create, verifies stream termination before replacement, ignores old playback/volume/queue-target inputs, and checks teardown of every engine. Event-consumer ownership is also guarded by the model's single task slot and epoch checks. This does not measure native runtime memory or Spotify recovery latency. Successful native C handles retain small shells by the existing destroy contract; runtime/audio/callback resources are reclaimed, but total handle memory is not claimed to be bounded.

## Presentation evidence

Sixteen captures cover `compact`, `expanded`, and `queue` in `before`, `reconnecting`, `offline`, `unavailable`, and `reauthorization` states, plus a compact permanent-error state. Captures are in `/private/tmp/bopify-recovery-final`; exploratory captures are in `/private/tmp/bopify-recovery-app-red`.

The probe waits for the existing window animation to settle before recording the baseline. It then asserts identical frames across loss and recovery states: compact 142×142, expanded/queue 484×300 on the available display. It checks frozen display position against a future timestamp, disabled Play, accessible Retry now/Reconnect Spotify actions, and blocked Space/next/seek/volume commands while detached. Screenshots were visually inspected for fit and retained record/sleeve geometry. Now Playing mapping tests verify release while unready and reclaim after local readiness; the app's media-command handler also checks readiness before dispatch.

Review found clipping that the original frame/accessibility assertions missed. The compact menu now honors its 94-point capsule proposal, uses a short Retry now caption for unavailable restoration, truncates longer captions, and displays an icon for permanent errors. The full explanation remains available in the menu and accessibility text. Compare `compact-unavailable-before-fix.png` with `compact-unavailable.png`. The native-width assertion first failed with an actual width of 106 points.

Invoking the actual menu action also exposed an Objective-C selector collision: `#selector(Handler.perform(_:))` selected the inherited `performSelector:` overload and crashed. The distinct `performRecoveryAction:` handler is checked by selector, target, native action dispatch, and the resulting factory request. The pull-down's hidden title item is excluded from action selection.

The compact native menu explicitly sets its accessibility name and exposes a keyboard action. AppKit takes a pull-down image from the first menu item, per [Apple NSPopUpButton documentation](https://developer.apple.com/documentation/appkit/nspopupbutton). Proposed sizing uses [Apple NSViewRepresentable.sizeThatFits documentation](https://developer.apple.com/documentation/swiftui/nsviewrepresentable/sizethatfits(_:nsview:context:)); a plain container resizes the native control according to [Apple NSView autoresizing behavior](https://developer.apple.com/documentation/appkit/nsview/autoresizessubviews). This checks accessibility attributes and action dispatch; a full manual VoiceOver listening session remains pending.

The follow-up polish removes the duplicate Reconnect Spotify label in expanded/queue modes and puts the remaining status and action on one row. The accessibility regression first failed against the old layout: status/action centers differed by 18 points, and reauthorization exposed an extra static label. It then passed against the new layout, alongside all 16 captures and the replacement stress check. Before/after evidence: `/private/tmp/bopify-recovery-polish-before`, `/private/tmp/bopify-recovery-polish-after`; logs: `/private/tmp/bopify-recovery-polish-red.log`, `/private/tmp/bopify-recovery-polish-green.log`.

Visual inspection confirms that the reconnect row leaves more room for the library and keeps its action visible. A long restoration explanation truncates to one line, with its complete text retained in accessibility and a tooltip. These use [Apple lineLimit documentation](https://developer.apple.com/documentation/swiftui/view/linelimit(_:)) and [Apple help documentation](https://developer.apple.com/documentation/swiftui/view/help(_:)).

## Scope exceptions

`cargo fmt --manifest-path rust/Cargo.toml --all --check` still fails on pre-existing formatting in startup, logging, queue, radio, remote, and older Spirc sections. Feature-owned Rust additions were formatted; unrelated sections were retained. Log: `/private/tmp/bopify-recovery-fmt.log`.

Plain `git diff --check` flags the single-space context prefix inside the unified patch text. Source whitespace is checked with `git diff --check -- . ':!rust/patches/librespot-queue-selection.patch'`; patch application is verified by `prepare-librespot.sh`. The complete diff also passes `git -c core.whitespace=-blank-at-eol diff --check`.

Older visual/library/mirror probes refer to removed fixtures and APIs. The focused recovery probe covers the affected player and library invariants without repairing those unrelated fixtures.

## Review decisions and costs

One independent read-only whole-branch review found five Important issues and one Minor. The five Important issues, plus the menu selector collision discovered during verification, were fixed in one regression-tested pass. The full Swift suite, Debug/Release builds, 16 captures, actual compact menu dispatch, and 100-replacement app stress all passed after that pass. The Minor presentation issue was subsequently fixed under the user's follow-up instruction, with the regression and visual checks above.

- Use the focused recovery probe when older preview/interface fixtures do not compile: narrower baseline visual coverage.
- Verify library, radio, sign-out, and quit in that probe when older library/mirror fixtures do not compile: broad historical mirror visual checks remain unavailable.
- Add credential-preserving `cancelPendingWork` to cancel pending browser consent on quit: a broader authentication API.
- Format feature-owned Rust while preserving unrelated baseline formatting: the repository-wide formatting gate remains red.
- Validate the unified patch by application and source checks: patch-text whitespace relies on application validation.
- Preserve pre-existing cold-launch trackless-device fallback; recovery still recognizes any foreign active owner: existing cold-launch behavior can remain surprising.
- Preserve supplied raw queue/occurrence/provider data without promising unloaded context pages or shuffle history: later unloaded history/order may differ.
- Retain native handle shells under the existing destroy contract: small handle allocations accumulate; native memory is not bounded or measured.
- Keep unrelated formatting and obsolete broad visual fixtures outside this change: the formatting and historical visual coverage costs above remain.
- Accelerate app resource stress with Retry now and verify automatic timing with a fake clock: the app stress run does not measure real automatic retry timing.
- Keep the existing `now-playing` checkout during implementation: the user subsequently authorized the follow-up polish, live acceptance, and integration. No remote is configured; integration can only be local.

The previously deferred Minor is resolved. No native memory guarantee was inferred from the review or live session.

## Native output cancellation

The long live run exposed a shutdown that spanned system sleep. Code inspection found two output waits that could not observe player teardown: Rodio backpressure while the audio consumer stalls, and drain-on-stop. The player now shares an out-of-band cancellation flag with its sink and signals it before closing commands and joining the player thread. Both waits observe cancellation; normal stop still drains output. Runtime/audio joins and the C callback lifetime contract remain intact.

Four boundary regressions cover stalled drain, stalled backpressure, normal draining, and signalling before the player-thread join. The cancellation and ordering regressions were observed failing before their fixes, then all four passed. Logs: `/private/tmp/bopify-audio-teardown-red.log`, `/private/tmp/bopify-player-teardown-red.log`, `/private/tmp/bopify-audio-teardown-green.log`. Patch preparation, wrapper tests, pinned Connect tests, clippy, framework rebuild, Debug/Release builds, and the 16-capture/100-replacement UI probe passed after the fix. An independent read-only review found no Important issue in the cancellation ordering or physical probe.

This removes two demonstrated uninterruptible waits. No stack was captured from the earlier hold, so its exact blocking site is unknown. Other native teardown operations, including loader joins and CoreAudio disposal, are not covered by a universal deadline guarantee.

## Connection loss versus device handoff

The fresh physical-network run confirmed local playing before a 35-second outage, then a replacement engine becoming locally ready but paused. Its 90-second playing assertion failed; cleanup restored captured settings and stopped the engines. Evidence: `/private/tmp/bopify-live-recovery-physical-fresh.log`. This reproduces a real failure beyond the original unattended run.

Inspection found that `SessionDisconnected` represented both connection cleanup and ordinary ownership loss. Translating both to an inactive device cleared the resume checkpoint before terminal supervision. The native boundary now carries a connection-loss flag: unexpected exit and an empty owner report terminal loss before cleanup awaits; a foreign owner and explicit disconnection retain ordinary inactivity. The existing terminal reporter suppresses subsequent cleanup events. The Rust–Swift wire format and C ABI remain unchanged. Empty ownership means playback ownership was lost; it does not establish that the transport was dead.

The wrapper regression failed before the fix with four delivered events instead of one, then passed. The native fixture exercises the actual disconnect method with an invalid cleanup header, causing failure before HTTP. Removing early notification made the terminal fixture time out; restoring it passed. A negative fixture verifies ordinary disconnection does not report terminal loss. Full coverage is now 52 wrapper tests, 46 Connect tests, 4 playback teardown tests, and 1 Connect doctest. Evidence: `/private/tmp/bopify-network-boundary-red.log`, `/private/tmp/bopify-network-boundary-green.log`, `/private/tmp/bopify-network-disconnect-fixture-red.log`, `/private/tmp/bopify-audio-recovery-connect-green.log`.

Safe diagnostics record paused/end-of-track/ownership events with engine epochs and, in the live probe, checkpoint activity/resume intent plus separate URI/UID/context match verdicts. No identity values are printed. The tool-owned post-fix probe subsequently disappeared: its terminal session was unavailable, no helper process remained, and its log contained no network-outage event. That user-performed outage cannot be counted as accepted. The earlier diagnostic startup run was stopped without claiming network acceptance; its log is retained as `/private/tmp/bopify-live-recovery-network-diagnostic-pre-fix.log`.

The replacement probe runs detached from the tool terminal, with stdin connected to `/private/tmp/bopify-live-recovery-control.fifo` and diagnostics written to `/private/tmp/bopify-live-recovery-detached.log`. Its launcher exited and process inspection verified macOS had adopted the still-running helper (parent PID 1). It confirmed local playing and paused/playing replacement before awaiting the physical network step. During the following 13 hours it recorded seven unrequested session losses, each returning to local playing in 3–4 seconds with URI, UID, and context match verdicts true. The initial grant expired at 03:45:13 UTC; the first subsequent recovery completed at 04:01:42 UTC. These observations verify recovery after initial grant expiry, but do not claim uninterrupted audible output or the separate 65-minute mode's persisted-grant comparison.

On 2026-10-11 at 00:36:18–00:37:08 MYT, this helper recorded a 50-second physical network outage and return with local playing at epoch 10. Confirmation passed both network assertions at 00:40:03 MYT. This outage did not require replacing the healthy engine. Actual sleep at 00:50:50 MYT injected the probe's controlled loss; wake arrived at 00:51:13, and the replacement became ready/local/playing at 00:51:16, epoch 11. Track identity matched and volume remained zero. All physical assertions passed, captured playback options and position were restored, and native engines stopped at 00:51:39. The log ends with `PASS: physical network and sleep recovery acceptance complete`.

## Live acceptance

The probe refreshed an expired saved grant, restored a paused occurrence and position without auto-resuming, preserved zero volume and repeat-track, and automatically resumed a playing occurrence after terminating its own native engine. A second controlled Connect client verified foreign ownership both before and during replacement.

The first run timed out when the probe shut down the secondary client before requesting transfer back to the primary. Keeping that client alive until transfer completes resolved the probe ordering issue. Review also found that this failure path skipped restoring temporary settings when the secondary owned playback. Cleanup now retains both models, restores through the active controlled player before shutdown, and reports restoration failure explicitly. The targeted `--cleanup-check` regression passed on 2026-10-10 at 01:04 MYT against the rebuilt native library, including expired-grant refresh, paused/playing replacement, ownership checks, and restoration of options and position through the active secondary client. Evidence: `/private/tmp/bopify-live-recovery-cleanup.log`. The same check passed again against the final connection-loss fix on 2026-10-11 at 00:52:34 MYT and exited zero. It preserved the controlled other owner before and during replacement and restored settings through that active secondary client. Its saved grant expiry was 17:09:07 UTC, later than the long probe's initial expiry of 03:45:13 UTC, confirming refreshed authorization persisted. Evidence: `/private/tmp/bopify-live-recovery-final-handoff.log`.

The original long run recorded 65 minute samples with ready/local/playing state, all at epoch 5. Samples 54–65 were after the initial OAuth expiry. Its final replacement did not pass: shutdown spanned a long sleep interval, readiness returned after full wake, and the recovered player did not meet the playing assertion. The process exited 77. macOS power logs record maintenance Sleep/DarkWake cycles around 02:42 MYT on October 9 and FullWake at 18:44:43, immediately before replacement completed. Elapsed wall time includes system sleep and is not evidence of a runnable 16-hour deadlock. Evidence: `/private/tmp/bopify-live-recovery.log`, `/private/tmp/bopify-live-recovery-power.log`.

Natural-expiry observation followed by successful recovery against the final fixes is now covered by the detached 13-hour run above. The dedicated 65-minute mode was not rerun: its original failed result remains recorded separately. Path-change samples and readiness transitions establish observed state, not uninterrupted audible output. The seven losses were unrequested; their exact native causes were not classified in this probe's log, and their timing does not demonstrate an hourly replacement policy.

The physical probe uses the production `PlaybackConnectionMonitor` and an AppKit event loop. It independently records host-network and workspace sleep/wake notifications. During actual sleep it also injects a controlled session loss into its own coordinator, so the wake check verifies replacement and automatic local resume. The first physical run stayed at its network prompt overnight. On 2026-10-10 at 10:42 MYT it recorded a 45-second host-network outage and return. After confirmation, the playing-state wait timed out and cleanup could not confirm restoration of all captured settings; it exited 77. It had recorded ready/local/paused state earlier in the unattended interval. This is a failed acceptance run, not a verified reconnection. Evidence: `/private/tmp/bopify-live-recovery-physical.log`. The fresh pre-fix failure is recorded in `/private/tmp/bopify-live-recovery-physical-fresh.log`; final network and sleep/wake acceptance passed in the detached run described above.

Both clients belong to the probe, and neither requests takeover from an unrelated owner. The runner prints fixed diagnostics and grant expiry metadata, never credential values, track identities, or authorization URLs. Cleanup stops both engines, retains saved authorization, and attempts to restore captured local options and position. The probe plays at zero volume; a manual listening/VoiceOver check is separate.

```sh
python3 docs/superpowers/verification/run-live-recovery-probe.py --derived-data /private/tmp/bopify-recovery-build --output /private/tmp/bopify-live-recovery
python3 docs/superpowers/verification/run-live-recovery-probe.py --derived-data /private/tmp/bopify-recovery-build --output /private/tmp/bopify-live-recovery-cleanup --cleanup-check
python3 docs/superpowers/verification/run-live-recovery-probe.py --derived-data /private/tmp/bopify-recovery-build --output /private/tmp/bopify-live-recovery-physical --physical-check
```

Native replacement is a controlled engine termination against real Spotify; it does not reproduce a spontaneous AP/dealer outage. Offline/sleep signals and retry timing are also covered by coordinator tests. The implementation recreates terminal sessions and retries transient failures; it cannot keep audio connected during an outage or prevent Spotify from revoking credentials.
