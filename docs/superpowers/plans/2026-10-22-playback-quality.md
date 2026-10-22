# Playback Quality Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` or `superpowers:subagent-driven-development` when implementation is requested. Track the steps with the checkboxes below.

**Goal:** Prefer 320 kbps for Bopify playback and establish a measured, continuity-preserving path to automatic quality selection.

**Architecture:** Ship a fixed 320 kbps preference in the Rust player constructor first. Automatic quality is a separate extension to the pinned librespot player: measure actual audio delivery, choose a future-load bitrate, and preserve the current decoder and Connect session. Network path flags provide data-cost policy, not a bandwidth measurement.

**Tech stack:** Rust/librespot pinned at `939dc5ee9d833e1980f9495241219d9d4868a061`, Tokio, existing C/JSON FFI, Swift 6, Network.framework, Swift Testing.

**Spec:** The research and design brief in this document. Fixed 320 was approved and implemented on 2026-10-22. Auto's policy and dependency patch remain a proposal for later review.

**Fixed-320 verification:** The native Rust test script, Clippy with warnings denied, release XCFramework rebuild, 451 package tests, 170 app tests, and the app build passed with the project-pinned Rust 1.99.0. Live Spotify/audio-hardware playback and selected-format inspection have not been performed.

## Global constraints

- macOS 26+, Apple Silicon; keep the existing librespot revision and audio backend.
- Fixed 320 requires no FFI/schema change, dependency patch, new setting, or playback recovery redesign.
- Treat rates as requested preferences; actual file availability can force a different nominal bitrate.
- Do not change PCM output format, normalization, volume, or gapless defaults to implement compressed bitrate selection.
- Automatic changes apply to future loads; current audio continues. Seamless mid-track representation switching is outside the initial Auto design.
- Never simulate session failure or recreate the Connect device merely to change quality.
- Add no third-party ABR library: this is a small discrete policy around librespot's own file loader, not a segmented-media player.
- Keep logs free of tokens, audio URLs, and private queue identifiers.

## Review focus

- An already loading or preloaded next track may retain the previous configuration (Task 2).
- Repeat-one and same-track resume reuse a decoder instead of loading a new file (Task 2).
- Idle, cached, fully buffered, or preloading transfers must not be mistaken for poor foreground bandwidth (Tasks 3 and 4).
- Reported throughput uses bytes per second despite a misleading dependency log label (Task 3).
- Path changes, pause, sleep, remote playback, and reconnect must not trigger quality oscillation or take playback ownership (Tasks 4 and 5).

## Verified findings

| Area | Evidence in the current checkout |
| --- | --- |
| Current preference | `rust/crates/bopify-core/src/engine.rs` passes `PlayerConfig::default()` to `Player::new`. |
| Default and rates | `.build/librespot-939dc5e/playback/src/config.rs` marks `Bitrate160` as default; options are 96, 160, 320. |
| File selection | `playback/src/player.rs:1151` chooses from ordered format lists. 320 preference tries Vorbis 320, MP3 320, MP3 256, Vorbis 160, MP3 160, Vorbis 96, MP3 96. |
| Runtime control | No bitrate command/setter exists. Player configuration is cloned into each `PlayerTrackLoader`. |
| Preloading | Player starts preloading about 30 seconds before the end and reuses ready/pending loaders. |
| Same-track reload | Existing playing/paused and repeat-one paths can reuse a decoder; loading the same URI does not force a new representation. |
| Network monitor | `Bopify/Bopify/PlaybackConnectionMonitor.swift` forwards availability and sleep/wake only. |
| Transfer information | `audio/src/fetch/receive.rs` measures CDN delivery; throughput is private, clamped to at least 8192 bytes/s, then averaged. Read waits occur in `audio/src/fetch/mod.rs`. |
| Events | Bopify does not receive throughput, audio-buffer availability, read stalls, or the selected file format. `TrackChanged` carries all available formats, not the chosen one. |
| Recovery configuration | `PlaybackEngineConfiguration` is encoded through `LibrespotEngine` into Rust `EngineCreateOptions`, which rejects unknown fields. Both sides must change together for Auto. |
| Patch preparation | `scripts/prepare-librespot.sh` verifies the exact checked-in patch against the pinned checkout; editing only `.build` is not a reproducible change. |

Upstream documents the three bitrate choices and the 160 default. [librespot Options](https://github.com/librespot-org/librespot/wiki/Options), edited February 4, 2026; checked 2026-10-22.

The project's exact API and default were verified against its pinned local source, rather than assuming current upstream main matches it. [Pinned PlayerConfig source](https://github.com/librespot-org/librespot/blob/939dc5ee9d833e1980f9495241219d9d4868a061/playback/src/config.rs), revision `939dc5e`.

Apple defines `isExpensive` as a potentially costly interface, such as a personal hotspot. It does not state the link's sustainable throughput. [Apple NWPath.isExpensive](https://developer.apple.com/documentation/network/nwpath/isexpensive), checked 2026-10-22.

Apple defines `isConstrained` as Low Data Mode. Use it to respect data policy independently of measured delivery capacity. [Apple NWPath.isConstrained](https://developer.apple.com/documentation/network/nwpath/isconstrained), checked 2026-10-22.

### Feasibility and alternatives

| Approach | Feasibility and cost | Recommendation |
| --- | --- | --- |
| Fixed 320 preference | Small Rust configuration change; supported by the existing pin. | Ship first. |
| Path-based automatic choice | Can choose a rate from Low Data Mode/hotspot flags, but still needs runtime control or disruptive recreation. Fast Wi-Fi can be congested; a hotspot can be fast. | Use as a data-cost cap within Auto, not as a claim of bandwidth adaptation. |
| Measured selection for future tracks | Feasible with a pinned player/telemetry patch, policy, bridge, settings, and tests. | Recommended Auto scope. |
| Seamless switching within a track | No existing API or segmented representation pipeline. Requires reopening a different file, decoder/seek handling, and audio continuity work. | Separate research project; do not promise gapless mid-track switching. |
| Recreate engine whenever conditions change | Existing recovery can reconstruct playback but reconnects the device, changes engine/queue identity, and can interrupt music or interact with remote ownership. | Reject for routine quality changes. |

Nominal payload cost, calculated as kbps × 1000 ÷ 8 × 3600: 320 ≈ 144 MB/hour, 160 ≈ 72 MB/hour, 96 ≈ 43.2 MB/hour. These are decimal MB estimates before protocol overhead, variable encoding, and prefetching. 320 doubles nominal payload relative to the current 160 preference; it needs only about 40 kB/s sustained payload, but latency and delivery variability require headroom.

## Task 1: Ship the fixed 320 kbps default

**Files:** Modify `rust/crates/bopify-core/src/engine.rs` and `README.md`.

**Interface:** No public interface change. In the shared creation path, import `Bitrate` and supply `PlayerConfig { bitrate: Bitrate::Bitrate320, ..PlayerConfig::default() }` to `Player::new`.

- [ ] Replace the inherited preference in the shared constructor so both ordinary and options-based engine creation use 320. Preserve all other fields and `AudioFormat::default()`.
- [ ] Log `requested_bitrate_kbps=320` at engine creation using the existing Rust logger. Describe playback as “prefers 320 kbps when available”; do not label it guaranteed or lossless.
- [ ] Run `./scripts/test-native.sh`, `./scripts/build-rust.sh`, the full package suite, and the native app suite below. This small configuration change needs no new test that merely restates a literal or tests librespot's enum.
- [ ] Smoke-test cold launch, a multi-track playlist, seek/pause/resume, remote transfer, and reconnect using Premium. Record that audio works; requested configuration alone does not prove the selected file's bitrate.
- [ ] If actual-format evidence is needed for release review, inspect the selected `format` at the pinned loader's selection point in a disposable debug build. Record requested versus selected nominal format, then remove the temporary instrumentation. Existing Bopify events cannot prove this.
- [ ] Update README and commit as `feat: prefer 320 kbps Spotify playback`.

Acceptance: every new Bopify engine requests 320, available lower-rate representations still play through existing fallback, all checks pass, and playback/recovery behavior remains intact.

## Optional Auto design

Tasks 2–5 are a separate follow-up, not required to ship Task 1. Proposed menu choices are **320 kbps** (default), **160 kbps**, **96 kbps**, and **Auto**. A fixed choice requests that preference; Auto can choose among all three. A fixed choice overrides Auto's data-cost policy. Quality controls affect Bopify's local playback, not a remote Spotify device.

Keep the decision policy in Rust beside audio measurements. Swift forwards the selected mode and path data policy through the existing bridge. Store the user's mode in UserDefaults, not transient measured bandwidth or a recovered bitrate snapshot. On recreation, reuse the mode and current path policy; discard measurements from the previous engine.

### Proposed policy, to calibrate with measurements

These values are design starting points, not established librespot behavior or measured optimal thresholds:

- Auto starts at 320 on an unconstrained path with no samples. Cap it at 160 on an expensive path and 96 in Low Data Mode. The cap is a data policy, not a speed estimate.
- Use raw, completed foreground audio transfer samples. Convert bytes/s to bits/s with ×8; never use ping time, the dependency's printed “kbps”, or whole-session average traffic as bandwidth.
- Keep at most five eligible samples from the last 60 seconds; estimate capacity as their median. Require at least three samples before a capacity-based decision. Invalidate the window when the network path changes.
- Choose the highest available tier whose nominal rate is at most half the estimated capacity, bounded by the data-policy cap. This gives starting thresholds of 640 kbit/s for 320 and 320 kbit/s for 160; otherwise prefer 96.
- Downgrade when that window selects a lower tier, or when two foreground data-starvation waits of at least 500 ms occur within 30 seconds. A stall-driven change lowers one tier. Exclude waits caused by seeks, startup, pause, sleep, or remote playback.
- Upgrade only after the candidate has remained sustainable for 60 seconds with at least three fresh eligible samples and no starvation. Apply a 60-second minimum interval between capacity-driven changes; data-policy caps can lower the next-load preference immediately.
- With no fresh samples, hold the current target subject to the path cap. Silence while a track is buffered must not become a zero-throughput sample. Exclude cache hits and preload traffic from the first implementation.
- Apply changes on the player command loop. Current playing/paused audio and already-started current-track loads finish with their original representation. Rebuild pending/ready preloads under the new target. A repeated track loads with the new target when it reaches its natural boundary.

This design improves later tracks on weak networks; it does not rescue a stalled current representation immediately. An emergency downgrade/reopen of the same track would be an explicit later feature with audible-interruption acceptance criteria.

## Task 2: Add safe future-load bitrate control to the pinned player

**Files:** Modify `rust/patches/librespot-queue-selection.patch` and the patched `playback/src/player.rs` through the reproducible pin workflow; modify `rust/crates/bopify-core/src/engine.rs`. Keep the existing single-patch verification contract unless a separate patch-stack design is approved.

**Interfaces:** Add `Player::set_bitrate(&self, bitrate: Bitrate)` and `PlayerCommand::SetBitrate(Bitrate)`. Retain an `Arc<Player>` in Bopify's Engine while passing a clone into Spirc. Command success means queued, not that current audio changed.

- [ ] Add failing patched-player tests for updated loader configuration; unchanged current playing/paused decoder; current loading retaining its snapshot; and unchanged Connect/session/queue identity.
- [ ] Add tests for pending and ready preload replacement, repeated identical setter calls, rapid successive changes, and late completion of a discarded preload. Retain/restart the preload URI: merely clearing preload loses the existing “already suggested preload” trigger.
- [ ] Test repeat-one at EndOfTrack after a change. Store the requested bitrate with loaded/state data and bypass stale EndOfTrack decoder reuse; preserve same-track resume behavior during playback.
- [ ] Implement the setter and preload replacement on the player thread. Dropping the old loader receiver already cancels its task through the existing oneshot mechanism; use that mechanism rather than adding a second generic generation system.
- [ ] Regenerate the checked-in patch from the exact pin; run `./scripts/prepare-librespot.sh` and `./scripts/test-native.sh`. Check reproducibility in a disposable clean pinned checkout, including reverse-apply validation.
- [ ] Commit as `feat: support bitrate changes for future track loads`.

## Task 3: Expose trustworthy audio-delivery measurements

**Files:** Extend the pinned patch in `audio/src/fetch/mod.rs`, `audio/src/fetch/receive.rs`, and `playback/src/player.rs`; add `rust/crates/bopify-core/src/quality.rs` and register it in `rust/crates/bopify-core/src/lib.rs`.

**Interfaces:** Define `DeliverySample { bytes: u64, elapsed_ms: u64, observed_at_ms: u64, play_request_id: u64 }` in the Bopify quality module. Add narrowly scoped patched-player telemetry for raw transfer samples and foreground starvation wait durations, associated with the active playback request. Keep the selected nominal file format distinct from the requested tier.

- [ ] Add fixture tests proving 40,000 bytes in 1,000 ms means 320,000 bits/s; a missing sample stays unknown; cached/idle/preload transfers are excluded; a network-path change resets the observation window.
- [ ] Add patched-loader tests for raw samples before the existing clamp/average, monotonic timestamps, cancellation, partial/failed transfers, and starvation waits at the actual read boundary.
- [ ] Publish small aggregated telemetry through the existing player channel, never a callback on every audio sample or a blocking action on the audio read path. Identify the active request so abandoned/preloaded/previous-track samples cannot affect policy.
- [ ] Carry selected format with loaded-track data and emit its nominal rate when it becomes current, not at preload completion. Log requested and effective nominal rate from Bopify's logger; do not infer effective rate from `AudioItem.files`.
- [ ] Run `./scripts/test-native.sh`; require both the Bopify boundary tests and patched dependency tests to pass. Commit as `feat: measure audio delivery for quality selection`.

## Task 4: Implement and verify the automatic policy

**Files:** Extend `rust/crates/bopify-core/src/quality.rs`, `engine.rs`, and `terminal.rs` where shutdown/active-engine ownership requires it.

**Interfaces:** `QualityMode::{Auto, Fixed96, Fixed160, Fixed320}`; `PathPolicy { expensive: bool, constrained: bool }`; `QualityController::set_mode`, `set_path_policy`, and `observe` return an optional new `Bitrate`. Use an injected monotonic clock for tests.

- [ ] Write deterministic failing tests for every threshold/window/cooldown above; fixed overrides; unknown/stale measurements; path reset; Low Data Mode/hotspot caps; pause/seek/sleep; remote inactivity; lower selected file format; and the 96 floor.
- [ ] Add an integration test proving one policy change sends one player command without a new engine/session, queue reload, playHere, or playback recovery event.
- [ ] Implement the policy and subscribe within Engine's existing runtime/lifetime. Cancel it during shutdown and reject telemetry from inactive requests or prior engine lifetimes. Do not upgrade based on reported progress alone.
- [ ] Run `./scripts/test-native.sh` and synthetic delivery traces. Commit as `feat: adapt future track quality to audio delivery`.

## Task 5: Add persisted quality controls and path-policy wiring

**Files:** Modify `Packages/BopifyCore/Sources/BopifyDomain/PlaybackRecovery.swift`, `PlaybackEngine.swift`, `PlaybackEvent.swift`, `Packages/BopifyCore/Sources/BopifyPlayback/LibrespotEngine.swift`, `EventBridge.swift`, `PlayerModel.swift`, `PlaybackRecoveryCoordinator.swift`, `rust/crates/bopify-core/src/recovery.rs`, `ffi.rs`, `event.rs`, `Bopify/Bopify/AppEnvironment.swift`, `PlaybackConnectionMonitor.swift`, `MenuBar/StatusItemController.swift`, `Localizable.xcstrings`, and `README.md`; update their existing test fakes. Add `Bopify/Bopify/PlaybackQualityStore.swift` and corresponding package/app tests.

**Interfaces:** Add a Codable Swift mode with string wire values `auto`, `96`, `160`, `320`; add optional wire fields `qualityMode` and `pathPolicy` to engine creation options (Rust fields `quality_mode` and `path_policy`), defaulting to fixed 320 when absent. Preserve the existing camelCase JSON convention. Add runtime quality/path commands through the existing guarded FFI pattern. Add a quality-applied event carrying requested tier, selected nominal tier, and mode when a loaded track becomes current; generation filtering remains owned by the existing bridge/coordinator. Update PlayerModel's exhaustive event handling and expose the applied quality without changing playback phase.

- [ ] Write failing encoding/decoding/validation tests on both sides, including omitted options, invalid mode, reconnect mode preservation, and new options under Rust's `deny_unknown_fields` schema.
- [ ] Write store/menu tests for default 320, persistence across launches, one checked menu choice, and “Applies to the next track” behavior. Keep the control in the existing status menu rather than introducing a settings window.
- [ ] Extend the existing network monitor to forward expensive/constrained flags and invalidate bandwidth samples on path changes, including satisfied-to-satisfied changes. Preserve availability and sleep/wake behavior.
- [ ] Wire cold creation and every reconnect to the current stored mode and path policy. Queue preferences while the engine is unavailable; never create a second engine to apply them. Forward changes without claiming remote playback ownership.
- [ ] Implement the bridge and regenerate its header/XCFramework using `./scripts/build-rust.sh`; update stubs/previews for the new engine methods/events.
- [ ] Run all suites below, then test constrained network traces around 1 Mbit/s, 400 kbit/s, and 180 kbit/s with latency/bursts/loss. Record selected tiers, load latency, starvation waits, transition gaps, and queue continuity. Use a controlled local fixture for repeatable tests and a live Spotify smoke test for integration.
- [ ] Verify no speed tests or additional media downloads are introduced. Check pause/resume, seeking, repeat-one, preload, hotspot, Low Data Mode, sleep/wake, offline recovery, fixed override, and remote ownership. Compare screenshots of the menu before/after.
- [ ] Tune the proposed policy only from those traces and update the tests/documented values together. Commit as `feat: expose automatic and fixed playback quality`.

## Execution checks and release order

```sh
./scripts/test-native.sh
./scripts/build-rust.sh
swift test --package-path Packages/BopifyCore
xcodebuild -project Bopify/Bopify.xcodeproj -scheme BopifyAppTests \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```

Recommended order: fixed 320 (Task 1), canonical Spotify link search (separate plan), then Auto only after its larger scope is accepted. Tasks 2–5 form one Auto feature and must not be presented as complete independently. Keep Auto opt-in until throttled-network and live playback checks establish that it improves continuity without unnecessary quality changes. No tests or live audio checks were executed while writing this plan.
