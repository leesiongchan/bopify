# Soloist Feasibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish whether Bopify can reliably correlate a local Soloist process with its authorized Spotify account/device and fetch librespot data while Soloist keeps playing.

**Architecture:** Build an opt-in developer probe separate from the shipping app. A Swift executable uses existing OAuth primitives, observes Soloist and Web API state, and runs a data-only Rust integration probe through private pipes. It records sanitized evidence; neither successful unit tests nor a plausible correlation hypothesis counts as passing the live gates.

**Tech Stack:** macOS 26+, Apple Silicon, Swift 6, Foundation/Network/Security, existing BopifyAuth and BopifyDomain, Rust 1.99.1, Tokio, serde, and the existing pinned librespot fork. No new external dependency.

**Spec:** `docs/superpowers/specs/2026-11-06-soloist-playback-design.md`

## Global Constraints

- "Use Soloist whenever possible, with librespot filling gaps."
- "This is a macOS Apple Silicon feature within Bopify's existing macOS 26 minimum."
- "No new dependency is proposed."
- "Never identify it by display name alone or send a targeted command with `device_id` omitted."
- "A display-name match or user confirmation alone is insufficient proof."
- "The first implementation plan is limited to proving account/device correlation and a data-only companion alongside real Soloist on an Apple Silicon Mac."
- "Do not read stored credentials opportunistically, embed a key, download or run a binary for a design-only exercise, or use mocked results as evidence of live integration."
- "Do not clear quarantine, use shell execution, or bypass a failed trust check."
- "Shut down only processes Bopify owns."
- "Plan the remaining implementation only after both checks pass."
- Preserve the existing app, OAuth grants, Keychain items, registered `http://127.0.0.1:8898/callback` redirect URI, lockfiles, and unrelated appearance changes. Do not wire the probe into `AppEnvironment`.

## Review Focus

1. Two devices share a name, or a cached ID has changed: ambiguous evidence must never authorize control. Task 1 tests both.
2. OAuth tabs sign into different accounts or a profile lacks `account_id`: no mixed-account probe. Task 1 tests both.
3. A phone takes playback during correlation or data requests: terminate the attempt without reclaiming playback. Task 1 tests ownership invalidation; Task 3 checks it live.
4. Soloist keeps playing after its WebSocket closes: report incomplete evidence without launching another audio engine. Task 1 tests loss of observation; Task 3 checks it live.
5. Cancellation or child failure exposes secrets or leaves a probe process running: clean up owned resources and emit only sanitized outcomes. Tasks 1 and 2 cover lifecycle and report boundaries.

---

## File map and interfaces

| File | Responsibility |
| --- | --- |
| `tools/SoloistFeasibility/Package.swift` | Separate executable/test package; local dependency `../../Packages/BopifyCore`, executable `soloist-feasibility`; no new remote package. |
| `tools/SoloistFeasibility/Sources/SoloistFeasibility/ProbeMain.swift` | Parse non-secret flags, run the sequence, and return process exit status. |
| `tools/SoloistFeasibility/Sources/SoloistFeasibility/ProbeAuthorization.swift` | Fresh in-memory PKCE grants using BopifyAuth primitives; no production credential stores. |
| `tools/SoloistFeasibility/Sources/SoloistFeasibility/ProbeObservation.swift` | Owned Soloist lifecycle, bounded WebSocket reads, `/me`, device and playback reads. |
| `tools/SoloistFeasibility/Sources/SoloistFeasibility/ProbeEvidence.swift` | Typed observation records, correlation evaluation, sanitized report, and companion-child invocation. |
| `tools/SoloistFeasibility/Tests/SoloistFeasibilityTests/ProbeEvidenceTests.swift` | Offline correlation and report tests. |
| `tools/SoloistFeasibility/Tests/SoloistFeasibilityTests/ProbeLifecycleTests.swift` | Offline cancellation, auth/HTTP boundaries, child cleanup, and observation loss tests. |
| `tools/SoloistFeasibility/README.md` | Exact build/run instructions, key-file handling, interactive steps, and interpretation. |
| `rust/crates/bopify-core/src/soloist_feasibility.rs` | Test-only data session and explicit live integration entry point, using existing crate-private data resolvers. |
| `rust/crates/bopify-core/src/lib.rs` | Register `#[cfg(test)] mod soloist_feasibility;`; no production exports or FFI changes. |
| `docs/superpowers/specs/2026-11-06-soloist-playback-design.md` | Replace unproven assumptions with observed results, or record why a gate failed. |

All Swift probe interfaces below are internal to the new executable target. Existing application protocols remain unchanged.

### Task 1: Correlate an owned Soloist process with fresh account observations

**Files:** Create the Swift package, its four source files, both test files, and README from the file map.

**Interfaces:**

- `ProbeAuthorization.authorize(clientID: String, scopes: Set<String>, callbackPort: UInt16?, callbackPath: String) async throws -> TokenSet` uses `PKCEPair`, `AuthorizationRequest`, `LoopbackCallbackListener`, and `TokenClient.exchange`. Stop the listener on every exit. Keep grants in memory only.
- `ProbeObservation.account(accessToken: String) async throws -> String` returns only nonempty `/me.account_id` in memory, never a display name, email, or legacy `id` substitute.
- `ProbeObservation.devices(accessToken: String) async throws -> Set<ProbeDevice>` and `playback(accessToken: String) async throws -> ProbePlayback?` read the documented endpoints. `ProbeDevice` contains optional ID, name, active/restricted flags. `ProbePlayback` contains device ID, item/context URI, playing flag, position, and local observation time.
- `ProbeObservation.startSoloist(executable: URL, keyFile: URL, directory: URL, deviceName: String) async throws -> OwnedSoloistProbe` validates the executable/key file, creates its own private directories, and starts the process. The owned object provides `snapshot() async throws -> SoloistProbeSnapshot` and `stop() async`; its snapshot contains paired/active flags, URI, position, status, and local observation time.
- `CorrelationEvidence` contains optional `streamingAccountID`/`webAccountID`, `beforeDevices`/`afterDevices` sets, the owned-process lifecycle generation, and paired Soloist/Web API playback samples.
- `ProbeVerdict: Equatable` is `passed`, `failed(reason: String)`, or `inconclusive(reason: String)`; `evaluateCorrelation(_ evidence: CorrelationEvidence) -> ProbeVerdict` never performs I/O. Fixed reasons include `accountMismatch`, `missingAccountID`, and `noNewDevice`.
- `ProbeReport` is Codable and contains schema version `1`, platform/build versions, gate verdicts, counts/timings, and fixed reason codes. No tokens, keys, account/device IDs, raw URLs, titles, lyrics, or raw service responses.

- [x] **Step 1: Write offline behavioral tests.** Define test-local `validEvidence() -> CorrelationEvidence` with matching account IDs, a new unrestricted device, the owned lifecycle, and fresh advancing matched samples. Start with these assertions:

  ```swift
  @Test func aNameMatchWithoutANewDeviceIsInconclusive() {
      var evidence = validEvidence()
      evidence.afterDevices = evidence.beforeDevices
      #expect(evaluateCorrelation(evidence) == .inconclusive(reason: "noNewDevice"))
  }
  @Test func differentAccountsCannotBeCombined() {
      var evidence = validEvidence()
      evidence.webAccountID = "another-account"
      #expect(evaluateCorrelation(evidence) == .failed(reason: "accountMismatch"))
  }
  @Test func missingAccountIDIsNotAUsernameFallback() {
      var evidence = validEvidence()
      evidence.streamingAccountID = nil
      #expect(evaluateCorrelation(evidence) == .inconclusive(reason: "missingAccountID"))
  }
  ```

  Add a passing valid-evidence case and rejection cases for multiple candidates, null ID, restricted device, stale sample, mismatched item, process restart, unpairing, and remote takeover. Assert sentinel secrets and raw identifiers never appear in encoded reports or captured diagnostics.
- [x] **Step 2: Run the failing tests.** `swift test --package-path tools/SoloistFeasibility`. Expected: target builds far enough to identify missing probe interfaces/behavior, then fails. Build the existing native artifact with `./scripts/build-rust.sh` first if needed for the local package dependency; do not label a missing artifact as the intended behavioral failure.
- [x] **Step 3: Implement the probe.** Support only `--soloist PATH`, `--key-file PATH`, `--client-id ID`, and optional `--report PATH`. The key file must be a user-owned regular file with permissions `0600`; never print its content. Assess the selected arm64 executable with macOS trust checks before executing `--version`; do not download, import, replace, or re-sign it.

  Use a fresh temporary `0700` data/cache directory and a unique `Bopify probe <UUID>` device name. Start Soloist with explicit directories, `--ws 127.0.0.1:0`, initial volume `0`, and a bounded cache of `100` MB. Keep the API key out of logs; acknowledge that Soloist requires it in its child-process arguments. Validate runtime endpoint files and connect only to the owned generation on loopback. Bound individual network/process operations to 30 seconds, interactive sign-in/pairing to five minutes, and WebSocket messages to 1 MiB.

  Request a fresh first-party `streaming` grant and a fresh user-client grant with `user-read-playback-state`/`user-modify-playback-state`. Use the existing first-party dynamic `/login` callback and the unchanged user-client fixed callback. Compare `/me.account_id` for both grants before starting companion requests. If either token cannot access the required identifier, mark the gate inconclusive with the actual status; do not silently add scopes, substitute usernames, or read production grants. Reject cross-origin HTTP redirects; honor `Retry-After` without retrying mutating commands.

  Correlation is an experiment: record the device baseline before starting the fresh process; let the user pair it and initiate playback in Spotify; require a unique new nonrestricted device ID associated with the owned lifecycle, matched active state and item, and at least two advancing playback samples. Samples must be at most two seconds old and positions must agree within two seconds after timestamp adjustment. The unique name only narrows candidates. Revoke evidence on auth/process generation changes, stale observations, or a different active device. Record whether supported observations actually establish the claimed association; do not turn the hypothesis into a success assumption.

  After the first correlation, restart the owned daemon once with the same private data directory and revalidate the mapping from fresh observations. The previously established ID may now appear in the baseline; require the previously demonstrated mapping plus the new owned generation and matched playback, rather than falsely requiring a second newly created device. Do not reuse pre-restart evidence.
- [x] **Step 4: Verify boundaries offline.** Run `swift test --package-path tools/SoloistFeasibility`; expected all offline tests pass. Include canceled OAuth, denied scope, null playback, a lost WebSocket with a live process, malformed/oversize frames, wrong endpoint address, a failed trust check, and child exit. No test starts a real Spotify session or another audio engine. Use a test process under probe ownership to demonstrate that cleanup waits for termination and never signals a pre-existing process.
- [x] **Step 5: Commit this reusable developer probe.** Stage only the new tool; use `test: add Soloist account correlation probe`. Do not claim the live identity gate has passed.

### Task 2: Fetch existing librespot services without constructing playback

**Files:** Create `rust/crates/bopify-core/src/soloist_feasibility.rs`; modify only test registration in `src/lib.rs` and the probe's `ProbeEvidence.swift`/README.

**Interfaces:**

- Test-only `ProbeInput { access_token: String, track_uri: String }` is decoded from a maximum 16 KiB stdin payload, never arguments or environment. Do not derive `Debug` or print it.
- `fn read_probe_input(reader: impl std::io::Read) -> Result<ProbeInput, ProbeFailure>` enforces that payload bound and validates a canonical track URI before any login. `ProbeFailure` implements `PartialEq` and has `MissingInput`, `InputTooLarge`, and `InvalidTrack` variants, in addition to fixed service/lifecycle reasons.
- `async fn probe_services(input: ProbeInput) -> Result<CompanionReport, ProbeFailure>` uses `Session::new(SessionConfig::default(), None)`, `Credentials::with_access_token`, and `session.connect(credentials, false)`. Bound login to 30 seconds. Obtain the token only from the freshly matched grant in Task 1.
- Call existing `lyrics::resolve(&SessionLyrics(session.clone()), track, 1)`, `radio::resolve(&SessionRadio(session.clone()), seed, 2)`, and `artist::resolve(&SessionArtist(session.clone()), track, 0, 3)`. Keep their existing 30-second resolver deadlines. Never call `Engine::new`, `Player::new`, `Spirc::new`, a mixer, or playback/Connect registration methods.
- `CompanionReport` serializes schema version `1`, service outcomes/counts and elapsed times only. Missing lyrics/radio is reported accurately and is not a successful retrieval. `ProbeFailure` contains fixed reason codes without source response text.
- Explicit live entry: `soloist_feasibility::live_data_session` is an ignored Rust test invoked by the Swift runner with `cargo test --manifest-path rust/Cargo.toml --locked -p bopify-core --lib soloist_feasibility::live_data_session -- --ignored --exact --nocapture --test-threads=1`. Its only environment path is `BOPIFY_SOLOIST_PROBE_RESULT_PATH`, a new private result file; secrets travel through the runner-owned stdin pipe. An absent/invalid input fails when invoked. Ordinary CI never claims this opt-in test as live coverage.
- `ProbeEvidence.runCompanion(accessToken: String, trackURI: String, repository: URL) async throws -> CompanionReport` invokes Cargo directly with `Process`, sends the private payload, captures and sanitizes diagnostics, bounds total execution to 150 seconds after precompilation, and removes its result file. The runner continues observing Soloist while the child works.

- [x] **Step 1: Write failing offline boundary tests.** Start with:

  ```rust
  #[test]
  fn rejects_missing_or_oversized_probe_input() {
      assert!(matches!(read_probe_input(&b""[..]), Err(ProbeFailure::MissingInput)));
      assert!(matches!(read_probe_input(&vec![b'x'; 16_385][..]), Err(ProbeFailure::InputTooLarge)));
  }
  ```

  Add `rejects_non_track_uri` asserting `InvalidTrack` for a valid JSON request containing an artist URI, and `report_excludes_sensitive_payloads` asserting sentinel token/lyric/account strings cannot occur in serialized results. Do not use a fake session to claim coexistence.
- [x] **Step 2: Run the tests and confirm behavioral failure.** `cargo test --manifest-path rust/Cargo.toml --locked -p bopify-core --lib soloist_feasibility::`. Expected: failures for the new boundary behavior while the live entry is explicitly ignored.
- [x] **Step 3: Implement the test-only session and Swift bridge.** Reuse existing response variants and normalization; retain only success/failure counts in the report. Call `session.shutdown()` on completion/error, then join the probe runtime on the test thread. On cancellation, Swift terminates only its Cargo/process group and waits for exit; never leave the ignored test holding an authenticated session. Do not install a logger that can print raw dependency responses. The probe requests data and never commands playback.
- [x] **Step 4: Verify.** Run the Rust filtered offline tests, the Swift probe tests including a canceled/failing companion child, and `./scripts/test-native.sh`. Expected: offline tests and existing native checks pass; live feasibility is still unverified. Confirm shipping source diff consists only of `#[cfg(test)]` registration and that the lockfile/FFI are unchanged.
- [x] **Step 5: Commit.** Stage only Task 2 files; use `test: probe librespot services without playback`.

### Task 3: Run both live gates and record evidence

**Files:** Update the design and tool README. Write any report first to a private temporary path; commit only sanitized results described in the design, never raw captures or credential files.

**Interfaces:** Consume the Task 1 executable and Task 2 child. Produce a dated pass/fail/inconclusive outcome for each feasibility gate, the tested build versions, the successful correlation procedure if any, and explicit remaining limits.

- [ ] **Step 1: Check live prerequisites.** Use only the user's explicitly supplied Soloist executable/key-file path and developer client ID. If any are unavailable, finish and verify the probe code, mark live checks unrun, and request these inputs without asking for secrets in chat. Do not search Keychain, browser storage, download directories, or other accounts for credentials. Keep the current Bopify app out of the experiment and do not terminate it automatically.
- [ ] **Step 2: Build before sign-in.** Run `./scripts/build-rust.sh`, `swift build --package-path tools/SoloistFeasibility`, and `cargo test --manifest-path rust/Cargo.toml --locked -p bopify-core --lib soloist_feasibility::live_data_session --no-run` before supplying credentials. Expected: executable and test binary compile using the locked dependencies. The live invocation is `swift run --package-path tools/SoloistFeasibility soloist-feasibility --soloist <executable-path> --key-file <private-key-file-path> --client-id <public-client-id>`; supply actual paths through properly quoted tool arguments. Start it only after the user is ready to pair/select playback; the key value itself is never placed in a shell command.
- [ ] **Step 3: Run account/device correlation.** Pair the uniquely named probe through Spotify. Use the user's chosen music/volume in Spotify after the probe starts muted. Require the observed evidence described in Task 1. Repeat after restarting the owned daemon with its same private data directory to see whether the mapping remains valid; refresh device discovery rather than assuming IDs persist. Repeat with a second account if available to demonstrate rejection; if unavailable, record that negative case as unit-tested only. A missing identifier, nondiscoverable/restricted device, or ambiguous relationship leaves the gate inconclusive and blocks full-feature planning.
- [ ] **Step 4: Run companion coexistence after correlation passes.** Let Soloist play while the Rust probe performs all three lookups. Observe fresh account playback and Soloist state before, during, and after for at least 30 seconds; require continued Soloist ownership and position advancement and no new Connect device attributable to librespot. Use tracks known by the user to have lyrics/radio/artist results; record genuine absence without converting it into a pass. Stop the companion and verify Soloist continues. Have the user move playback to a phone during a separate run; require the probe to invalidate the attempt and never reactivate itself. Disconnect only the probe WebSocket during another run; require incomplete observation with no second audio engine. Natural track transitions should refresh the observation baseline, not appear as unexplained jumps.
- [ ] **Step 5: Inspect and document results.** Have the listener confirm whether audio remained continuous, and distinguish that observation from state/position evidence. Remove probe-owned temporary authentication/data/cache directories after processes stop; never remove the supplied key file or binary. Update the design's feasibility section with actual evidence and the current-profile `account_id` linkage rule. If either gate fails or remains inconclusive, record the narrow blocker and stop broader implementation planning. If both pass, record that later routing, queue, recovery, installation, and UI work still require their own plan.
- [ ] **Step 6: Verify the final state and commit.** Run both offline probe suites, `git diff --check`, and review the complete diff and sanitized report for secrets and unrelated changes. Run `swift test --package-path Packages/BopifyCore` and the `BopifyAppTests` Xcode scheme as existing integration checks if the execution changes any shared code beyond test registration; record precisely what ran. Commit only the evidence/design updates with `docs: record Soloist feasibility findings`.

## Scope and handoff

This plan deliberately does not implement the hybrid engine, change app authorization/scopes, ship an installer/updater, alter queue UI, or implement automatic audio handoffs. Those requirements are deferred by the approved design until the two live gates pass. A failure is a useful feasibility result; it must not be hidden behind a fallback or reported as a completed Soloist feature.

Recommend **native execution**: the three tasks share one observation/report contract, require interactive live pairing, and are smaller than the full feature. Keep all user changes outside the task commits. The user approved native execution on 2026-11-06. Tasks 1 and 2 are implemented and verified offline; Task 3 live checks await explicitly supplied inputs.

## Research notes

Rechecked official sources 2026-11-06:

- [Current User's Profile](https://developer.spotify.com/documentation/web-api/reference/get-current-users-profile) explicitly identifies immutable `account_id` as the account-linking field and warns against using `id`. Treat missing `account_id` as unproven linkage, not permission to substitute a legacy username.
- [Available Devices](https://developer.spotify.com/documentation/web-api/reference/get-a-users-available-devices) allows null IDs, warns that IDs can change, and says restricted devices reject Web API controls. The probe tests these cases.
- [Soloist WebSocket API](https://developer.spotify.com/documentation/soloist/reference/websocket-api) supplies paired/active flags and playback observations but no account identifier or Connect device ID. The lifecycle correlation method remains an experimental hypothesis until observed and reviewed.
- The pinned librespot `Session::connect(credentials, false)` and `Session::shutdown()` are available independently of Spirc. Existing lyric/radio/artist resolvers already accept the underlying `Session`; live usability without playback initialization remains unverified.
