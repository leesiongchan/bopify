# Playback recovery verification

Verified on macOS arm64 with Xcode/Swift 6.4; final review fixes checked on 2026-10-09. Automated app probes use invented tracks, in-memory credentials, and fake managed engines; they never authorize Spotify or change system networking.

## Results

| Check | Result | Evidence |
| --- | --- | --- |
| `./scripts/prepare-librespot.sh` | Passed: pinned patch verified | Tool output |
| `cargo test --manifest-path rust/Cargo.toml` | 51 passed | `/private/tmp/bopify-recovery-native-green.log` |
| `cargo test --manifest-path .build/librespot-939dc5e/Cargo.toml -p librespot-connect` | 44 unit tests + 1 doctest passed | `/private/tmp/bopify-recovery-connect-green.log` |
| `cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings` | Passed; pinned upstream authentication lint expectation warning remains | `/private/tmp/bopify-recovery-clippy.log` |
| `./scripts/build-rust.sh` | Passed: static framework and generated C header rebuilt | `/private/tmp/bopify-recovery-build-rust.log` |
| `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-recovery-tests` | 294 passed: playback 155, library 56, domain 28, auth 55 | `/private/tmp/bopify-recovery-terminal-swift-green.log` |
| Debug app build | Passed | `/private/tmp/bopify-recovery-app-baseline.log` |
| Release app build, code signing disabled | Passed | `/private/tmp/bopify-recovery-release.log` |
| Recovery app probe | Passed: lifecycle, presentation, and stress checks | `/private/tmp/bopify-recovery-final-probe.log` |

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

## Scope exceptions

`cargo fmt --manifest-path rust/Cargo.toml --all --check` still fails on pre-existing formatting in startup, logging, queue, radio, remote, and older Spirc sections. Feature-owned Rust additions were formatted; unrelated sections were retained. Log: `/private/tmp/bopify-recovery-fmt.log`.

Plain `git diff --check` flags the single-space context prefix inside the unified patch text. Source whitespace is checked with `git diff --check -- . ':!rust/patches/librespot-queue-selection.patch'`; patch application is verified by `prepare-librespot.sh`. The complete diff also passes `git -c core.whitespace=-blank-at-eol diff --check`.

Older visual/library/mirror probes refer to removed fixtures and APIs. The focused recovery probe covers the affected player and library invariants without repairing those unrelated fixtures.

## Review decisions and costs

One independent read-only whole-branch review found five Important issues and one Minor. The five Important issues, plus the menu selector collision discovered during verification, were fixed in one regression-tested pass. The full Swift suite, Debug/Release builds, 16 captures, actual compact menu dispatch, and 100-replacement app stress all passed after that pass. Live service behavior remains pending.

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
- Keep the existing `now-playing` checkout under the user's approved inline execution scope: merge/push integration remains deferred to the user.

Deferred minor: expanded reauthorization repeats Reconnect Spotify in message and action rows; two-row status presentation reduces the small library viewport. No live acceptance or native memory guarantee was inferred from the review.

## Pending live acceptance

Live Spotify playing/paused disconnects, real network return and sleep/wake, remote-device takeover before/during recovery, zero volume/options against the live service, and playback beyond initial OAuth expiry remain pending. No real reconnect/resume latency, uninterrupted audio guarantee, or more-than-one-hour observation is claimed. The implementation recreates a terminal session and retries transient failures; it cannot keep audio connected during an outage or prevent Spotify from revoking credentials.
