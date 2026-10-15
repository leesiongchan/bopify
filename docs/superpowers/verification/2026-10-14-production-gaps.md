# Production gap verification — 2026-10-14

The three approved gaps are implemented on `codex/public-distribution-integration`
in `/Users/leesiongchan/.codex/worktrees/7e93/bopify`. Code commit: `3c67e66`.
Main and the source branches remain unchanged.

## Logout cleanup

Explicit sign-out now records non-secret, versioned cleanup intent for the
playback and library credential namespaces before deleting credentials. Both
stores are attempted independently, including a library grant without a client
ID. Pending or unreadable intent blocks old-grant restoration. Partial completion
survives service recreation; startup retries cleanup before loading credentials.
Playback/player/library teardown continues on failure. The UI offers **Retry
removal**, never credential restoration, and blocks new consent while removal
runs. Quit and client-ID replacement retain their previous contracts.

A failed intent commit defers deletion and invalidates in-memory authorization.
The dedicated error explains that saved sign-in may return after restarting
until the request can be recorded. Checked atomic replacement supports process
restart recovery; it does not establish sudden-power-loss durability. The shared
lock coordinates one process, not simultaneous application processes or old
binaries that ignore the new metadata. Existing Keychain identities and token
encoding are unchanged. Apple documents asynchronous UserDefaults persistence,
so it is not the acknowledged intent store. [Apple UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults).

## Native and app release gates

`test-native.sh` runs wrapper, Connect and playback unit tests/doctests against
the shipping lock. Core tests require the upstream workspace and its separate
lock. `--lib` excludes the upstream account/network integration test; the real
audio-device test remains explicitly ignored. CI permits dependency downloads
with `--locked`; local offline verification used populated caches. [Cargo test](https://doc.rust-lang.org/cargo/commands/cargo-test.html).

`test-app-boundaries.py` compiles the Debug app without signing or launching it,
then runs maintained logout and artwork fixtures against production sources.
Both scripts run before release packaging. Injected failures at all four native
commands stop later commands, and a real deliberately failing Rust test in a
throwaway crate exits 101 without producing the packaging marker. Publishing
still depends on successful build completion. [GitHub workflow semantics](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax).

## Artwork recovery and limits

Nuke 13.2.0 is pinned by exact version and commit
`30f7a7e72e0607d304fbf69c799474bd5fb6d1ce`; only its core product is linked.
Its MIT notice is embedded and shipped beside the app. The tagged manifest
requires Swift tools 6.0/macOS 12 and declares no resource bundles or external
package dependencies. [Nuke release](https://github.com/kean/Nuke/releases/tag/13.2.0),
[tagged manifest](https://github.com/kean/Nuke/blob/13.2.0/Package.swift).

The adapter limits responses to 8 MiB, active downloads to four, thumbnails to
640 pixels and decoded image cost to 32 MiB/112 entries. Negative records are
limited to 112. Pipeline image/disk/resumable caches are disabled so the
observable cache owns retention and clear. One retry job per URL shares three
attempts across staggered consumers; individual cancellation returns promptly,
and final-consumer cancellation stops the job and Nuke request. Clear replaces
the invalidated pipeline and rejects stale image/palette work.

Transient failures use a 30-second cooldown; permanent/decode/palette failures
use ten minutes. Connectivity recovery can reopen transport failures; wake/show
can reopen expired records. HTTP Retry-After seconds and HTTP dates prevent early
requests, with server delays bounded to one day. Retry revision and image-ready
keys re-run unchanged-URL callers; recovered palette publication updates pressing
appearance. [HTTP Retry-After](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.3).

## Verified evidence

| Check | Result |
| --- | --- |
| Swift suites | 360 passed: 177 playback, 60 library, 28 domain, 95 authentication |
| Native gate on Rust 1.99.0 | 168 unit tests and 2 doctests passed; 1 hardware test ignored |
| Python tooling tests | 27 passed; final native gate assertions separately passed |
| App boundary gate | Debug build plus all three fixture executables passed |
| Headless logout fixture | All four deletion outcomes, startup pending/corrupt state, failed intent commit/repair and quit passed; eight scenarios |
| Artwork fixtures | Recovery, shared budgets, known/unknown response sizes, cancellation, replacement/eviction and actual 30-second expiry passed |
| Additional cancellation stress | 25 cancellation/clear/replacement races and 100 pre-cancelled consumers passed |
| Decoded retention measurement | 20 fixture images, 32,768,000 bitmap bytes; every image at most 640 pixels |
| Offscreen cleanup UI | Actual localized production views at 360pt; Retry removal and wrapped restart caveat fit without clipping |
| Workflow and shell lint | actionlint and ShellCheck passed |
| Whole-change review | No P1/P2 findings after correction of intent write ordering and retry regressions |
| Fresh RustSec scan | RSA 0.9.10 / RUSTSEC-2023-0071 only; no warnings/yanked packages; raw scan exits 1, no ignores |

The RustSec result retains the previous public-key-only reachability assessment.
Nuke's maintainer advisory page had no published advisories on the check date;
this is the scope of that check. [Nuke maintainer advisories](https://github.com/kean/Nuke/security/advisories).

Headless fixtures replace window/media/connection boundaries and use synthetic
stores/HTTP. Offscreen UI rendering uses the existing increased-contrast style;
native spinner and glass compositing are not validated by ImageRenderer.
Ten-minute expiry was source-reviewed, not waited through. Live SwiftUI task
execution, real Keychain/account/audio/output switching/sleep-wake and clean-Mac
installation remain user-deferred. Hosted Actions scheduling is not yet run.

## Verified free DMG

Artifact: `build/release/Bopify-0.1.0-rc.2.dmg`, built from code commit `3c67e66`.
App version `0.1.0`, build `250`. SHA-256:

```text
f570a2972ae48e3db4787c028b0d3d587949ddd03102447f1458fea097c2266b
```

The actual release command completed. Read-only mounting confirmed arm64,
strict/deep ad-hoc signature, hardened runtime, exactly the four required
capabilities, no signing team, matching readable 0644 embedded/adjacent notices,
Nuke metadata in the executable, no external Nuke runtime library and the
Applications symlink. The image was ejected. This free artifact is not notarized;
GitHub installation follows the documented Gatekeeper override route.

The native build still emits the eleven previously assessed cbindgen parser
warnings; they were not suppressed. Debug builds emit Xcode's skipped AppIntents
metadata extraction diagnostic. The separately investigated AppKit layout
warning remains unresolved. None is claimed fixed by these three changes.
No merge, push, tag, GitHub Release or live account test was performed.

Reproduce the automated gates from the repository root:

```sh
unset RUSTUP_TOOLCHAIN
CARGO_NET_OFFLINE=true ./scripts/test-native.sh
swift test --package-path Packages/BopifyCore
python3 -m unittest discover -s scripts/tests -v
python3 scripts/test-app-boundaries.py
```

Local full logs and offscreen images are under
`/private/tmp/bopify-three-gaps-implementation/` and
`/private/tmp/bopify-gaps-*`; maintained fixtures and scripts are in this commit.

The later user-assisted playback, output-switching and short sleep/wake checks
are recorded in [live release acceptance](2026-10-14-live-release-acceptance.md).
That report supersedes the live-test deferral above for those specific checks
and records diagnostics and release gates that remain open.

The subsequent [live diagnostic investigation](2026-10-14-live-diagnostic-fixes.md)
records the native session-invalidation fix and an independent rendering
reproduction; no reliable popover workaround is claimed.
