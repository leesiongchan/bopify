# Connection resilience

Status: approved by the user on 2026-11-03, design and written spec. First of four reliability specs from the Spotifast comparison. Order: connection resilience, refused audio keys, library authorization, audio output lifecycle.

## Intent and scope

A transient failure must never leave playback in a state only a relaunch can clear. Reconnect attempts must be paced, and every connect attempt must be bounded in time.

Three verified defects drive this:

- **Unclassified errors are terminal.** The fork's `From<io::Error>` maps `HostUnreachable`, `NetworkUnreachable`, `NetworkDown` and uncategorised errors (likely including DNS failures) to `ErrorKind::Unknown`. Handshake EOF and login5 `TRY_AGAIN_LATER` map to `FailedPrecondition`. `classify_connect_error` (`engine.rs`) turns every kind except Unauthenticated, Unavailable, DeadlineExceeded, ResourceExhausted and Aborted into `BopifyError::Unknown`. Swift then sets `.failed(.unknown)` (`PlaybackRecoveryCoordinator.swift`), and that state refuses retry, wake and network changes. The only escape is a relaunch or sign-out.
- **AP socket setup is unbounded.** The fork awaits `socket::connect` before its 5 s handshake timer starts (`core/src/connection/mod.rs`). Addresses are tried sequentially, and the macOS TCP connect timeout is 75 s, so one blackholed AP consumes the whole 30 s `LOGIN_DEADLINE`. Each retry builds a new session, which tries the same first AP again. The dealer uses the same `socket::connect`.
- **Backoff never damps periodic drops.** Delays cap at 30 s. After 60 s ready, the failure count and the immediate-retry allowance both reset, so a session that drops every 61 s or more reconnects instantly forever.

Out of scope:
- keeping the Player alive across reconnects (Spotifast's librespot#1765 approach);
- splitting the fork's squashed patch;
- reusable librespot credentials;
- changing the 30 s login deadline or the 20 s readiness deadline.

## Approaches

The retry policy belongs in bopify-core, the only layer that sees librespot's `ErrorKind` and the underlying io kind. Flipping the guard in Swift instead would be wrong: Swift's `.unknown` also covers malformed token responses, FFI misuse and unmapped errors, which must stay terminal.

For the timeouts, the open upstream PRs librespot-org/librespot#1800 and #1803 already fix socket setup. They apply cleanly to both the pinned fork and a rebased one, and adopting them keeps Bopify aligned with other librespot users. A Bopify-only rewrite would duplicate them.

## Fork (`leesiongchan/librespot`, branch `bopify`)

1. **Rebase onto upstream `dev`.** This brings in librespot#1807 (bounded handshake packet size, which closes a pre-auth allocation issue) and #1802.
   - `git merge-tree` shows three conflicts, resolved as follows:
     - regenerate `Cargo.lock`;
     - take upstream's `core/src/authentication.rs`;
     - merge the two rewrites of `connect/src/shuffle_vec.rs`'s `test_shuffle_with_first`.
   - Before force-updating `bopify`, push a tag at the old head (`bopify-7857e74`), so released builds pinned to `7857e749…` still resolve.
   - Force-pushing is outward-facing; confirm with the user at execution time.
2. **Add #1800**, which moves socket setup inside the 5 s timer, as its own commit with an `Upstream: librespot-org/librespot#1800` trailer and its tests.
3. **Add #1803** the same way. It connects through hyper-util `HttpConnector` with name resolution off the runtime and IPv4 tried 300 ms after IPv6, with DNS, TCP and proxy CONNECT sharing one 5 s budget. It adds a `tower-service` dependency edge that is already present in Bopify's lockfile, and the tokio `test-util` dev feature.
4. **Extend `Error::authentication_failure()`** with an account-restricted case for the AP login failures that mean this account cannot sign in here: `TravelRestriction`, `ApplicationBanned`, `InvalidAppKey` and `ExtraVerificationRequired`. Add tests in `core/src/error.rs`. This commit is written to be upstreamable.

Bump the pin in `rust/Cargo.toml` to the new head. The fork commit must be published before CI can fetch it.

## bopify-core

- **Invert `classify_connect_error`.** Terminal outcomes are only:
  - Premium required → −4;
  - invalid credentials or `Unauthenticated` → −3;
  - account restricted → new code −6 (`AccountRestricted`).

  Every other librespot error becomes −5, which recovery already retries. Engine-local failures (runtime build, mixer open) remain −99.
- **Log the source.** The connect-failure log records the librespot `ErrorKind` and, when present, the io `ErrorKind`, never payloads. Today the line records only the mapped code.
- **Share the FFI error codes** through a new `contracts/ffi-error-codes.json`, consumed by tests on both sides, as `contracts/session-loss-reasons.json` is. This replaces the hand-mirrored `PlayerError(ffiCode:)` table. Spec 3 adds −7 to the same contract.

## Swift recovery

- **Windowed backoff.** Replace the 60 s stable reset with a count of drops inside a rolling 10-minute window. The n-th drop in the window waits immediate, 2 s, 5 s, 15 s, 30 s, 60 s, 120 s, then 300 s (cap), each with 50–100 % jitter. Consecutive failed connects climb the same schedule. Network restoration and wake still retry immediately.
- **Never give up on transient errors.** −3 keeps its current path: one forced token refresh, then `.needsReauthentication`. `.failed` is reserved for −4, −6, engine-local −99, and spec 3's −7.
- **Manual escape.** `retryNow()` accepts every `.failed` state and every backoff wait. Wake and network changes still do not leave `.failed`, so a restricted account cannot loop.
- **UI.** `PlaybackConnectionStatusView` shows the existing "Retry now" (`connection.retry`) while a wait of 30 s or longer is scheduled, and on every `.failed`.
- **Account-restricted copy.** Add `PlayerError.accountRestricted`, localized as "Spotify won't let this account play here."

## Verification

Tests are written first and must fail before the change:

- **Rust (`engine.rs` tests):** a table classifying `Error::from(io::Error)` for `HostUnreachable`, `NetworkUnreachable`, `NetworkDown`, `io::Error::other`, `UnexpectedEof` and `InvalidData`, plus `failed_precondition`, `permission_denied`, `unknown` and `unauthenticated`. Each maps to −5 except the terminal kinds.
- **Fork:** the tests carried by #1800 and #1803, and account-restricted `authentication_failure()` tests.
- **Contract:** the FFI code contract tested in Rust (`error.rs`) and Swift (`LibrespotEngineTests`).
- **Coordinator (`PlaybackRecoveryCoordinatorTests`):**
  - rewrite `permanentErrorsDoNotLoop`, which asserts the bug for `.unknown`;
  - add the windowed ladder and its 300 s cap;
  - drops every 61 s still escalate;
  - `retryNow` leaves `.failed`, and wake and network changes do not;
  - Retry during a long wait.
- **App tests** for the status view's Retry action. `SignInRecordTests.automaticRecoveryOffersNoManualRetry` changes deliberately.

Run `scripts/test-native.sh`, the Swift package tests, the app tests, clippy, and a Release build with signing disabled. Manual check: block the first AP's address (for example with a `pf` rule), then confirm login reaches the next AP within the deadline and recovery keeps retrying through a DNS outage.

## Research

- [librespot#1800](https://github.com/librespot-org/librespot/pull/1800) and [#1803](https://github.com/librespot-org/librespot/pull/1803): both open; a maintainer (kingosticks) noted the OS-level connect timeout on #1800.
- [librespot#1807](https://github.com/librespot-org/librespot/pull/1807): handshake packet bound, on upstream `dev`.
- Spotifast v0.16.0 ([crmne/spotifast@3767d53](https://github.com/crmne/spotifast/tree/3767d53)): carries #1800 and #1803 and caps session drops at 6 per 10 minutes. Bopify keeps retrying instead, per the user's choice.
