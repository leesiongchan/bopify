# Connection Resilience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Playback recovery never dead-ends on a transient failure, backs off across repeated drops, and every access-point connect is time-bounded.

**Architecture:**
- **Swift:** `PlaybackRecoveryCoordinator` replaces its 60 s reset with a 10-minute drop window and a longer ladder, and lets Retry leave any failure.
- **Fork:** the librespot fork is rebased on upstream `dev` and gains librespot#1800/#1803 and an account-restricted login classification.
- **bopify-core:** inverts its connect-error classifier, so only account problems are terminal.
- **FFI error codes:** become a JSON contract shared by Rust and Swift tests.

**Tech Stack:** Swift (tools 6.0, Swift Testing, SwiftUI), Rust 2024 (tokio, librespot fork), cargo, xcodebuild.

**Spec:** `docs/superpowers/specs/2026-11-03-connection-resilience-design.md`

## Global Constraints

- **Retry schedule:** nominal seconds per step, each with 50–100 % jitter: immediate, 2, 5, 15, 30, 60, 120, then 300 (cap).
- **Drop window:** drops inside a rolling 10 minutes count towards the step.
- **Recovery policy:**
  - Network restoration and wake still retry immediately.
  - −3 keeps one forced token refresh, then `.needsReauthentication`.
  - `.failed` is reserved for −4, −6, engine-local −99, and spec 3's −7.
  - `retryNow()` leaves every `.failed` state; wake and network changes do not.
- **Retry UI:** "Retry now" (`connection.retry`) shows while a wait of nominal 30 s or longer is scheduled, and on every `.failed`.
- **FFI codes:** −1 InvalidArgument, −2 SessionLost, −3 AuthInvalid, −4 PremiumRequired, −5 NetworkUnavailable, −6 AccountRestricted (new), −99 Unknown.
- **Copy:** `error.accountRestricted` = "Spotify won't let this account play here."
- **Logging:** log error kinds, never payloads, tokens or user identifiers.
- **Toolchain:** run cargo as `env -u RUSTUP_TOOLCHAIN …`, because the user's global mise pins `rust = "latest"`, which overrides `rust-toolchain.toml`.
- **Fork:** `github.com/leesiongchan/librespot`, branch `bopify`, currently `7857e749cc83d4ac98ffe42e14dc3cdfa3cc18c9`. Pushing the fork is outward-facing; Task 7 stops for the user's explicit approval.
- **Commits:** Conventional Commits, subject under 72 characters, body explains why, no co-author trailer.

## File map

| File | Responsibility | Tasks |
|---|---|---|
| `contracts/ffi-error-codes.json` (new) | FFI code contract | 1, 8 |
| `rust/crates/bopify-core/src/error.rs` | `BopifyError` codes and contract test | 1, 8 |
| `Packages/BopifyCore/Sources/BopifyDomain/PlayerError.swift` | Swift error taxonomy, FFI mapping | 8 |
| `Packages/BopifyCore/Tests/PlaybackTests/LibrespotEngineTests.swift` | Swift contract test | 1, 8 |
| `Packages/BopifyCore/Sources/BopifyPlayback/PlaybackRecoveryCoordinator.swift` | backoff, retry policy | 2 |
| `Packages/BopifyCore/Tests/PlaybackTests/PlaybackRecoveryCoordinatorTests.swift` | coordinator tests | 2, 8 |
| `Bopify/Bopify/Views/PlaybackConnectionStatusView.swift` | Retry action and message keys | 3, 8 |
| `Bopify/Bopify/AppEnvironment.swift` | `offersPlaybackRetry` | 3 |
| `Bopify/Bopify/Views/PlayerRootView.swift`, `RecordPlayerView.swift` | pass `offersRetry` | 3 |
| `Bopify/BopifyAppTests/SignInRecordTests.swift`, `PlaybackConnectionStatusViewTests.swift` | view tests | 3, 8 |
| `Bopify/Bopify/PlayerError+Localized.swift`, `Localizable.xcstrings` | copy | 8 |
| `.build/librespot-fork/` (gitignored working clone) | fork changes | 4–7 |
| `rust/Cargo.toml`, `rust/Cargo.lock` | fork pin | 8 |
| `rust/crates/bopify-core/src/engine.rs` | `classify_connect_error` | 8 |

Tasks 1–3 need no fork changes. Tasks 4–6 work only in the fork clone. Task 7 is the push checkpoint. Task 8 consumes the published fork.

---

### Task 1: Share FFI error codes through a contract

**Files:**
- Create: `contracts/ffi-error-codes.json`
- Modify: `rust/crates/bopify-core/src/error.rs` (replace the `codes_are_stable` test)
- Modify: `Packages/BopifyCore/Tests/PlaybackTests/LibrespotEngineTests.swift` (replace `mapsFFICodesOntoTheErrorTaxonomy`)

**Interfaces:**
- Produces: `contracts/ffi-error-codes.json`, an object mapping contract name to code. Task 8 adds `"accountRestricted": -6` to it.

- [ ] **Step 1: Write the contract file**

```json
{
  "invalidArgument": -1,
  "sessionLost": -2,
  "authInvalid": -3,
  "premiumRequired": -4,
  "networkUnavailable": -5,
  "unknown": -99
}
```

- [ ] **Step 2: Replace the Rust test.** In `error.rs`, replace `codes_are_stable` with:

```rust
    /// Swift's `LibrespotEngineTests` read the same fixture, so a code changes on both sides or neither.
    #[test]
    fn codes_match_the_shared_wire_contract() {
        use BopifyError::*;
        fn name(error: BopifyError) -> &'static str {
            // A new variant stops this compiling until it is named, and so listed in the fixture.
            match error {
                InvalidArgument => "invalidArgument",
                SessionLost => "sessionLost",
                AuthInvalid => "authInvalid",
                PremiumRequired => "premiumRequired",
                NetworkUnavailable => "networkUnavailable",
                Unknown => "unknown",
            }
        }
        let all = [InvalidArgument, SessionLost, AuthInvalid, PremiumRequired, NetworkUnavailable, Unknown];
        let actual: std::collections::BTreeMap<String, i32> =
            all.iter().map(|error| (name(*error).to_owned(), error.code())).collect();
        let contract: std::collections::BTreeMap<String, i32> = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../contracts/ffi-error-codes.json"
        )))
        .unwrap();
        assert_eq!(actual, contract);
    }
```

- [ ] **Step 3: Replace the Swift test.** In `LibrespotEngineTests.swift`, replace `mapsFFICodesOntoTheErrorTaxonomy` with:

```swift
    /// `InvalidArgument` (-1), `Unknown` (-99) and unrecognised codes all fold to `.unknown`, because -1 is a caller bug
    /// with nothing useful to show a listener. Rust's `error.rs` tests read the same fixture.
    @Test func mapsTheSharedFFICodesOntoTheErrorTaxonomy() throws {
        let expected: [String: PlayerError] = [
            "invalidArgument": .unknown, "sessionLost": .playbackSessionLost, "authInvalid": .authExpired,
            "premiumRequired": .premiumRequired, "networkUnavailable": .networkUnavailable, "unknown": .unknown,
        ]
        let fixture = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../contracts/ffi-error-codes.json").standardized
        let codes = try JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: fixture))
        #expect(Set(codes.keys) == Set(expected.keys))
        for (name, code) in codes { #expect(PlayerError(ffiCode: code) == expected[name], "\(name)") }
        #expect(PlayerError(ffiCode: 12345) == .unknown)
    }
```

- [ ] **Step 4: Run both tests and confirm they pass.** This is a refactor of existing coverage, so it passes on the first run. Then confirm each test really reads the contract: temporarily change `-5` to `-7` in the JSON, rerun, and both tests must FAIL. Restore the JSON.

Run:
```bash
env -u RUSTUP_TOOLCHAIN cargo test --manifest-path rust/Cargo.toml --locked -p bopify-core error::tests
swift test --package-path Packages/BopifyCore --filter LibrespotEngineTests
```

- [ ] **Step 5: Commit**

```bash
git add contracts/ffi-error-codes.json rust/crates/bopify-core/src/error.rs Packages/BopifyCore/Tests/PlaybackTests/LibrespotEngineTests.swift
git commit -m "test: share FFI error codes through a contract" -m "Rust and Swift mirrored the codes by hand. Both suites now read one fixture, as session-loss reasons already do, so a new code cannot reach one side only."
```

---

### Task 2: Windowed backoff and Retry from any failure

**Files:**
- Modify: `Packages/BopifyCore/Sources/BopifyPlayback/PlaybackRecoveryCoordinator.swift`
- Test: `Packages/BopifyCore/Tests/PlaybackTests/PlaybackRecoveryCoordinatorTests.swift`

**Interfaces:**
- Produces:
  - `let recoveryRetrySchedule: [Double]`
  - `func recoveryRetryDelay(step: Int, jitterUnit: Double) -> Duration`. This replaces `recoveryRetryDelay(failureCount:jitterUnit:)`.
  - `public private(set) var offersManualRetry: Bool` on `PlaybackRecoveryCoordinator`, consumed by Task 3.

- [ ] **Step 1: Write the failing tests.**

Replace `retryDelaysStayWithinJitterBoundsAndCapWithoutOverflow`, `flappingKeepsBackoffAndSixtySecondsReadyResetsIt`, `readyThenDeadSessionsBackOffUntilStable` and `permanentErrorsDoNotLoop` with:

```swift
    @Test func retryDelaysFollowTheScheduleWithinJitterBounds() {
        #expect(recoveryRetryDelay(step: 0, jitterUnit: 1) == .zero)
        #expect(recoveryRetryDelay(step: 1, jitterUnit: 0) == .seconds(1))
        #expect(recoveryRetryDelay(step: 1, jitterUnit: 1) == .seconds(2))
        #expect(recoveryRetryDelay(step: 7, jitterUnit: 1) == .seconds(300))
        #expect(recoveryRetryDelay(step: Int.max, jitterUnit: 0) == .seconds(150))
        #expect(recoveryRetryDelay(step: -1, jitterUnit: 1) == .zero)
    }

    /// Connect failures climb the whole ladder and stay at its cap instead of giving up.
    @Test func connectFailuresClimbToTheFiveMinuteCap() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        recovery.start()
        for (attempt, seconds) in [2.0, 5, 15, 30, 60, 120, 300, 300].enumerated() {
            await gate.waitForCreationCount(attempt + 1)
            gate.failNext(with: .networkUnavailable); await settle()
            #expect(clock.pendingDelays.contains(.seconds(seconds)), "attempt \(attempt)")
            clock.advance(by: .seconds(seconds))
        }
        await gate.waitForCreationCount(9); gate.failNext(with: .networkUnavailable); await settle()
        await recovery.stop()
    }

    /// The old 60-second reset let a session that dropped every minute reconnect instantly forever.
    @Test func dropsEverySixtyOneSecondsStillEscalate() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1)
        var engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle()
        engine.emit(.connectionReady(.remote)); await settle()
        for (drop, seconds) in [0.0, 2, 5, 15, 30].enumerated() {
            clock.advance(by: .seconds(61)); await settle()
            engine.emit(.sessionLost(.spircEnded)); await settle()
            if seconds > 0 {
                #expect(clock.pendingDelays.contains(.seconds(seconds)), "drop \(drop)")
                #expect(gate.configurations.count == drop + 1)
                clock.advance(by: .seconds(seconds))
            }
            await gate.waitForCreationCount(drop + 2)
            engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle()
            engine.emit(.connectionReady(.remote)); await settle()
        }
        await recovery.stop()
    }

    @Test func dropsOlderThanTenMinutesStopCounting() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1)
        var engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle()
        engine.emit(.connectionReady(.remote)); await settle()
        engine.emit(.sessionLost(.spircEnded)); await gate.waitForCreationCount(2)
        engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle(); engine.emit(.connectionReady(.remote)); await settle()
        engine.emit(.sessionLost(.spircEnded)); await settle()
        #expect(clock.pendingDelays.contains(.seconds(2)))
        clock.advance(by: .seconds(2)); await gate.waitForCreationCount(3)
        engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle(); engine.emit(.connectionReady(.remote)); await settle()
        clock.advance(by: .seconds(601)); await settle()
        engine.emit(.sessionLost(.spircEnded)); await gate.waitForCreationCount(4)
        #expect(clock.pendingDelays.isEmpty)
        gate.failNext(with: .networkUnavailable); await settle()
        await recovery.stop()
    }

    @Test func onlyLongWaitsOfferAManualRetry() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        recovery.start()
        for (attempt, seconds) in [2.0, 5, 15].enumerated() {
            await gate.waitForCreationCount(attempt + 1); gate.failNext(with: .networkUnavailable); await settle()
            #expect(!recovery.offersManualRetry)
            clock.advance(by: .seconds(seconds))
        }
        await gate.waitForCreationCount(4); gate.failNext(with: .networkUnavailable); await settle()
        #expect(clock.pendingDelays.contains(.seconds(30)))
        #expect(recovery.offersManualRetry)
        recovery.retryNow(); await gate.waitForCreationCount(5)
        #expect(!recovery.offersManualRetry)
        gate.failNext(with: .networkUnavailable); await settle()
        await recovery.stop()
    }

    /// Wake and network changes must not loop on an account problem; an explicit Retry always tries again.
    @Test(arguments: [PlayerError.premiumRequired, .unknown]) func onlyAnExplicitRetryLeavesAFailure(_ error: PlayerError) async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1); gate.failNext(with: error); await settle()
        #expect(recovery.status == .failed(error))
        recovery.setNetworkAvailable(false); recovery.setNetworkAvailable(true); recovery.wake()
        clock.advance(by: .seconds(600)); await settle()
        #expect(gate.configurations.count == 1)
        recovery.retryNow(); await gate.waitForCreationCount(2)
        #expect(recovery.status == .connecting)
        gate.failNext(with: error); await settle()
        await recovery.stop()
    }
```

Then update the existing tests that assert the old one-second first delay:
- **`hasBeenReadyDistinguishesFirstConnectionFromReconnection`:** change `clock.advance(by: .seconds(1))` to `.seconds(2)`.
- **`forcedRefreshBudgetSurvivesNetworkRetry`:** change `clock.advance(by: .seconds(1))` to `.seconds(2)`.
- **`readinessTimesOutAt20SecondsAndStartupResolvedIsInsufficient`:** change `#expect(clock.pendingDelays.contains(.seconds(1)))` to `.seconds(2)`.
- **`networkChangesPreservePermanentFailure`:** it still holds for `.authDenied` and `.authExpired`, which reach `.needsReauthentication`. For `.premiumRequired`, `retryNow` now retries. Change its arguments to `[PlayerError.authDenied, .authExpired]` and remove the `.premiumRequired` branch of `expected`, so it reads:

```swift
        let expected: PlaybackConnectionStatus = .needsReauthentication
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `swift test --package-path Packages/BopifyCore --filter PlaybackRecoveryCoordinatorTests`

Expected: compile failure, because `recoveryRetryDelay(step:jitterUnit:)` and `offersManualRetry` are undefined.

- [ ] **Step 3: Implement.** In `PlaybackRecoveryCoordinator.swift`:

Replace the free function at the top with:

```swift
/// Nominal seconds before each retry: a first drop reconnects at once, repeated trouble escalates to five minutes.
let recoveryRetrySchedule: [Double] = [0, 2, 5, 15, 30, 60, 120, 300]
/// Drops older than this stop counting, so a session that recovers for good starts again from an immediate retry.
let recoveryDropWindow: TimeInterval = 600
/// Waits this long or longer offer the listener a manual retry.
let manualRetryThreshold: Double = 30

func recoveryRetryDelay(step: Int, jitterUnit: Double) -> Duration {
    let nominal = recoveryRetrySchedule[min(max(0, step), recoveryRetrySchedule.count - 1)]
    let unit = jitterUnit.isFinite ? min(1, max(0, jitterUnit)) : 0.5
    return .seconds(nominal * (0.5 + 0.5 * unit))
}
```

Replace these stored properties:

```swift
    @ObservationIgnored private var stableReady: Task<Void, Never>?
    ...
    private var failureCount = 0
    private var immediateRecoveryUsed = false
```

with:

```swift
    private var recentDrops: [TimeInterval] = []
    private var connectFailures = 0
    private var retryStep = 0
    public private(set) var offersManualRetry = false
```

Delete the `stableReady` property line, then remove every remaining `stableReady` use:
- in `reportSessionLoss`, the line `stableReady?.cancel()`;
- in `invalidate`, change `delay?.cancel(); deadline?.cancel(); stableReady?.cancel()` to `delay?.cancel(); deadline?.cancel()`;
- in `run`, delete the whole `stableReady?.cancel()` / `stableReady = Task { … }` block in the `.ready` branch, and with it the now-unused `let readyEpoch = player.engineEpoch`.

In `retryNow()`, delete the line:

```swift
        if case let .failed(error) = status, !error.canRetryCredentials { return }
```

In `reportSessionLoss`, replace:

```swift
        if bootstrap == nil {
            if immediateRecoveryUsed {
                failureCount = min(6, failureCount + 1)
                retryBeforeCreate = true
            } else { immediateRecoveryUsed = true }
        }
```

with:

```swift
        if bootstrap == nil {
            recentDrops.append(now())
            retryStep = dropStep()
            retryBeforeCreate = retryStep > 0
        }
```

In `run`'s `.ready` branch, after `rejectedToken = nil`, add `connectFailures = 0`.

In the `catch` block, replace:

```swift
                failureCount = min(6, failureCount + 1)
```

with:

```swift
                connectFailures += 1
                retryStep = dropStep() + connectFailures
```

Replace `waitForRetry()` with the following, and add `dropStep()` next to it:

```swift
    /// Counts drops inside the window, so a session that keeps failing escalates however long each connection lasts.
    private func dropStep() -> Int {
        let cutoff = now() - recoveryDropWindow
        recentDrops.removeAll { $0 <= cutoff }
        return max(0, recentDrops.count - 1)
    }

    private func waitForRetry() async {
        let step = min(retryStep, recoveryRetrySchedule.count - 1)
        let retry = recoveryRetryDelay(step: step, jitterUnit: randomUnit())
        BopifyLog.playback.info("recovery retry step=\(step, privacy: .public) delay=\(String(describing: retry), privacy: .public)")
        offersManualRetry = recoveryRetrySchedule[step] >= manualRetryThreshold
        defer { offersManualRetry = false }
        let sleep = self.sleep
        let waiting = Task { try await sleep(retry) }
        delay = waiting
        try? await waiting.value
        delay = nil
    }
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --package-path Packages/BopifyCore --filter PlaybackRecoveryCoordinatorTests`
Expected: all pass. Then run the full package: `swift test --package-path Packages/BopifyCore`. Expected: all pass. `PlayerRecoveryTests` uses the coordinator; fix any timing literal there that asserted the old 1 s first delay, using step 1 = 2 s.

- [ ] **Step 5: Commit**

```bash
git add Packages/BopifyCore/Sources/BopifyPlayback/PlaybackRecoveryCoordinator.swift Packages/BopifyCore/Tests/PlaybackTests
git commit -m "fix: back off across repeated playback drops" -m "A session that dropped every minute reconnected instantly forever, because 60 s of stable playback reset the backoff. Count drops in a 10-minute window, climb to a five-minute cap, and let Retry leave any failure, so a stuck connection no longer needs a relaunch."
```

---

### Task 3: Offer Retry now during long waits and on every failure

**Files:**
- Modify: `Bopify/Bopify/Views/PlaybackConnectionStatusView.swift`
- Modify: `Bopify/Bopify/AppEnvironment.swift:56`
- Modify: `Bopify/Bopify/Views/PlayerRootView.swift:110`, `Bopify/Bopify/Views/RecordPlayerView.swift:129`
- Test: `Bopify/BopifyAppTests/SignInRecordTests.swift` (`StartupConnectionTests`)

**Interfaces:**
- Consumes: `PlaybackRecoveryCoordinator.offersManualRetry` (Task 2).
- Produces: `PlaybackConnectionStatusView(…, offersRetry: Bool = false, …)` and `AppEnvironment.offersPlaybackRetry: Bool`.

- [ ] **Step 1: Write the failing tests.**

In `StartupConnectionTests`, extend the helper:

```swift
    private func connection(_ status: PlaybackConnectionStatus, restorationUnavailable: Bool = false,
                            isAuthorizing: Bool = false, offersRetry: Bool = false) -> PlaybackConnectionStatusView {
        PlaybackConnectionStatusView(status: status, restorationUnavailable: restorationUnavailable, hasConnected: true,
                                     onRetry: {}, onReconnect: {}, offersRetry: offersRetry, isAuthorizing: isAuthorizing)
    }
```

Replace `automaticRecoveryOffersNoManualRetry` with:

```swift
    /// Short waits retry on their own, so a manual retry would add nothing.
    @Test(arguments: [PlaybackConnectionStatus.connecting, .restoring, .reconnecting, .offline])
    func shortWaitsOfferNoManualRetry(status: PlaybackConnectionStatus) {
        #expect(connection(status).actionKey == nil)
    }

    @Test(arguments: [PlaybackConnectionStatus.connecting, .reconnecting, .offline])
    func longWaitsOfferRetryNow(status: PlaybackConnectionStatus) {
        #expect(connection(status, offersRetry: true).actionKey == "connection.retry")
    }

    @Test(arguments: [PlayerError.premiumRequired, .unknown, .networkUnavailable])
    func everyFailureOffersRetryNow(error: PlayerError) {
        #expect(connection(.failed(error)).actionKey == "connection.retry")
    }

    @Test func credentialFailuresKeepTheirOwnActions() {
        #expect(connection(.failed(.credentialCorrupt)).actionKey == "connection.reconnect")
        #expect(connection(.failed(.credentialUnavailable)).actionKey == "connection.retryCredentials")
    }
```

`StartupConnectionTests` needs `import BopifyDomain` for `PlayerError`; add it if the file lacks it.

- [ ] **Step 2: Run the tests and confirm they fail**

Run:
```bash
env -u RUSTUP_TOOLCHAIN ./scripts/build-rust.sh
xcodebuild -project Bopify/Bopify.xcodeproj -scheme BopifyAppTests -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test -only-testing:BopifyAppTests/StartupConnectionTests
```

Expected: compile failure, because of the extra argument `offersRetry`.

- [ ] **Step 3: Implement.** In `PlaybackConnectionStatusView`, add the stored property after `onReconnect`:

```swift
    /// Recovery is waiting long enough that the listener may want to try at once.
    var offersRetry = false
```

Replace `actionKey` with:

```swift
    var actionKey: String? {
        if isAuthorizing { return "signIn.cancel" }
        if offersRetry, [.connecting, .reconnecting, .offline].contains(status) { return "connection.retry" }
        return switch status {
        case .needsReauthentication, .failed(.credentialCorrupt): "connection.reconnect"
        case let .failed(error) where error.canRetryCredentials: "connection.retryCredentials"
        // Recovery never retries a failure on its own, so the listener always gets a way out.
        case .failed: "connection.retry"
        case .ready where restorationUnavailable: "connection.retryRestoration"
        // Recovery already retries short waits on its own, and as soon as the network returns.
        default: nil
        }
    }
```

In `AppEnvironment.swift`, below `var connectionStatus`, add:

```swift
    var offersPlaybackRetry: Bool { recovery?.offersManualRetry ?? false }
```

In `PlayerRootView.swift:110` and `RecordPlayerView.swift:129`, pass `offersRetry: environment.offersPlaybackRetry` after the `onReconnect:` argument.

- [ ] **Step 4: Run the tests and confirm they pass**

Run the `xcodebuild … -only-testing:BopifyAppTests/StartupConnectionTests` command from Step 2, then the whole `BopifyAppTests` scheme. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Bopify/Bopify Bopify/BopifyAppTests
git commit -m "feat: offer Retry now while playback waits to reconnect" -m "Long backoff waits and failures that recovery never retries on its own now show Retry now, so a listener is never left waiting minutes or stuck until a relaunch."
```

---

### Task 4: Rebase the fork onto upstream `dev`

**Files:** the fork working clone `.build/librespot-fork` (gitignored; not part of the Bopify commit history).

**Interfaces:**
- Produces: local branch `bopify` in `.build/librespot-fork`, rebased onto `upstream/dev`, with all fork tests passing.

- [ ] **Step 1: Prepare the clone**

```bash
git clone https://github.com/leesiongchan/librespot.git .build/librespot-fork
cd .build/librespot-fork
git switch bopify
test "$(git rev-parse HEAD)" = 7857e749cc83d4ac98ffe42e14dc3cdfa3cc18c9
git remote add upstream https://github.com/librespot-org/librespot.git
git remote add crmne https://github.com/crmne/librespot.git
git fetch upstream dev && git fetch crmne
```

- [ ] **Step 2: Rebase**

```bash
git rebase upstream/dev
```

Expected conflicts and their resolutions. During a rebase, `--ours` is the upstream base and `--theirs` is the fork commit being replayed.
- **`core/src/authentication.rs`:** take upstream's side. Upstream deleted the deprecation attribute after its dependency update.

  ```bash
  git checkout --ours core/src/authentication.rs
  ```
- **`connect/src/shuffle_vec.rs`:** keep the fork's deterministic `test_shuffle_with_first`. It asserts the exact swap at positions `0` and `MAX_RANGE - 1`, which the fork's `shuffle_with_seed` rewrite guarantees. Delete upstream's retry-loop version and its `get_shuffle_vec_without_and_with_first` helper if nothing else calls it (`rg get_shuffle_vec_without_and_with_first connect/`).
- **`Cargo.lock`:** take upstream's, then let cargo re-resolve only what the fork adds:

  ```bash
  git checkout --ours Cargo.lock
  env -u RUSTUP_TOOLCHAIN cargo metadata --format-version 1 >/dev/null
  ```

After each resolution, run `git add <files>` and `git rebase --continue`. Stop and report if any other file conflicts.

- [ ] **Step 3: Run the fork's own checks**

```bash
env -u RUSTUP_TOOLCHAIN cargo clippy --workspace --all-targets -- -D warnings
env -u RUSTUP_TOOLCHAIN cargo test --workspace --lib
env -u RUSTUP_TOOLCHAIN cargo test --workspace --doc
```

Expected: all pass. A failure in the fork's Bopify-specific connect tests after upstream #1795 (track selection) means the auto-merge changed behaviour. Investigate it, then fold the fix into the commit it belongs to:
1. Commit the fix with `git commit --fixup <that-commit>`.
2. Run `git rebase --autosquash upstream/dev`. Git ≥ 2.44 applies autosquash without an interactive editor.

- [ ] **Step 4: Record the result.** `git log --oneline upstream/dev..HEAD` must show the two Bopify commits.

---

### Task 5: Carry librespot#1800 and #1803

**Files:** `.build/librespot-fork` (`core/src/connection/mod.rs`, `core/src/socket.rs`, `core/Cargo.toml`, `Cargo.lock`).

**Interfaces:**
- Produces: two commits on local `bopify`, with bounded AP and dealer socket setup.

- [ ] **Step 1: Cherry-pick crmne's commits one at a time, and add the trailer right after each.** Their content matches the upstream PRs, and each brings its own tests.

```bash
git cherry-pick 9128951   # core: include socket setup in the access-point timeout
git commit --amend --no-edit --trailer "Upstream: librespot-org/librespot#1800"
git cherry-pick 54e6e0b   # core: bound socket setup and race IPv6 and IPv4
git commit --amend --no-edit --trailer "Upstream: librespot-org/librespot#1803"
```

Conflict handling:
- If `CHANGELOG.md` conflicts, keep the fork's `CHANGELOG.md` unchanged (`git checkout --ours CHANGELOG.md`). Changelog entries belong to upstream's merge.
- If `Cargo.lock` conflicts, take ours and re-resolve as in Task 4.

After either, run `git add` and `git cherry-pick --continue`, then the amend.

- [ ] **Step 2: Check the history.** `git log -2 --format='%s%n%(trailers:key=Upstream)'` shows each subject with its single `Upstream:` trailer.

- [ ] **Step 3: Run the tests**

```bash
env -u RUSTUP_TOOLCHAIN cargo test -p librespot-core --lib connection socket
env -u RUSTUP_TOOLCHAIN cargo clippy --workspace --all-targets -- -D warnings
```

Expected: the #1800 tests (socket setup counted inside the 5 s timer) and the #1803 tests (shared connect budget, IPv4 fallback) pass. The new edge `core → tower-service 0.3` must resolve to the `tower-service 0.3.3` already in the lockfile: `rg -n 'name = "tower-service"' -A1 Cargo.lock` shows one version.

---

### Task 6: Classify account-restricted AP logins

**Files:** `.build/librespot-fork/core/src/error.rs`

**Interfaces:**
- Produces: `librespot_core::error::AuthenticationFailure::AccountRestricted`. `Error::authentication_failure()` returns it for AP `LoginFailed` with `TravelRestriction`, `ApplicationBanned`, `InvalidAppKey` or `ExtraVerificationRequired`. Consumed by Task 8.

- [ ] **Step 1: Write the failing test.** Append to `core/src/error.rs`:

```rust
#[cfg(test)]
mod authentication_failure_tests {
    use super::*;
    use crate::{connection::AuthenticationError, protocol::keyexchange::ErrorCode};

    fn login_failure(code: ErrorCode) -> Option<AuthenticationFailure> {
        Error::from(AuthenticationError::LoginFailed(code)).authentication_failure()
    }

    #[test]
    fn login_failures_that_bar_the_account_are_restrictions() {
        for code in [
            ErrorCode::TravelRestriction,
            ErrorCode::ApplicationBanned,
            ErrorCode::InvalidAppKey,
            ErrorCode::ExtraVerificationRequired,
        ] {
            assert_eq!(login_failure(code), Some(AuthenticationFailure::AccountRestricted), "{code:?}");
        }
    }

    #[test]
    fn transient_login_failures_are_not_authentication_failures() {
        for code in [
            ErrorCode::ProtocolError,
            ErrorCode::TryAnotherAP,
            ErrorCode::BadConnectionId,
            ErrorCode::AccountExists,
        ] {
            assert_eq!(login_failure(code), None, "{code:?}");
        }
        assert_eq!(login_failure(ErrorCode::PremiumAccountRequired), Some(AuthenticationFailure::PremiumRequired));
        assert_eq!(login_failure(ErrorCode::BadCredentials), Some(AuthenticationFailure::InvalidCredentials));
    }
}
```

- [ ] **Step 2: Run and confirm it fails**

Run: `env -u RUSTUP_TOOLCHAIN cargo test -p librespot-core --lib authentication_failure_tests`
Expected: compile error, `no variant named AccountRestricted`.

- [ ] **Step 3: Implement.** Add the variant and match arm:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthenticationFailure {
    InvalidCredentials,
    PremiumRequired,
    /// Spotify will not let this account sign in here, and retrying cannot change that.
    AccountRestricted,
}
```

In `authentication_failure()`, add before `_ => None,`:

```rust
                ErrorCode::TravelRestriction
                | ErrorCode::ApplicationBanned
                | ErrorCode::InvalidAppKey
                | ErrorCode::ExtraVerificationRequired => Some(AuthenticationFailure::AccountRestricted),
```

- [ ] **Step 4: Run and confirm it passes**

Run: `env -u RUSTUP_TOOLCHAIN cargo test -p librespot-core --lib authentication_failure_tests` and `cargo clippy --workspace --all-targets -- -D warnings`. Expected: pass.

- [ ] **Step 5: Commit in the fork**

```bash
git add core/src/error.rs
git commit -m "core: report logins Spotify bars for this account" -m "Travel restrictions, banned applications, invalid app keys and required extra verification cannot clear by retrying. Classify them so clients stop reconnecting and tell the listener instead."
```

---

### Task 7: Checkpoint: publish the fork (user approval required)

- [ ] **Step 1: Stop and ask the user** to approve these exact commands. Show `git log --oneline upstream/dev..bopify` first.

```bash
cd .build/librespot-fork
git tag bopify-7857e74 7857e749cc83d4ac98ffe42e14dc3cdfa3cc18c9
git push origin bopify-7857e74
git push --force-with-lease=bopify:7857e749cc83d4ac98ffe42e14dc3cdfa3cc18c9 origin bopify
```

The tag keeps released Bopify builds pinned to `7857e74` fetchable after the branch moves.

- [ ] **Step 2: After approval and push,** record the new head: `git rev-parse HEAD`. Wait for the fork's `bopify.yml` workflow (`gh run list --repo leesiongchan/librespot --branch bopify --limit 1`) to pass before Task 8.

---

### Task 8: Retry everything except account problems

**Files:**
- Modify: `rust/Cargo.toml:12-15` (the four `rev = …` values), `rust/Cargo.lock`
- Modify: `rust/crates/bopify-core/src/engine.rs` (`classify_connect_error` and its tests)
- Modify: `rust/crates/bopify-core/src/error.rs`, `contracts/ffi-error-codes.json`
- Modify: `Packages/BopifyCore/Sources/BopifyDomain/PlayerError.swift`, `Packages/BopifyCore/Tests/PlaybackTests/LibrespotEngineTests.swift`, `Packages/BopifyCore/Tests/PlaybackTests/PlaybackRecoveryCoordinatorTests.swift`
- Modify: `Bopify/Bopify/Views/PlaybackConnectionStatusView.swift`, `Bopify/Bopify/PlayerError+Localized.swift`, `Bopify/Bopify/Localizable.xcstrings`

**Interfaces:**
- Consumes: `AuthenticationFailure::AccountRestricted` (Task 6), the published fork head (Task 7), and the contract (Task 1).
- Produces: `BopifyError::AccountRestricted` (code −6) and `PlayerError.accountRestricted`.

- [ ] **Step 1: Bump the pin.** Set all four `rev = "…"` values in `rust/Cargo.toml` to the new head from Task 7, then:

```bash
env -u RUSTUP_TOOLCHAIN cargo update --manifest-path rust/Cargo.toml -p librespot-core
git diff --stat rust/Cargo.lock
```

Expected: the lockfile changes only the librespot crates' `source` lines, the dependency edges brought by upstream's 17 commits, and `tower-service` under `librespot-core`. Report any version bump of an unrelated crate.

- [ ] **Step 2: Write the failing tests.**

Add to `engine.rs` tests:

```rust
    /// DNS, routes, Spotify outages and malformed answers can all clear on their own,
    /// so only account problems may stop recovery.
    #[test]
    fn only_account_problems_stop_recovery() {
        use std::io::{Error as Io, ErrorKind as IoKind};
        use librespot_core::Error as Lib;
        let retryable = [
            Lib::from(Io::from(IoKind::HostUnreachable)),
            Lib::from(Io::from(IoKind::NetworkUnreachable)),
            Lib::from(Io::from(IoKind::NetworkDown)),
            Lib::from(Io::other("failed to lookup address information")),
            Lib::from(Io::from(IoKind::UnexpectedEof)),
            Lib::from(Io::from(IoKind::InvalidData)),
            Lib::failed_precondition("TRY_AGAIN_LATER"),
            Lib::permission_denied("HTTP 403"),
            Lib::not_found("HTTP 404"),
            Lib::invalid_argument("HTTP 400"),
            Lib::unknown("HTTP 502"),
            Lib::internal("channel closed"),
        ];
        for error in retryable {
            let kind = error.kind;
            assert_eq!(classify_connect_error(error), BopifyError::NetworkUnavailable, "{kind:?}");
        }
        assert_eq!(classify_connect_error(Lib::unauthenticated("HTTP 401")), BopifyError::AuthInvalid);
    }
```

In `error.rs`, add `AccountRestricted` to the `all` array and `name` match in `codes_match_the_shared_wire_contract` (`AccountRestricted => "accountRestricted"`). Do not edit the JSON yet.

In `LibrespotEngineTests.mapsTheSharedFFICodesOntoTheErrorTaxonomy`, add `"accountRestricted": .accountRestricted` to `expected`.

In `PlaybackRecoveryCoordinatorTests`, change the arguments of `onlyAnExplicitRetryLeavesAFailure` to `[PlayerError.premiumRequired, .accountRestricted, .unknown]`.

In `StartupConnectionTests`, add `.accountRestricted` to `everyFailureOffersRetryNow`'s arguments.

- [ ] **Step 3: Run and confirm they fail**

```bash
env -u RUSTUP_TOOLCHAIN cargo test --manifest-path rust/Cargo.toml --locked -p bopify-core
swift test --package-path Packages/BopifyCore --filter 'LibrespotEngineTests|PlaybackRecoveryCoordinatorTests'
```

Expected:
- Rust fails to compile (`AccountRestricted` is missing, and the classifier's `match` is non-exhaustive against the fork's new variant).
- `only_account_problems_stop_recovery` would fail on `HostUnreachable → Unknown`.
- Swift fails to compile (`.accountRestricted` is missing).

- [ ] **Step 4: Implement Rust.**

In `error.rs`, add the variant `AccountRestricted` after `NetworkUnavailable`, with code `-6` and message `"Spotify will not let this account play here"`.

In `contracts/ffi-error-codes.json`, add `"accountRestricted": -6`.

Replace `classify_connect_error` in `engine.rs` with:

```rust
/// Only account problems are terminal: DNS, routes, Spotify outages and malformed
/// answers can all clear on their own, so recovery keeps retrying them.
fn classify_connect_error(err: librespot_core::Error) -> BopifyError {
    use librespot_core::error::{AuthenticationFailure, ErrorKind};
    let io_kind = err
        .error
        .downcast_ref::<std::io::Error>()
        .map(std::io::Error::kind);
    let error = match err.authentication_failure() {
        Some(AuthenticationFailure::PremiumRequired) => BopifyError::PremiumRequired,
        Some(AuthenticationFailure::InvalidCredentials) => BopifyError::AuthInvalid,
        Some(AuthenticationFailure::AccountRestricted) => BopifyError::AccountRestricted,
        None if err.kind == ErrorKind::Unauthenticated => BopifyError::AuthInvalid,
        None => BopifyError::NetworkUnavailable,
    };
    log::error!(
        "engine: spirc connect failed kind={:?} io_kind={io_kind:?} error={error:?}",
        err.kind
    );
    error
}
```

Leave `network_error_mentioning_credentials_is_not_a_token_rejection` as is; it still holds.

- [ ] **Step 5: Implement Swift.**

In `PlayerError.swift`, add `case accountRestricted` after `premiumRequired`, and in `init(ffiCode:)` add `case -6: self = .accountRestricted`.

In `PlaybackConnectionStatusView.messageKey`, add `case .accountRestricted: "error.accountRestricted"`.

In `PlayerError+Localized.swift`, add `case .accountRestricted: Text("error.accountRestricted")`.

In `Localizable.xcstrings`, add after `"error.authExpired"`, keeping keys sorted:

```json
    "error.accountRestricted" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Spotify won't let this account play here."
          }
        }
      }
    },
```

- [ ] **Step 6: Run everything**

```bash
env -u RUSTUP_TOOLCHAIN ./scripts/test-native.sh
env -u RUSTUP_TOOLCHAIN ./scripts/build-rust.sh
swift test --package-path Packages/BopifyCore
xcodebuild -project Bopify/Bopify.xcodeproj -scheme BopifyAppTests -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Release -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
```

Expected: all pass. Report actual counts.

- [ ] **Step 7: Commit**

```bash
git add rust contracts Packages Bopify
git commit -m "fix: keep reconnecting through DNS and route failures" -m "Unrecognised connect errors such as an unreachable host or a failed DNS lookup ended playback recovery until a relaunch. Only account problems now stop recovery; everything else retries with backoff." -m "Rebase the librespot fork on upstream dev and carry librespot#1800 and #1803, so a blackholed access point times out in 5 s instead of consuming the whole login deadline. Spotify login refusals that cannot clear (travel restriction, banned app, extra verification) show their own message."
```

---

### Task 9: Manual verification (user runs the app)

- [ ] **Route failure on wake.** Play, turn Wi-Fi off for 30 s, then on. Expect "Reconnecting…", then playback resumes, and never "Something went wrong."
- [ ] **Blackholed AP.**
  1. Find the AP the app connects to: `log stream --predicate 'subsystem == "com.leesiongchan.bopify"' --level debug`, then reconnect.
  2. Blackhole its address: `sudo route add -host <ap-ip> 127.0.0.1 -blackhole`.
  3. Trigger a reconnect (toggle Wi-Fi).
  4. Expect login to move to the next AP within about 5 s per attempt and playback to recover.
  5. Clean up: `sudo route delete -host <ap-ip>`.
- [ ] **Long wait.** Keep Wi-Fi associated but with no internet (for example, a phone hotspot with mobile data off) for 3 minutes. Expect "Retry now" to appear once waits reach 30 s, and pressing it to try at once.
- [ ] **Check the logs.** `connect failed kind=… io_kind=…` shows kinds only, with no URLs, tokens or usernames.

Report each result. Anything not run is reported as unverified.
