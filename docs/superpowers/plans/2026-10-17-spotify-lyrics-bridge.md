# Spotify Lyrics Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Expose real Spotify lyric retrieval through Bopify's existing Rust–Swift playback-engine boundary, with validated data and bounded request lifetimes.

**Architecture:** Extend the current radio request/reply pattern with a separate lyric channel. Rust calls the pinned `librespot_metadata::Lyrics::get` on the engine-owned session, normalizes its result and emits correlated replies; Swift decodes typed domain values and manages cancellation, identity checks, deadlines and teardown. Keep radio behavior, authentication and the Debug-only ribbon unchanged.

**Tech Stack:** Swift 6, Swift Testing, Rust 1.99.0, Tokio, Serde, pinned librespot, existing C ABI/XCFramework, Xcode 27/macOS 26.

**Spec:** [Approved bridge design](../specs/2026-10-17-spotify-lyrics-bridge-design.md).

**Execution:** Native, preserving the user's choice: implement in this session, then one fresh whole-change review. Stay on `main`, commit cohesive completed tasks, and push directly; no worktree or PR.

## Global Constraints

- Dependency remains pinned at `939dc5ee9d833e1980f9495241219d9d4868a061`; no new product dependencies or authentication changes.
- Rust retrieval/normalization deadline: 30 seconds. Swift watchdog: 35 seconds, cancelled on every completion path.
- Maximum normalized result: 2,000 lines and 256 KiB of total UTF-8 lyric text; reject larger results as unavailable.
- Preserve original line order, duplicate timestamps, empty lines, provider attribution, language and RTL metadata.
- Timed starts must be nonnegative `Int64`; unsynced starts are `nil`/JSON `null`. Do not invent line endings or instrumental status.
- Canonical Spotify track URIs only. Missing lyrics → `noLyrics`; transient failure/deadline → `network`; unsupported/forbidden/malformed content → `unavailable`.
- Lyric service failure must not log the user out, interrupt playback or enter the playback-event stream. Never log lyric bodies or credentials.
- The native ribbon remains Debug-only. Live ribbon observation, release UI, seek tracking, caching and other lyric features are outside this increment.

## Review Focus

- A lyric reply must not resolve a simultaneous radio request with the same numeric ID; pin cross-channel separation in Task 3.
- A synchronous callback must not leave an orphan watchdog after completion; pin timer cleanup and advance-after-completion in Task 3.
- Non-ASCII words must be bounded by UTF-8 bytes rather than character count; pin exact and over-limit cases in Task 2.
- Negative, overflowing or partially numeric starts must fail the whole timed response; pin `-1`, `9223372036854775808` and `1000ms` in Task 2.
- A reply without a usable ID must not strand its caller forever; pin missing/invalid envelope IDs and watchdog expiry in Task 3.

## File Structure

| Files | Responsibility |
| --- | --- |
| New `Packages/BopifyCore/Sources/BopifyDomain/TrackLyrics.swift` | Immutable lyric values, synchronization/failure enums and lyric wire decoding |
| New `Packages/BopifyCore/Tests/DomainTests/LyricReplyTests.swift` | Domain/wire contract tests using original test words |
| New `rust/crates/bopify-core/src/lyrics.rs` | Session adapter, URI validation, normalization, error mapping, bounded resolver and owned-boundary unit tests |
| Existing Rust `lib.rs`, `event.rs`, `engine.rs`, `ffi.rs` | Module registration, wire variants, engine dispatch and additive C entry point |
| Existing `PlaybackEngine.swift`, `LibrespotEngine.swift`, `EventBridge.swift` | Public request, FFI invocation and separate lyric waiter lifecycle |
| New `Packages/BopifyCore/Tests/PlaybackTests/EventBridgeLyricsTests.swift` | Callback correlation, identity, cancellation, watchdog and teardown tests |
| Existing `EventBridgeTests.swift` | Generated-header/FFI smoke assertions |
| Existing engine conformers listed in Task 3 | Explicit unsupported behavior in previews and unrelated test doubles |
| Existing `docs/spotify-lyrics-probe.md` | Record completed bridge verification separately from the earlier standalone probe |

## Task 1: Define the Swift Lyric Contract

**Files:** Create `TrackLyrics.swift` and `LyricReplyTests.swift` at the paths above. Read `SpotifyURI.swift`, `RadioMix.swift` and `RadioReplyTests.swift` first.

**Interfaces:**

- Produce `LyricSynchronization: String, Codable, Hashable, Sendable` with `.lineSynced` and `.unsynced`.
- Produce `TrackLyricLine: Hashable, Sendable` with public `let text: String`, `let startTimeMs: Int64?`, and `init(text:startTimeMs:)`.
- Produce `TrackLyrics: Hashable, Sendable` with the spec's seven fields and an explicit public initializer accepting those fields by name.
- Produce `LyricFailure: String, Error, Hashable, Sendable` with `.noLyrics`, `.network`, `.unavailable`.
- Produce `LyricReply: Hashable, Sendable, Decodable`: `.lyrics(requestID: UInt64, TrackLyrics)` and `.failed(requestID: UInt64, trackURI: SpotifyURI, LyricFailure)`, plus `requestID`, `trackURI` and `eventTypes == ["lyrics", "lyricsFailed"]` as a set.

- [x] **Step 1: Write failing domain/wire tests.** Use the spec's JSON examples and original words. `timedReplyPreservesOrderAndAttribution` supplies starts `[1000, 1000, 2000]`, including an empty second line, and asserts decoded ordering, words, request ID, track URI, provider fields, language and RTL. `unsyncedReplyHasNoStarts` supplies null starts and asserts `lines.allSatisfy { $0.startTimeMs == nil }`. `unknownFailureBecomesUnavailable` asserts `.failed(requestID: 42, trackURI: track, .unavailable)` for a new reason. Parameterized rejection tests assert `DecodingError` for a non-track URI, unknown synchronization mode, missing required metadata, negative/missing timed starts and non-null unsynced starts. Reuse only test-local fixture helpers; define their inputs explicitly.
- [x] **Step 2: Run `swift test --package-path Packages/BopifyCore --filter LyricReplyTests`.** Confirm the missing lyric contract is the failure; fix test typos or unrelated compilation errors before proceeding.
- [x] **Step 3: Implement the types and `LyricReply.init(from:)` in `TrackLyrics.swift`.** Follow `RadioMix.swift`'s manual wire decoder. Require `SpotifyURI.kind == .track` without changing the shared URI parser; Rust owns canonical base-62 validation. Decode the exact keys in the approved JSON, preserve response order and enforce synchronization/start consistency. Unknown failure reasons fold into unavailable; missing or wrongly typed required keys fail decoding.
- [x] **Step 4: Run the new suite and `swift test --package-path Packages/BopifyCore --filter 'LyricReplyTests|RadioReplyTests'`.** Expect every selected test to pass. The public engine protocol is not changed yet, so existing conformers remain buildable.
- [x] **Step 5: Commit the domain file and tests.** Suggested subject: `Define typed Spotify lyric replies`.

## Task 2: Add the Bounded Rust Request and C ABI

**Files:** Create `rust/crates/bopify-core/src/lyrics.rs`; modify `lib.rs`, `event.rs`, `engine.rs`, `ffi.rs`. Read `radio.rs`, the pinned SDK lyric types, and existing FFI guard tests first. Generated `artifacts/` files come only from `scripts/build-rust.sh`.

**Interfaces:**

- Consume Task 1's wire names and enum values, exactly as written in the spec.
- In `lyrics.rs`, define public serializable `WireLyrics`, `WireLyricLine`, `LyricSynchronization`, `LyricFailure` with camelCase fields/values; `WireLyrics` carries the same seven fields as `TrackLyrics`. Lines have `text: String`, `start_time_ms: Option<i64>`; serialize unsynced `None` as explicit null.
- Define `pub(crate) fn parse_track(raw: &str) -> Option<SpotifyUri>` and `fn normalize(track_uri: String, lyrics: librespot_metadata::Lyrics) -> Result<WireLyrics, LyricFailure>`.
- Define `LyricSource: Clone + Send + Sync + 'static` with `fn lyrics(&self, id: &SpotifyId) -> impl Future<Output = Result<librespot_metadata::Lyrics, LyricFailure>> + Send`; `SessionLyrics(pub Session)` calls `Lyrics::get` and maps its error.
- Define `pub(crate) async fn resolve<S: LyricSource>(source: &S, track: SpotifyUri, request_id: u64) -> WireEvent`, backed by private `resolve_within(..., limit: Duration)` for deterministic timeout tests. The production wrapper passes `Duration::from_secs(30)`.
- Extend `WireEvent` with `Lyrics { request_id, lyrics: WireLyrics }` using `#[serde(flatten)]` for the lyric fields, and `LyricsFailed { request_id, track_uri, reason }`. Explicitly rename acronyms to `requestID` and `trackURI`.
- Add `Engine::request_lyrics(&self, track_uri: &str, request_id: u64) -> Result<(), BopifyError>` and `bopify_request_lyrics(handle: *mut BopifyEngine, track_uri: *const c_char, request_id: u64) -> i32`.

- [x] **Step 1: Register `mod lyrics;` in `lib.rs` and write failing adapter tests in `lyrics.rs`.** This makes the new tests discoverable before implementing `normalize`/`resolve`. Construct SDK values with original test words. Assert timed starts `[Some(1000), Some(1000), Some(2000)]`, preserved blank lines/RTL/provider metadata and unsynced starts `[None, None]`. Invalid timed `"-1"`, `"9223372036854775808"`, `"1000ms"` and `""` each yield `Err(LyricFailure::Unavailable)`. Exactly 2,000 lines pass; 2,001 fail. Exactly 262,144 total UTF-8 bytes pass; 262,145 fail, including a multibyte fixture. Whitespace-only content yields `NoLyrics`. Canonical track round-trips pass `parse_track`; other kinds, local URIs, garbage and suffixes fail.
- [x] **Step 2: Add resolver/wire/FFI tests.** A controlled `LyricSource` returns success or each failure and verifies the requested ID. A never-completing source plus paused Tokio time yields `Network` at the supplied deadline. Assert the serialized JSON equals the approved flat shape, including explicit null starts and acronym spelling. Extend existing FFI guard tests: null URI returns `InvalidArgument`; a valid URI on a destroyed handle returns `SessionLost`, while a null handle preserves the existing `InvalidArgument` result. Do not authenticate in unit tests.
- [x] **Step 3: Run `rustup run 1.99.0 cargo test --manifest-path rust/Cargo.toml --locked --lib -p bopify-core lyrics::`.** Observe missing implementation failures, not unrelated dependency errors. Run the new wire/FFI tests by their concrete test names once added.
- [x] **Step 4: Implement normalization and error mapping.** Parse with the SDK URI parser, require the round-trip string to match, and accept only `SpotifyUri::Track { .. }`. Use the SDK result directly; no raw HTTP or new deserializer. Enforce the exact limits before serialization. Map `NotFound` to `NoLyrics`; `DeadlineExceeded`, `Unavailable`, `Aborted`, `ResourceExhausted` to `Network`; other SDK errors to `Unavailable`. Log request IDs and failure categories, not payloads.
- [x] **Step 5: Implement dispatch and FFI.** Clone the engine-owned session and wrapped sink, spawn `resolve` on its existing runtime and return after enqueueing. Reuse `str_from`, `with_engine`, safety documentation and lifecycle guards. Do not change radio, `EngineReporter`, credential storage or session configuration.
- [x] **Step 6: Run `rustup run 1.99.0 cargo test --manifest-path rust/Cargo.toml --locked --lib -p bopify-core`.** Expect all wrapper tests to pass. Then run `rustup run 1.99.0 bash ./scripts/build-rust.sh`; expect the header to export `bopify_request_lyrics` and XCFramework creation to succeed. Inspect the generated symbol/header; do not hand-edit artifacts or add ignored binaries to Git.
- [x] **Step 7: Commit the Rust source and tests.** Suggested subject: `Fetch and normalize Spotify lyrics through librespot`.

## Task 3: Connect Swift Waiters, Verify the Whole Bridge

**Files:** Modify `Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift`, `Sources/BopifyPlayback/LibrespotEngine.swift`, `Sources/BopifyPlayback/EventBridge.swift`, `Tests/PlaybackTests/EventBridgeTests.swift`; create `Tests/PlaybackTests/EventBridgeLyricsTests.swift`. Update these explicit conformers:

- `Bopify/Bopify/Views/PreviewPlaybackEngine.swift` — `PreviewPlaybackEngine`.
- `Packages/BopifyCore/Tests/PlaybackTests/StubPlaybackEngine.swift` — `StubPlaybackEngine`.
- `Packages/BopifyCore/Tests/PlaybackTests/RecoveryStubEngine.swift` — `RecoveryStubEngine`.
- `Packages/BopifyCore/Tests/PlaybackTests/PlayerModelTests.swift` — `FailingSelectionEngine`.
- `Packages/BopifyCore/Tests/PlaybackTests/PlayerVolumeTests.swift` — `ControlledVolumeEngine`.

Read existing callers, `EventBridgeRadioTests` and `RecoveryTestClock.swift`. Update `docs/spotify-lyrics-probe.md` with actual final results and mark the approved spec implemented only when acceptance passes.

**Interfaces:**

- Consume Task 1's domain types and Task 2's generated C function.
- Add the protocol method `func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics`; implement it in `LibrespotEngine` as `@concurrent public func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics`.
- Add internal `EventBridge.lyrics(for track: SpotifyURI, _ send: (UInt64) throws -> Void) async throws -> TrackLyrics`.
- Preserve `public EventBridge.init()` and add internal `init(lyricSleep: @escaping @Sendable (Duration) async throws -> Void)` for the existing cancellation-aware test clock. Production sleep is `Task.sleep(for:)`; the duration remains fixed at `.seconds(35)`.
- Maintain a separate private lyric waiter lock/counter. Each waiter owns the requested URI, checked continuation and watchdog task; radio IDs may overlap safely because routing is by reply type.

- [x] **Step 1: Write failing lyric lifecycle tests.** `synchronousReplyCompletesWithoutOrphanTimer` injects a callback inside `send` and asserts decoded content, then no pending clock delay after cancellation drains. `reverseOrderRepliesReachTheirCallers` dispatches two different tracks and replies in reverse order. `wrongTrackFailsUnavailable` returns a valid reply with another URI for the same ID and asserts `.unavailable`. `radioAndLyricsWithEqualIDsStaySeparate` dispatches both channels and asserts each gets its own result. Exercise success, typed failure, unknown reason, malformed body with recoverable ID, rejected send, duplicate and late replies.
- [x] **Step 2: Write failing watchdog/teardown tests using `RecoveryTestClock`.** Wait for `pendingDelays == [.seconds(35)]`, advance 35 seconds and assert `LyricFailure.network` for no reply and missing/invalid IDs. Caller cancellation must throw `CancellationError`. `finish`, `.sessionLost` and `.failed(.playbackSessionLost)` must fail waiters with `PlayerError.playbackSessionLost`. After each completion, wait for cancellation to drain, assert `pendingDelays.isEmpty`, advance again and deliver a late reply without another resume. A caller already cancelled when registration completes must not invoke `send`. Finish/drain the event stream and assert lyric replies never appear in it. Synchronize through streams/clock registration, not arbitrary sleeps.
- [x] **Step 3: Run `swift test --package-path Packages/BopifyCore --filter EventBridgeLyricsTests`.** Confirm the missing lyric bridge fails before implementation.
- [x] **Step 4: Implement the separate waiter lifecycle in `EventBridge.swift`.** Register the waiter and its weakly captured watchdog under the lyric lock before `send`, preventing a synchronous-completion/timer-attachment race. Centralize resolution: atomically remove, then cancel the timer and resume outside the lock. Route lyric envelopes before playback decoding; malformed recognized messages with usable IDs fail unavailable, and unrecoverable IDs expire through the watchdog. For malformed known lyric types, log no raw body. Keep existing radio semantics intact. Drain/cancel lyric waiters alongside radio on finish and both terminal-event paths.
- [x] **Step 5: Expose the engine API and update conformers.** The real method calls `bridge.lyrics(for:)`, `perform("requestLyrics")` and the generated FFI symbol, borrowing the URI only for that call. Preview/unrelated doubles explicitly throw `LyricFailure.unavailable`; preserve `RecoveryStubEngine.record("lyrics")` failure injection and record `"lyrics:\(track.rawValue)"` in `StubPlaybackEngine`. Add no default protocol implementation. Extend Swift FFI smoke tests to call the new symbol and assert null-URI `-1` and null-handle/valid-URI `-1`, preserving the existing handle guard.
- [x] **Step 6: Run focused tests.** `swift test --package-path Packages/BopifyCore --filter 'LyricReplyTests|EventBridgeLyricsTests|EventBridgeRadioTests|FFISmokeTests'` must pass, including clock cleanup and cross-channel tests. Resolve failures before broadening.
- [x] **Step 7: Run required repository checks on the final code.** All must complete successfully; record actual counts and any existing warnings rather than inventing a clean run:

```sh
rustup run 1.99.0 cargo fmt --manifest-path rust/Cargo.toml -- --check
rustup run 1.99.0 cargo clippy --manifest-path rust/Cargo.toml --locked --all-targets -- -D warnings
rustup run 1.99.0 bash ./scripts/test-native.sh
swift test --package-path Packages/BopifyCore
xcodebuild -project Bopify/Bopify.xcodeproj -scheme BopifyAppTests -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/lyric-ribbon-study CODE_SIGNING_ALLOWED=NO test
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/lyric-ribbon-study CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/lyric-ribbon-study CODE_SIGNING_ALLOWED=NO build
```

- [x] **Step 8: Verify the implemented Swift API live through Bopify's normal engine.** Use temporary Debug-only diagnostic instrumentation in `Bopify/Bopify/AppEnvironment.swift` at `connect()`'s existing `onEngineChange` hook, gated to run once after the current player reports ready. Bound the readiness wait to 45 seconds and report its outcome if no usable engine appears. Call `engine.requestLyrics(for:)` for the probe track, observe the same engine epoch, print only synchronization/line count/timestamp validity/attribution presence, and check playback identity/state before and after the request. Issue no play/pause/seek/transfer commands and create no second probe engine. Use normal app authentication/Keychain consent; do not revive the rejected alternate-runner route. If account access is unavailable, report the specific blocker instead of calling the bridge verified. Remove the diagnostic instrumentation before the final diff; rerun the affected app build after removal.
- [x] **Step 9: Record actual verification in `docs/spotify-lyrics-probe.md`.** Separate the implemented Swift API result from the successful standalone Rust probe. Note remaining live/manual gaps and that the ribbon still uses fixtures. `git diff --check` must pass; verify the final diff contains no diagnostic hook, credential value, new dependency, unrelated refactor or ribbon UI change.
- [x] **Step 10: Obtain one fresh whole-change review, fix substantive findings and rerun affected checks.** Native execution uses a single final reviewer; no per-task implementation agents. Commit the Swift bridge, conformer updates, tests and validation notes with subject `Expose bounded Spotify lyric requests to Swift`. Push the completed commits directly to `main`, verify a clean tree and remote synchronization, then report results and remaining limits.

## Self-Review

Spec coverage maps to Tasks 1–3: domain and wire schema (1/2), SDK reuse/normalization/limits/deadline/FFI (2), caller identity/correlation/watchdog/cancellation/teardown/conformers (3), and full-suite plus real Swift API verification (3). Each Review Focus item has an owning test above. No UI, provider-selection or auth subsystem is added. Native execution and direct-main integration preserve the user's existing instructions.

Implementation approved by the user and executed natively. A fresh whole-change review of `9001c30..dedf960` found no critical, important or minor issues. All required checks and live Swift API retrieval passed. Completed changes are committed and pushed directly to `main`.
