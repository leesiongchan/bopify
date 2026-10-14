# Live diagnostic investigation and native fix — 2026-10-14

Worktree: `codex/public-distribution-integration`. The live rc2 results are in
[live release acceptance](2026-10-14-live-release-acceptance.md). The changes
below were verified without changing that running release app or its credentials.

## Session invalidation: reproduced and fixed

The exact pinned native implementation marks a Session invalid and shuts down
Mercury/channel managers, while Dealer subscriptions can remain pending. Its
idle Connect loop checks `is_invalid()` only before entering its select. An
already waiting loop therefore does not notice shutdown until unrelated input
arrives. The maintained `session_shutdown_ends_waiting_loop_without_other_input`
regression failed on the shipping workspace before the fix and passed afterward.

The patch adds a sticky Tokio watch signal to Session, published after releasing
the existing state lock. `Session::invalidated()` observes earlier shutdown,
registered/canceled subscribers and independent waiters. Connect selects that
signal. The existing Tokio dependency provides this; no new library, polling
loop, C ABI or wire reason was added. `send_replace` retains the latest state
without receivers and `wait_for` checks the initial value and is cancellation
safe. [Tokio Sender documentation](https://docs.rs/tokio/latest/tokio/sync/watch/struct.Sender.html),
[Tokio Receiver documentation](https://docs.rs/tokio/latest/tokio/sync/watch/struct.Receiver.html), checked 2026-10-14.

Review identified a second path: a previously selected HTTP handler or native
cleanup can remain pending after invalidation. The engine supervisor now observes
the Session directly as well as task completion. It reports terminal loss through
the existing once-only/teardown gate even if the Connect future is stalled. The
new engine regression failed with a virtual one-second timeout before this change
and passed afterward. Prior/pending invalidation, a single terminal event and no
recovery after intentional teardown are covered. Cleanup remains owned by the
runtime until Swift requests the existing joined engine teardown; this fix does
not make HTTP cleanup itself time-bounded.

Transport diagnostics now allowlist AP send/read I/O kind, EOF and keepalive
state; Connect diagnostics identify closed streams, connection-ID error kind,
local Spirc sequence and invalid/shutdown exit flags. URLs, usernames, device IDs,
tokens, packet contents and arbitrary error messages are excluded. Third-party
log messages retain their existing privacy redaction.

This fixes a demonstrated detection/reporting defect. It does not retrospectively
identify what initiated the live AP failure. In the live run, a redacted upstream
error occurred while paused at 21:36:36 +0800; Resume at 21:38:20 was followed by
successful HTTP publication and then a Warn/disconnect at 21:38:21. There were no
cluster-update ownership logs. Delayed recognition of an invalid session is
consistent with this sequence, but the initial private error cannot prove it.
The recorded live recovery took 3.340578 seconds.

## Popover transaction error: independent reproduction, no retained workaround

Environment confirmed freshly: macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), arm64.
The full live stack runs through AppKit window-property precommit actions,
transaction deallocation and Core Animation commit cleanup into the normal
application run loop. It contains no Bopify layout callback in that causal portion.
The diagnostic cluster follows a popover closing; the log does not identify
whether VolumeControl or FavoriteButton supplied it. The separate historical
`layoutSubtreeIfNeeded` warning was absent in this capture and remains unresolved.

Eighteen fresh plain-AppKit controls (six each animated, nonanimated and no
popover) were clean with validated lifecycle/log collection. These controls
retain their popover until process exit, so they do not exclude a release-lifetime
path in SwiftUI. A weakly observed standard SwiftUI `.popover` independently
reproduced the six-record live cluster in both a titled NSWindow and a
nonactivating NSPanel, without Bopify, playback, artwork, glass or credentials.
An initially invalid fixture required SwiftUI `onDisappear`; it was corrected to
validate public NSPopover show/close notifications. Invalid runs were not counted
as clean evidence.

Two supported SwiftUI transaction candidates were tested and rejected:

- Value-scoped `disablesAnimations` had a valid panel run with the same error
  during repeated paired tests.
- A fixed transaction produced six clean explicit-binding-close runs, with
  actual `NSPopover.animates == false`. Direct public AppKit `performClose(nil)`
  still reproduced the complete cluster in both the titled-window and panel
  controls. These two valid failures reject it as a general fix.

Both temporary production UI changes were removed. No animation workaround,
introspection library, private API, global timing delay or diagnostic suppression
is retained. Apple's transaction API describes view animation control; it does
not promise to repair AppKit commit ordering.
[Apple Transaction documentation](https://developer.apple.com/documentation/swiftui/transaction).
Apple documents that `performClose` honors `animates`; observing false at show
alone cannot establish its value throughout teardown.
[Apple NSPopover performClose documentation](https://developer.apple.com/documentation/appkit/nspopover/performclose(_:)).
A developer forum report independently describes this cluster on macOS 27; it
contains no Apple-confirmed solution.
[Apple Developer Forums report](https://developer.apple.com/forums/thread/847128).

Maintained account-free fixtures: `AppKitPopoverTransactionRepro.swift` and
`SwiftUIPopoverTransactionRepro.swift`. Compile with Swift 6, MainActor default,
warnings as errors and macOS 14 deployment. Run one fixture process at a time.
Exit 0 means a valid clean observation, 1 captured diagnostics, 2 invalid evidence.
The SwiftUI control exposes `host-binding`, `panel-binding`, `host-systemclose`
and `panel-systemclose` as well as parent-order-out controls. Direct public
`performClose` is a sufficient test trigger, not proof it exactly matches the
system close-all action in the live app. These are diagnostic reproductions,
not CI tests declaring Apple's framework warning an application regression.

## Fresh verification

| Check | Result |
| --- | --- |
| Native release gate | 173 unit tests + 2 doctests passed; 1 existing hardware test ignored |
| Native suite breakdown | 59 wrapper, 86 Connect, 7 playback, 21 core; core uses its separate upstream lock |
| Swift package suites against rebuilt native artifact | 360 passed: 177 playback, 60 library, 28 domain, 95 authentication |
| Python tooling | 27 passed |
| App boundary gate | Debug build and all logout/artwork fixture executables passed |
| Strict wrapper Clippy | Passed with `--lib -- -D warnings` |
| Independent native reviews | No P1/P2 findings in final signal and supervisor implementation |
| Source whitespace/patch parity | Root engine and prepared upstream diffs passed; prepare-librespot verified exact patch |

The whole-repository `git diff --check` flags two newly introduced blank context
lines in the tracked unified-diff artifact. They are single-space context prefixes
required by its canonical generated representation, not source trailing whitespace.
The exact generated patch and reverse application were verified; no whitespace
check was suppressed. Native compilation still emits the eleven previously
assessed cbindgen warnings, and Debug app builds retain skipped AppIntents metadata
extraction. These are not claimed fixed.

Local logs and rejected candidates are in `/private/tmp/bopify-live-triage/`.
No raw account logs are committed. The earlier live checks cover rc2, not a live
run of this new native fix. The existing rc2 DMG is unchanged. Fresh packaging
and live verification of the changed artifact, real sign-out/re-consent,
clean-Mac quarantine installation and hosted Actions remain separate gates.

## Apple Feedback draft — not submitted

Title: Standard SwiftUI popover teardown opens an AppKit transaction during
Core Animation commit on macOS 27.0.1.

Expected: A normal `.popover` closes without invalid commit-order diagnostics.
Actual: Both stock titled-window and nonactivating-panel hosts can emit three
entangle warnings, a fence warning, a dropped-handler error and
`NSCGSTransactionCreatedDuringCommitError`. Attach the maintained SwiftUI fixture
and self-scoped logs from a validated failing run; the fixture needs no account,
Bopify libraries or audio. A fixed transaction disabling animation did not avoid
the direct-close reproduction. The complete live stack is in local redacted
runtime evidence. Apple acknowledgement and a supported workaround remain absent.
Recommended next step: compare this reproduction on another supported OS/SDK,
then assess a verified framework fix or a separately designed presentation change.
