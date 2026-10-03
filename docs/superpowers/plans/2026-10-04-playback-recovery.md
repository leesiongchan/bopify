# Automatic Playback Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically replace failed playback engines, preserve the player surface, and resume matching local music while respecting another active Spotify device.

**Architecture:** A main-actor Swift coordinator owns engine creation, shutdown, retries, and credentials. A stable `PlayerModel` consumes one engine stream at a time and rejects stale work. Rust supervises terminal failure and performs recovery bootstrap inside Spirc, using native Spotify session state and ownership checks.

**Tech Stack:** Swift 6, SwiftUI/Observation, AppKit/Network, Rust 2024, Tokio, serde, the existing librespot source patch, Swift Testing.

**Spec:** [Approved recovery design](../specs/2026-10-04-playback-recovery-design.md).

## Global Constraints

- "Keep the same model across recovery."
- "Do not create another engine before the previous engine or failed attempt has fully torn down."
- "Generate the device UUID once for the coordinator's authenticated session and retain it through all retries."
- "Previously paused music stays paused. Another active Spotify device takes precedence over automatic local restoration."
- "Automatic restoration must not call `playHere()` or `spclient.transfer(own, own, None)`."
- "Do not automatically substitute Liked Songs or another track."
- "Use a 30-second Tokio deadline around the complete asynchronous login/`Spirc::new` setup inside `Engine::new`." Allow 20 seconds after creation for readiness and restoration.
- Retry immediately, then equal jitter over nominal 1, 2, 4, 8, 16, 30 seconds; reset only after 60 seconds of confirmed readiness. These constants are not user settings.
- "Keep explicit blocking shutdown off the main actor." Preserve runtime/audio joins and callback-context lifetime; no timed/background runtime shutdown.
- "Existing error-code values remain stable." Preserve the legacy C creator and existing public initializer calls.
- "No new package or service client is needed." Preserve librespot revision `939dc5ee9d833e1980f9495241219d9d4868a061` and locked dependency versions; Tokio test features may be enabled for existing dependencies.
- "Do not rebuild a healthy engine on a one-hour timer."
- "Preserve preferences and the separate library authorization when playback needs reauthorization."
- "Do not log tokens, reusable credentials, login response bodies, raw transfer/player state, or public track/account identifiers."
- Project deployment floor remains macOS 14.0; build the existing arm64 target. New app files use the synchronized Xcode source group; no project-file rearrangement.

## Review Focus

- A replacement finishes creating after sign-out: destroy it, never attach it or restore credentials. Task 5 cancellation gate test and Task 6 app probe.
- Another active device has no track/title: connectivity becomes ready while Bopify stays inactive. Task 3 native cluster fixture and Task 5 inactive readiness test.
- Duplicate occurrences, raw delimiter rows, and delayed context pages: retain native UIDs/providers/order; no stale queue target selects the replacement. Tasks 3 and 4.
- Media keys or a volume completion arrive during replacement: release system ownership and ignore old work. Tasks 4 and 7.
- A rejected-token refresh overlaps an ordinary refresh or newer consent: share refresh work or use the newer credential, without a second refresh or stale save. Task 2.

---

## File and responsibility map

| Boundary | Files |
|---|---|
| Recovery values and event decoding | New `Packages/BopifyCore/Sources/BopifyDomain/PlaybackRecovery.swift`; existing `PlaybackEvent.swift`, `PlaybackQueue.swift` in that directory. |
| Terminal supervision and deadlines | New `rust/crates/bopify-core/src/terminal.rs`; existing `engine.rs`, `event.rs`, `ffi.rs`, `lib.rs`, and crate `Cargo.toml`. |
| Native bootstrap | New `rust/crates/bopify-core/src/recovery.rs`; existing `rust/patches/librespot-queue-selection.patch`, maintained through the pinned checkout; new patched `connect/src/recovery.rs` and `connect/src/state/recovery.rs`. |
| Credential refresh | Existing `Packages/BopifyCore/Sources/BopifyAuth/SpotifyAuthService.swift` and `TokenClient.swift`. |
| Stable player and lifecycle policy | Existing `BopifyPlayback/PlayerModel.swift`, `LibrespotEngine.swift`, `EventBridge.swift`; new `ManagedPlaybackEngine.swift` and `PlaybackRecoveryCoordinator.swift`. |
| App integration | Existing `Bopify/Bopify/AppEnvironment.swift`; new `Bopify/Bopify/PlaybackConnectionMonitor.swift`. |
| Presentation and media commands | New `Bopify/Bopify/Views/PlaybackConnectionStatusView.swift`; existing `PlayerRootView.swift`, `RecordPlayerView.swift`, `TransportControls.swift`, `QueueView.swift`, `VolumeControl.swift`, `NowPlayingController.swift`, and `Localizable.xcstrings`. |
| App verification | New `docs/superpowers/verification/PlaybackRecoveryProbe.swift` and `2026-10-04-playback-recovery.md`; existing `run-monolith-probe.py`. |

Paths abbreviated as `BopifyPlayback/...` below mean `Packages/BopifyCore/Sources/BopifyPlayback/...`. Test paths are written in full. Files under `.build/` are patch working files, not root-repository deliverables.

## Execution preparation

- [ ] Use the worktree skill when execution begins. Preserve any existing user changes; the docs-only planning commits do not authorize resetting a checkout.
- [ ] In the implementation workspace, run `./scripts/prepare-librespot.sh` and obtain the static framework through `./scripts/build-rust.sh` if absent. Record baseline results from `cargo test --manifest-path rust/Cargo.toml` and `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-recovery-tests`.
- [ ] Capture the existing error surface before UI changes, using the existing visual probe after a Debug app build. Keep evidence under `/private/tmp/bopify-recovery-before`; log baseline failures rather than attributing them to this change.

Tools were found during planning: Cargo, Rust, Swift, Xcode, cbindgen, and Python. If a CLI is missing at execution, retry with the project's `,` prefix. Use sandbox escalation for blocked required commands. Do not report the baseline or any future check as passing until its output has been read.

### Task 1: Report terminal engine failures once and bound login

**Files:** Create `rust/crates/bopify-core/src/terminal.rs`, `Packages/BopifyCore/Sources/BopifyDomain/PlaybackRecovery.swift`; modify Rust `engine.rs`, `event.rs`, `ffi.rs`, `lib.rs`, `rust/crates/bopify-core/Cargo.toml`, domain `PlaybackEvent.swift`, `BopifyPlayback/PlayerModel.swift`, and `EventBridge.swift`. Modify the existing librespot patch for the safe authentication classification helper.

**Tests:** Rust unit tests in `terminal.rs`, `engine.rs`, `ffi.rs`; `Packages/BopifyCore/Tests/DomainTests/PlaybackEventTests.swift`; `Packages/BopifyCore/Tests/PlaybackTests/EventBridgeTests.swift`.

**Interfaces:**

- Domain: `public enum SessionLossReason: String, Codable, Hashable, Sendable` with `spircEnded`, `spircPanicked`, `playerChannelClosed`, `forwarderPanicked`, `commandFailed`, `eventStreamEnded`, `readinessTimeout`, `legacy`.
- Event: `PlaybackEvent.sessionLost(SessionLossReason)` decodes `{"type":"sessionLost","reason":"spircEnded"}`. Legacy `failed` with code -2 remains accepted.
- Rust: mirror the domain reason strings in `terminal.rs` as a serde-serializable `SessionLossReason`; add `WireEvent::SessionLost { reason: SessionLossReason }`. Provide `EngineReporter::new(EventSink) -> Self`, `event(&self, WireEvent)`, `session_lost(&self, SessionLossReason)`, `begin_teardown(&self)`. Its shared mutex serializes live events, the single terminal event, and teardown; an atomic duplicate flag alone is insufficient.
- Rust: `async fn with_connect_deadline<T>(operation: impl Future<Output = Result<T, librespot_core::Error>>) -> Result<T, BopifyError>` wraps the operation with the fixed 30-second Tokio deadline.
- Patched core: `Error::authentication_failure(&self) -> Option<AuthenticationFailure>`, where the new public enum has `InvalidCredentials` and `PremiumRequired`. Inspect native AP/login5 enums inside librespot rather than exporting credentials or formatting response bodies.

- [ ] **Write failing boundary tests.** Assert: racing live/terminal events yield one terminal and no ordinary event after it; `begin_teardown()` suppresses loss; Spirc completion/panic reports loss while the player channel remains open; pending login expires at 30 virtual seconds; typed network errors mentioning authentication remain retryable. Representative assertions:

```rust
assert_eq!(events.iter().filter(|e| matches!(e, WireEvent::SessionLost { .. })).count(), 1);
assert!(matches!(events.last(), Some(WireEvent::SessionLost { .. })));
assert_eq!(result, Err(BopifyError::NetworkUnavailable));
assert_eq!(classify_connect_error(network_error), BopifyError::NetworkUnavailable);
```

Swift tests decode each reason and legacy -2, fold a new terminal event to `.error(.playbackSessionLost)`, and confirm pending radio waiters fail once without double resume.

- [ ] **Run red:** `cargo test --manifest-path rust/Cargo.toml terminal`; `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-recovery-tests --filter PlaybackEvent`. Expect missing new interfaces or failed policy assertions, not unrelated build failures.
- [ ] **Implement supervision.** Share the reporter with Spirc watcher, forwarder, metadata/remote workers, and queue acknowledgement failures. Route any legacy `Failed { code: -2, .. }` through the terminal gate as well. Mark teardown from `Engine`'s drop before its runtime field drops. Preserve field-drop ordering and the C tombstone contract. Existing command-send failures remain -2; asynchronous observers also emit the safe terminal event. EventBridge fails radio waiters on loss while preserving delivery of the terminal playback event.
- [ ] **Implement classification and deadline.** Add the helper inside patched `core/src/error.rs`; make `Login5Error` crate-visible only as needed. Match AP `PremiumAccountRequired` and credential codes, and login5 `INVALID_CREDENTIALS`; leave timeout, throttling, malformed protocol, and ambiguous failures out of the credential category. Change `classify_connect_error` to consume `librespot_core::Error` and its kinds/helper. Enable Tokio `test-util` through a dev feature without updating the locked version.
- [ ] **Regenerate and verify the patch.** Stage any new working files in the pinned checkout so `git diff HEAD` includes them. Generate `rust/patches/librespot-queue-selection.patch` with `git -C .build/librespot-939dc5e diff --no-ext-diff --binary HEAD`, run `./scripts/prepare-librespot.sh`, and rebuild the static framework.
- [ ] **Run green:** full Rust tests; focused domain/EventBridge tests and the existing model session-loss tests. Confirm intentional destruction remains quiet and existing FFI destroy-race tests pass.
- [ ] **Commit** only Task 1 deliverables with subject `Detect terminal playback failures and bound engine login`; body explains the missing supervision and preserved callback lifetime.

### Task 2: Refresh a rejected playback credential safely

**Files:** Modify `Packages/BopifyCore/Sources/BopifyAuth/SpotifyAuthService.swift`, `TokenClient.swift`.

**Tests:** `Packages/BopifyCore/Tests/AuthTests/SpotifyAuthServiceTests.swift`, `TokenClientTests.swift`.

**Interfaces:** Preserve both existing `validAccessToken` overloads. Add `public func validAccessToken(rejecting rejectedAccessToken: String) async throws -> String`. It refreshes an otherwise unexpired rejected token, shares an existing refresh, and returns a newer valid token if another consumer has already replaced the rejected value. The coordinator's token provider will pass `nil` for an ordinary lookup and the rejected value for this overload.

- [ ] **Write failing tests:** `rejectedUnexpiredTokenRefreshes`, `rejectedOldTokenUsesNewerCredential`, `forcedAndOrdinaryRefreshShareRequest`, `signOutDuringForcedRefreshCannotSave`, `newConsentInvalidatesForcedRefresh`. Reuse the existing controlled refresh protocol/gate; assert:

```swift
#expect(result == "NEW_FAKE")
#expect(gate.requestCount == 1)
#expect(store.load() == nil) // after sign-out and releasing the old response
```

Add TokenClient fixtures: `invalid_grant` is `.authExpired`; temporary 429/5xx is `.networkUnavailable`; a malformed success or unrecognized permanent OAuth error is `.unknown`; cancellation remains cancellation. Retain missing-refresh-token fallback.

- [ ] **Run red:** `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-recovery-tests --filter AuthTests`; confirm the new behavior fails.
- [ ] **Implement the overload** by sharing the existing generation/task/save boundary, not creating a second OAuth client or keychain. Parse OAuth error responses before classification; never send response bodies to logs. Treat revoked/invalid refresh credentials as terminal and leave transient failures retryable.
- [ ] **Run green:** the AuthTests filter, including existing refresh-sharing, scope, consent, and sign-out tests.
- [ ] **Commit** with subject `Refresh rejected playback credentials without stale saves` and a body explaining refresh coalescing and terminal grant errors.

### Task 3: Restore native Spotify state with guarded recovery bootstrap

**Files:** Extend domain `PlaybackRecovery.swift`, `PlaybackEvent.swift`, and `PlayerModel.swift` for passive receipt of identity/readiness. Create `rust/crates/bopify-core/src/recovery.rs`; modify Rust `engine.rs`, `ffi.rs`, `event.rs`, `lib.rs`, `rust/cbindgen.toml`, and the existing patch. Create patched `.build/librespot-939dc5e/connect/src/recovery.rs` and `connect/src/state/recovery.rs`; modify patched `connect/src/{lib,spirc,state}.rs`, context-resolver integration as necessary, and `playback/src/player.rs` only where required by the new event/configuration contract.

**Tests:** Rust recovery/FFI/event unit tests; patched recovery/state tests; domain `PlaybackEventTests.swift`; new `Packages/BopifyCore/Tests/DomainTests/PlaybackRecoveryTests.swift`.

**Interfaces:**

- `public struct PlaybackIdentity: Codable, Hashable, Sendable`: `trackURI: SpotifyURI`, `trackUID: String?`, `contextURI: String?`; JSON keys `trackUri`, `trackUid`, `contextUri`. Encode/decode the URI as its validated raw string inside this type; `SpotifyURI` itself currently has no Codable conformance and does not need a project-wide change.
- `public struct PlaybackRecoverySnapshot: Codable, Equatable, Sendable`: `wasActive: Bool`, `shouldResume: Bool`, `identity: PlaybackIdentity?`, `positionMs: Int64`, `volume: Double`, `shuffleEnabled: Bool`, `repeatMode: RepeatMode`.
- `public enum PlaybackStartupMode: String, Codable, Sendable`: `coldLaunch`, `recovery`. `public struct PlaybackEngineConfiguration: Codable, Equatable, Sendable`: `deviceID: String`, `startup: PlaybackStartupMode`, `snapshot: PlaybackRecoverySnapshot?`; JSON key `deviceId`.
- `public enum PlaybackBootstrapOutcome: Hashable, Sendable`: `local(PlaybackIdentity)`, `remote`, `unavailable`. Associated event values must be Hashable because the existing `PlaybackEvent` is Hashable.
- Give domain value structs public fieldwise initializers. Identity UID/context and configuration snapshot default to nil; other snapshot fields are explicit. Cross-module consumers must not rely on Swift's internal synthesized memberwise initializer.
- `PlaybackEvent.recoveryIdentity(PlaybackIdentity)` and `.connectionReady(PlaybackBootstrapOutcome)`; wire envelopes have types `recoveryIdentity` and `connectionReady`, the latter uses `outcome` = `local`/`remote`/`unavailable` and identity only for local.
- New C entry point `bopify_engine_create_with_options(access_token, device_name, options_json, callback, ctx, out_err)` uses the existing argument types plus a borrowed `const char *options_json`, and returns `BopifyEngine *`. Preserve the existing creator as a cold-launch wrapper. Validate nonempty device ID, valid mode/identity, nonnegative position, finite volume in 0...1, and consistency before login: coldLaunch has no snapshot; shouldResume requires wasActive and an identity.
- In new Rust `recovery.rs`, define serde `EngineCreateOptions`, `StartupMode`, `RecoveryCheckpoint`, and `RecoveryIdentity` matching the Swift field names/JSON contract. Produce `Engine::new_with_options(&str, &str, EngineCreateOptions, EventSink) -> Result<Engine, BopifyError>`.
- Patched connect exports plain `StartupMode::{ColdLaunch, Recovery(Option<RecoveryCheckpoint>)}`, checkpoint and identity types with the same fields (strings instead of validated Swift URI). Add `ConnectConfig.startup_mode` defaulting to ColdLaunch; preserve existing `startup_restore`. Map Rust wire options into these native types.
- Patched Spirc `RecoveryDecision::{Foreign, Transfer(TransferState), OwnState(PlayerState), NoSession}` and `recovery_decision(&Cluster, &str) -> RecoveryDecision`.
- Patched ConnectState `restore_recovery_player_state(&mut self, PlayerState) -> Result<(), Error>` preserves raw track/prev/next/context/index/options/restrictions and replacement session bookkeeping. This is a recovery-only adapter.

- [ ] **Write failing decision/adapter tests.** Fixtures include foreign ownership with/without a track, own stale ownership, usable no-active transfer, missing/malformed transfer, repeated track URI with different UIDs, delimiter/empty URI rows, manual queue providers, zero volume, absent options, and mismatched content. Pin these assertions:

```rust
assert!(matches!(decision, RecoveryDecision::Foreign));
assert_eq!(restored.track, native.track);
assert_eq!(restored.prev_tracks, native.prev_tracks);
assert_eq!(restored.next_tracks, native.next_tracks);
assert_eq!(recorded_transfer_requests, 0);
assert_eq!(recorded_fallback_loads, 0);
```

Add loop-boundary fixtures for delayed context resolution and foreign ownership arriving before activation or immediately after resume. Assert volume precedes playback, a paused snapshot never resumes, a matching playing snapshot resumes once, and a changed URI/UID/context rejects both seek and resume.

- [ ] **Run red:** `cargo test --manifest-path .build/librespot-939dc5e/Cargo.toml -p librespot-connect recovery`; `cargo test --manifest-path rust/Cargo.toml recovery`; focused domain recovery tests. Expect unavailable new interfaces or failing bootstrap assertions.
- [ ] **Implement native restoration.** Add the recovery branch before ordinary startup fallback. Prepare context while inactive using `ResolveContext::from_uri`, `ContextResolver`, and `ConnectState::update_context`; keep a pending native-state overlay and apply it at initial context completion. Do not reuse `handle_load`, `load_context_from_uri`, or `handle_set_queue` unchanged: they activate/reset/normalize state. Ensure later pages retain the restored available queue rather than replacing it. Use current provider/context metadata for default versus autoplay context; never infer occurrence from URI alone.
- [ ] **Implement the readiness boundary.** Emit native identity when the local track/context changes. Load paused and apply captured volume before any playback. Immediately before activation/resume check the latest ownership; abandon pending restoration on any observed foreign owner. No-active transfer uses the existing transfer path with captured seek only for matching identity. Emit connectionReady only after local playback confirmation and fresh queue publication, or immediately after confirmed inactive/unavailable bootstrap. Ordinary cold startup also emits readiness but retains its existing paused/fallback semantics.
- [ ] **Implement FFI and cross-language decoding** in the same commit as the schema. Add passive `PlayerModel.recoveryIdentity` storage and `onConnectionReady` callback using Task 4's signatures so its exhaustive event switch builds; do not add a catch-all. Document create arguments and lifetime in cbindgen's contract. Malformed options return -1 without a login or retained handle.
- [ ] **Regenerate the patch, verify preparation, rebuild the static framework.** Follow Task 1's pinned-checkout workflow and retain the generated-header lifetime contract.
- [ ] **Run green:** `cargo test --manifest-path .build/librespot-939dc5e/Cargo.toml -p librespot-connect`; `cargo test --manifest-path rust/Cargo.toml`; `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-recovery-tests --filter DomainTests`. No failed recovery, startup, remote-mirror, queue-selection, or legacy creator tests.
- [ ] **Commit** with subject `Restore playback through an ownership-aware recovery bootstrap`; body explains raw queue preservation and why automatic takeover endpoints are excluded.

### Task 4: Keep one player model and reject work from old engines

**Files:** Modify domain `PlaybackQueue.swift`, `BopifyPlayback/PlayerModel.swift`, `LibrespotEngine.swift`, `EventBridge.swift`; create `BopifyPlayback/ManagedPlaybackEngine.swift` and `Packages/BopifyCore/Tests/PlaybackTests/RecoveryStubEngine.swift`.

**Tests:** Existing `PlayerModelTests.swift`, `PlayerVolumeTests.swift`, `LibrespotEngineTests.swift`, `EventBridgeTests.swift`; new `Packages/BopifyCore/Tests/PlaybackTests/PlayerRecoveryTests.swift`.

**Interfaces:**

- `public protocol ManagedPlaybackEngine: PlaybackEngine { func shutdown() async }`; `LibrespotEngine` conforms.
- Extend `LibrespotEngine.init(accessToken: String, deviceName: String, configuration: PlaybackEngineConfiguration? = nil) async throws`. Nil preserves legacy create; production recovery supplies configuration.
- `PlayerModel` keeps existing engine-based initializers and adds `public convenience init()` for initial connection before an engine exists.
- `public private(set) var engineEpoch: UInt64`, `isEngineReady: Bool`, `recoveryIdentity: PlaybackIdentity?`, `restorationUnavailable: Bool`.
- `@ObservationIgnored public var onSessionLost: (@MainActor (SessionLossReason, PlaybackRecoverySnapshot) -> Void)?` and `onConnectionReady: (@MainActor (PlaybackBootstrapOutcome) -> Void)?`.
- `public func attachEngine(_ engine: any PlaybackEngine, epoch: UInt64)`, `detachEngine()`, `setConnectionReady(_ outcome: PlaybackBootstrapOutcome)`, `captureRecoverySnapshot(at date: Date) -> PlaybackRecoverySnapshot`.
- `QueueTarget` adds `engineEpoch: UInt64` with default zero to its initializer. Wire decoding remains epoch zero; `PlayerModel` stamps every new queue target with its current epoch. FFI still sends structural generation/raw index; epoch is validated in Swift before dispatch.
- `RecoveryStubEngine` implements the managed protocol and provides `emit(_:)`, `finishEvents()`, controlled command completions, `recordedCommands`, and `shutdownCount` under the existing stub's synchronization pattern.

- [ ] **Write failing tests.** Assert stable object identity after attach/detach; one loss callback for stream end/event/command loss; buffered old events are ignored; late commands and volume failures cannot clear new state; retained metadata/position survive detachment and pre-readiness replacement events; loading uses prior confirmed intent; ended/idle/remote snapshots do not resume.

```swift
#expect(ObjectIdentifier(model) == originalID)
#expect(model.state.currentTrack == oldTrack)
#expect(model.displayPositionMs(at: later) == frozenPosition)
#expect(lossCallbacks.count == 1)
#expect(replacement.recordedCommands.isEmpty) // stale queue target
```

Create two queues with the same structural generation and raw target but different engine epochs. The old target must be rejected. Treat new metadata as belonging only to the currently consuming epoch.

- [ ] **Run red:** `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-recovery-tests --filter PlayerRecovery` and targeted volume tests.
- [ ] **Implement the replacement boundary.** Make the engine optional while detached. Cancel/invalidate command and volume workers before replacement; capture the concrete engine and epoch at every dispatch. Guard loop events, stream termination, command completions, and radio failure reporting by epoch. Capture intent before clearing active state, preserve last confirmed intent through loading, freeze mirrors, and call the terminal callback at most once per epoch. A manual `stop()` remains intentional and does not report stream loss.
- [ ] **Implement readiness and unavailable content handling.** Attach begins with controls disabled. Stage replacement track/queue/phase/volume events until connectionReady instead of exposing a partial state or resetting the frozen display position; continue processing identity and terminal callbacks. Local/remote readiness publishes a coherent new state and enables only the appropriate controls. Unavailable content retains stale metadata and an inactive state for explicit retry/play. Preserve direct-stub initializer behavior for existing tests/previews; coordinator-managed attachment always awaits readiness.
- [ ] **Test configuration encoding** against the Task 3 JSON schema; invoke the new FFI creator for supplied options and keep callback retain/release pairing unchanged. Fail pending radio requests on detachment; requests during unavailable engine state fail immediately.
- [ ] **Run green:** focused recovery/volume/engine/EventBridge tests, then the PlaybackTests suite once. Confirm the legacy model tests still observe the expected terminal phase when no recovery owner is installed.
- [ ] **Commit** with subject `Preserve player state across playback engine replacement`; body explains epoch validation and command cancellation.

### Task 5: Coordinate retries, readiness, cancellation, and credentials

**Files:** Create `BopifyPlayback/PlaybackRecoveryCoordinator.swift`, `Packages/BopifyCore/Tests/PlaybackTests/PlaybackRecoveryCoordinatorTests.swift`, `RecoveryTestClock.swift`, and `RecoveryFactoryGate.swift`.

**Interfaces:**

- `public enum PlaybackConnectionStatus: Equatable, Sendable`: `connecting`, `restoring`, `ready`, `reconnecting`, `offline`, `needsReauthentication`, `failed(PlayerError)`, `stopped`.
- `@MainActor @Observable public final class PlaybackRecoveryCoordinator` owns `player: PlayerModel`, read-only `status`, and read-only `currentEngine: (any ManagedPlaybackEngine)?`.
- Initializer inputs: player; `tokenProvider: @Sendable (String?) async throws -> String`; `makeEngine: @Sendable (String, PlaybackEngineConfiguration) async throws -> any ManagedPlaybackEngine`; `deviceID: String = UUID().uuidString`; monotonic `now: @MainActor () -> TimeInterval`; `sleep: @Sendable (Duration) async throws -> Void`; `randomUnit: @Sendable () -> Double`. Use production defaults and internal test injection for clock/random closures.
- Public methods: `start(recovery: PlaybackRecoverySnapshot? = nil)`, `retryNow()`, `setNetworkAvailable(_ available: Bool)`, `setSleeping(_ sleeping: Bool)`, `wake()`, `reportSessionLoss(_ reason: SessionLossReason, epoch: UInt64)`, `invalidate()`, `stop() async`. Start schedules work and returns immediately. Invalidate synchronously rejects further work and begins tracked teardown; stop calls it idempotently and awaits all create/teardown work. Epoch is required for radio failures from work dispatched before replacement.
- `onStatusChange: (@MainActor (PlaybackConnectionStatus) -> Void)?` and `onEngineChange: (@MainActor ((any ManagedPlaybackEngine)?) -> Void)?` are observation-ignored composition callbacks.
- Internal `recoveryRetryDelay(failureCount: Int, jitterUnit: Double) -> Duration` implements the spec constants. Failure count one means the first delay after the immediate failed attempt.
- Test helpers are main-actor classes: `RecoveryTestClock` exposes `now: TimeInterval`, `sleep(for: Duration) async throws`, `advance(by: Duration)`, and `pendingDelays: [Duration]`. `RecoveryFactoryGate` records configurations, concurrent counts, and token lookups; provide `create(token: String, configuration: PlaybackEngineConfiguration) async throws -> any ManagedPlaybackEngine`, `succeedNext(with: RecoveryStubEngine)`, `failNext(with: PlayerError)`, and `waitForCreationCount(_ count: Int) async`. Sendable asynchronous injection closures hop to these helpers; the synchronous main-actor now closure reads the clock directly. Use continuations/events for milestones, never wall-time sleeps.

- [ ] **Write failing policy tests.** Pin both jitter endpoints, creation/restoration deadlines, and stable-readiness reset:

```swift
#expect(recoveryRetryDelay(failureCount: 1, jitterUnit: 0) == .milliseconds(500))
#expect(recoveryRetryDelay(failureCount: 6, jitterUnit: 1) == .seconds(30))
#expect(recoveryRetryDelay(failureCount: 100, jitterUnit: 0) == .seconds(15))
#expect(factory.maximumConcurrentCreations == 1)
#expect(configurations.allSatisfy { $0.deviceID == deviceID })
```

Add `duplicateLossCoalesces`, `oldShutdownPrecedesCreate`, `offlineSuspends`, `networkWakeAndRetryCoalesce`, `healthyWakeDoesNotRebuild`, `sleepSuspendsDelay`, `flappingReadyDoesNotResetBefore60Seconds`, and `readinessTimesOutAt20Seconds`. `startupResolved(.restored)` without confirmed readiness must remain restoring.

- [ ] **Write lifecycle/auth tests.** Suspend token lookup, create, restore, and shutdown independently. Stop and release each gate; assert late engines are shut down and never attached. Verify one forced refresh after token rejection, no second forced refresh on repeated rejection, and correct terminal Premium/unknown outcomes. Test initial offline sign-in retries using coldLaunch options, no usable session becomes ready/unavailable without an automatic retry loop, and remote readiness discards stale automatic-resume intent.
- [ ] **Run red:** `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-recovery-tests --filter PlaybackRecoveryCoordinator`.
- [ ] **Implement one operation loop and generation guard.** A fresh failure captures one snapshot, detaches, awaits old shutdown, fetches credentials, and creates with the stable ID. A stale successful creation is shut down before returning. Route commands through the currently attached engine only after readiness. Protect ownership of the task slot: an old task's defer must not clear a newer retry task. Cancellation is distinct from network failure.
- [ ] **Implement retry policy and readiness.** Inject monotonic time; cap exponent calculation before arithmetic. Manual retry/network return/wake interrupt only a delay, never start a second create. Record ready time and reset failure count after 60 uninterrupted seconds, with a generation check on the reset task. Apply the 20-second deadline to initial and recovery bootstrap. Clear the recovery snapshot only after successful local readiness or confirmed remote ownership; retain it for reauthorization/manual restoration retry when needed.
- [ ] **Implement credential rejection budget and logging.** Ordinary lookup passes nil; the first true token rejection passes the rejected token to the provider once. A second rejection is needsReauthentication. Retain that budget through intervening network retries; reset only after readiness or explicit new authorization. Network/session failures retry; .premiumRequired/.unknown fail without a loop. Log safe reason, generation, attempt, elapsed phases, delay, and result.
- [ ] **Run green:** coordinator tests plus the full package suite. Count factory requests and shutdown order rather than testing the scheduling library itself.
- [ ] **Commit** with subject `Reconnect playback automatically with bounded retry delays`; body explains readiness gating, automatic resume intent, and lifecycle cancellation.

### Task 6: Integrate recovery into authentication and app lifetime

**Files:** Modify `Bopify/Bopify/AppEnvironment.swift`; create `Bopify/Bopify/PlaybackConnectionMonitor.swift`, `docs/superpowers/verification/PlaybackRecoveryProbe.swift`; modify `docs/superpowers/verification/run-monolith-probe.py`.

**Interfaces:**

- Environment owns one recovery coordinator and exposes `connectionStatus`, `retryPlaybackConnection()`, and `reconnectSpotify() async`. Existing restore/signIn/signOut/prepareForQuit entry points remain.
- `PlaybackConnectionMonitor.init(coordinator: PlaybackRecoveryCoordinator)`, `start()`, `stop()` adapts `NWPathMonitor` and workspace sleep/wake notifications to main-actor signals. Unknown initial path permits one attempt; an unsatisfied path suspends retries. Release observers/monitor on stop.
- App DEBUG injection adds a coordinator factory or engine/token closures to `AppEnvironment` for probes; production still chooses concrete auth/engine implementations here.
- Add `--probe recovery` to the existing probe runner, mapped to `PlaybackRecoveryProbe.swift`. The probe uses production app composition with fake managed engines/auth stores and no Spotify login.

- [ ] **Write the failing app probe.** Establish known artwork/library contents/player/window mode; force loss then readiness. Assert player identity and preferences are retained; library generation/content and library keychain are unchanged; radio routing uses only the replacement. Suspend create, sign out/quit, release creation, and assert the new engine is destroyed without attachment. Assert initial network failure shows connection retry rather than browser authorization.

```swift
precondition(environment.player === originalPlayer)
precondition(environment.presentation.mode == originalMode)
precondition(libraryStore.load() == originalLibraryTokens)
precondition(lateEngine.shutdownCount == 1)
precondition(browserOpenCount == 0)
```

- [ ] **Build and run red:** Debug Xcode build below, then `python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-recovery-build --output /private/tmp/bopify-recovery-app-red --probe recovery`. Missing injection/new probe interfaces or failed invariants are expected.
- [ ] **Implement composition.** Replace the environment's direct concrete engine lifecycle with the coordinator. Token provider calls the Task 2 rejected-token overload when supplied. Initialize the stable player before connection and publish signed-in auth after credentials are established; connection status describes pending network work. `onEngineChange` updates StationRoute; radio session-loss catches report to the coordinator for the matching engine generation.
- [ ] **Implement auth and stop integration.** Preserve `serialize` without nesting or awaiting retry loops. Sign-out/quit stop the monitor and call synchronous `invalidate()` before enqueuing their serialized cleanup; an environment session generation also prevents an earlier pending authorization from starting recovery afterward. Inside cleanup, await `stop()` before dropping the coordinator/model. Playback reauthorization retains the stable model/snapshot, does not sign out of library auth, and restarts recovery only after successful user authorization. Quit preserves saved credentials. Existing preview initialization continues to work without starting recovery.
- [ ] **Implement native monitor adapters.** Forward path transitions and sleep/wake on the main actor, ignore old callbacks after stop, and never replace a healthy engine merely because the Mac wakes. Avoid treating path availability as Spotify reachability.
- [ ] **Run green:** Debug build and the recovery app probe; existing library/mirror probes where affected. Capture output showing lifecycle ordering and zero unsolicited browser opens.
- [ ] **Commit** with subject `Integrate playback recovery with app authentication and lifetime`; body explains preserved library authorization and cancellation before teardown.

### Task 7: Present recovery actions without resetting the player

**Files:** Create `Bopify/Bopify/Views/PlaybackConnectionStatusView.swift`; modify `PlayerRootView.swift`, `RecordPlayerView.swift`, `TransportControls.swift`, `QueueView.swift`, `VolumeControl.swift`, `Bopify/Bopify/NowPlayingController.swift`, `Localizable.xcstrings`, `BopifyPlayback/NowPlayingInfo.swift`, and the recovery probe.

**Tests:** `Packages/BopifyCore/Tests/PlaybackTests/NowPlayingInfoTests.swift`, `PlayerRecoveryTests.swift`; recovery app probe.

**Interfaces:** `PlaybackConnectionStatusView(status: PlaybackConnectionStatus, restorationUnavailable: Bool, onRetry: () -> Void, onReconnect: () -> Void)`. Extend `nowPlayingInfo(for:positionMs:connectionReady:)` with a default true readiness parameter so existing callers compile; the app passes `player.isEngineReady`.

- [ ] **Write failing presentation checks.** Add `unreadyPlayerReleasesNowPlaying` and `readyLocalPlayerReclaimsNowPlaying`; assert the pure mapping returns nil while unavailable. Inject a media command while replacing and assert neither old nor new engine receives it. Probe all player modes with reconnection, offline, unavailable content, and needsReauthentication; record the player ID, frame, displayed position, and enabled actions.

```swift
#expect(nowPlayingInfo(for: state, positionMs: 12_000, connectionReady: false) == nil)
#expect(nowPlayingInfo(for: state, positionMs: 12_000, connectionReady: true) != nil)
precondition(frameAfterLoss == frameBeforeLoss)
precondition(displayedPositionAfterDelay == frozenPosition)
```

- [ ] **Run red:** focused NowPlayingInfo tests and the recovery probe's presentation assertions.
- [ ] **Implement localized status/actions.** Use `connection.reconnecting` = “Reconnecting…”, `connection.offline` = “You're offline”, `connection.retry` = “Retry now”, `connection.reconnect` = “Reconnect Spotify”, `connection.restoreUnavailable` = “Playback couldn't be restored.”, and `connection.retryRestoration` = “Retry restoration”. The latter is shown for ready/unavailable content and routes to coordinator retry with retained snapshot. Suppress generic command notices while a connection status explains the interruption.
- [ ] **Preserve surfaces in every mode.** Known content remains on the stable RecordPlayerView during reauthorization and reconnection; update the environment's listening/presentation predicate accordingly. In expanded/queue mode, put status/actions in the existing status row. In compact mode, expose a small status affordance on the record with an accessible action menu; it must fit the existing compact geometry and remain usable by keyboard/VoiceOver. Do not force expansion, open the panel, or add an alert.
- [ ] **Guard controls and system ownership.** All model dispatches and visible transport/seek/queue/volume availability require `isEngineReady`; library browsing/authorization stays usable. Stop spin/clock, release Now Playing, and remove effective media-command ownership while detached. Keep the same controller tied to the stable model; reclaim only after local readiness. Preserve reduced-motion behavior and focus.
- [ ] **Run green:** NowPlayingInfo and PlayerRecovery tests, then Debug app build and the recovery probe. Capture before/after screenshots in compact/expanded/queue, offline, and reauthorization states; inspect that text/actions fit and frames remain stable. Record VoiceOver labels and disabled controls in the probe report.
- [ ] **Commit** with subject `Show reconnect status and recovery actions in the player`; body explains stable presentation and truthful system media ownership.

### Task 8: Verify the full recovery path and document evidence

**Files:** Extend `docs/superpowers/verification/PlaybackRecoveryProbe.swift`; create `docs/superpowers/verification/2026-10-04-playback-recovery.md`. Modify implementation only to address failures attributable to this feature.

- [ ] **Run a repeated fake-recovery stress probe.** Perform 100 successful replacements plus failed creates. Assert maximum one live managed engine, one event consumer, and shutdown of every replaced or stale-created engine. Test old callback/metadata/volume/media inputs after each epoch. Document that native successful handles retain small shells; do not label total handle memory bounded.
- [ ] **Run final automated checks once after the last change:**

```sh
./scripts/prepare-librespot.sh
cargo fmt --manifest-path rust/Cargo.toml --all --check
cargo test --manifest-path rust/Cargo.toml
cargo test --manifest-path .build/librespot-939dc5e/Cargo.toml -p librespot-connect
cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings
./scripts/build-rust.sh
swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-recovery-tests
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-recovery-build build
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-recovery-release build CODE_SIGNING_ALLOWED=NO
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-recovery-build --output /private/tmp/bopify-recovery-final --probe recovery
git diff --check
```

Every applicable command must exit zero with no failed tests/assertions. Read complete logs; distinguish pre-existing warnings from new errors. Don't apply rustfmt to unrelated pinned upstream code or change dependencies to make checks pass.

- [ ] **Exercise live recovery with the available Spotify account.** Confirm disconnect/reconnect while playing and paused, network return, sleep/wake, and another device taking over before and during recovery. Use controlled app/probe failure and user-directed network changes rather than silently changing system-wide networking. Record actual freeze/reconnect/resume times and the observed current/next queue. Verify volume zero and options survive. If GUI/network permissions are required, use the tool's escalation; if live evidence is unavailable, mark that verification pending rather than claiming it passed.
- [ ] **Observe a session beyond initial OAuth expiry.** Verify the new policy does not perform an hourly engine rebuild. This is a long-running acceptance check, not a reason to block frequent user updates or run a long blocking tool wait. Record actual elapsed evidence or explicitly pending verification.
- [ ] **Write the evidence document** with exact commands/results, screenshot paths, latency observations, ownership outcomes, stress/resource limits, and any pending live checks. Do not include credentials or raw account/track identifiers.
- [ ] **Request whole-branch code review** using the applicable review skill before integration. Address verified findings and rerun only affected checks, then broader checks if the findings justify them.
- [ ] **Commit** verification evidence with subject `Verify automatic playback recovery and device ownership`; body states the exercised scenarios and any acceptance limits. Use the finishing skill for integration decisions; this plan does not authorize publishing or changing unrelated branches.

## Coverage and handoff

Tasks 1/3 implement Rust detection, identity, deadlines, bootstrap, and ABI safety. Task 2 covers credential refresh/error classification. Tasks 4/5 cover stable state, command/queue epochs, retry policy, and cancellation. Tasks 6/7 cover app lifetime, connectivity, reauthorization, UI, and system controls. Task 8 supplies automated, visual, live, and resource evidence.

All new signatures above are proposed interfaces. Existing APIs were checked against the pinned source during planning; execution must read the approved spec as well as this plan. A failing assumption about native restore semantics requires revisiting the affected design, not silently switching to a takeover endpoint or track-only reconstruction.

Execution has not started. Recommended handoff: **Native** execution in this session, with one independent whole-branch review. These eight tasks share event schemas, epoch state, and bootstrap readiness; one implementer can keep those interfaces consistent without paying for a fresh implementation/review context at every step. Subagent-driven execution remains available if the user prefers a review gate after every task.
