# Public-distribution integration evidence — 2026-10-13

Integration worktree: `/Users/leesiongchan/.codex/worktrees/7e93/bopify`.
Branch: `codex/public-distribution-integration`.
Base: `public-distribution` at `16b4cae9b43310882e0a2ec53b206cdea0f3c330`.
Merged input: `codex/release-pipeline` at `605efa7d556478b349b4a89666a7c681c8523f9e`.
The source branches and main checkout were not edited.

## Preserved behavior

- Public Library Access, validated user-owned client IDs, consent recovery and
  visible-library accounting; no production Dashboard client ID remains.
- Hardened OAuth callbacks, typed credential restoration errors, rotated-grant
  persistence retries and audio-output fault/checkpoint recovery.
- One release pipeline with pinned tools, locked Cargo inputs, exported-capability
  checks, selected-certificate consistency, embedded notices, strict Apple-log
  checks, retained evidence, safe final promotion and CI credential cleanup.
- Public branch's Rust bootstrap and one-hour notarization wait.

Seven merge conflicts were confined to tooling/configuration and resolved as one
coherent release implementation. Cargo then reproduced a duplicate license value
from an automatic merge; the inherited MIT declaration fixes the manifest.

A composition regression reproduced a lost rotated refresh grant when Library
Access saved an unchanged ID. Save now cancels only active consent, preserving
an otherwise pending credential-save retry. The isolated app fixture failed with
`authExpired` before the change and passes afterward with exactly one refresh.

## Verification

| Check | Result |
| --- | --- |
| Public baseline Swift suites | 327 passed |
| Integrated Swift suites | 351 passed: 177 playback, 60 library, 28 domain, 86 authentication |
| Native tests after dependency update | 171 passed: 57 wrapper, 85 Connect, 19 core, 7 playback, 2 doctests, 1 explicit faulted-sink contract |
| Release-script/tooling/credential tests | 21 passed |
| Locked native build | Passed without warnings/errors |
| Clippy with `-D warnings` | Passed |
| ShellCheck and actionlint | Passed |
| Debug app build and development-signed archive | Passed |
| Library composition fixture | Passed: consent guards, scope widening, no playback, teardown, dual-store sign-out and stale consent |
| Same-ID Save fixture | Passed: rotated grant survives Save and retry needs no second refresh/browser |
| Archive policy checks | arm64, strict/deep signature, hardened runtime, required sandbox/network/file rights, Music category, matching0644notices |
| Dependency security audit after update | XML/time advisories and yanked package removed; raw scan still exits 1 for RSA only, with a scoped usage assessment and no ignores |
| Developer ID preflight | Blocked: no usable team6RS6K2N242 Developer ID Application identity |

New library/auth boundary tests preserve the client ID/grant under four storage
read faults, recover after the fault clears, replace suspended fixed-port consent,
reject its stale callback and serve only the replacement grant. They use local
loopback and synthetic stores/HTTP responses; no Spotify account is accessed.

Debug/archive builds still emit Xcode's supported-platform diagnostic while
returning success. AppKit's investigated recursive layout warning remains
unresolved. Neither was suppressed.

## Pending acceptance

Actual Developer ID export, Apple notarization/stapling/Gatekeeper, second-Mac
installation and hosted CI execution remain pending. Installed-account Keychain,
real playback, output switching and sleep/wake remain user-deferred.
No source branch/main merge, push, tag, GitHub Release or signing-secret change
was performed. The integrated branch is the reviewable result.

## Independent review and verified fixes

A fresh integration review found two Important credential-boundary issues, both
reproduced by failing tests and fixed:

- Client changes previously published a new ID despite failed Keychain deletion.
  The strict `signOutAndClearCredentials` path now propagates failure, preserves
  the original library ID and blocks publication of the replacement service.
  Library Access stays open with a visible error and supports retry. Ordinary
  nonthrowing sign-out remains compatible.
- Corrupt library credentials previously offered repeated Retry and blocked even
  explicit consent. Library requests now expose Enable; explicit user consent
  can replace an undecodable grant. Background reads and temporary inaccessible
  credentials remain nondestructive. A reopened actor reads the persisted repair;
  declining consent preserves the corrupt entry and client ID.

The complete351Swift suite passes after both fixes. No Critical or Minor findings.
Standalone audio/auth/release work had prior review; this review focused on
integration. Real DeveloperID/remote/live acceptance remains outside these tests.

Visual verification of Library Access compares the
[normal setup](public-integration-2026-10-13/library-setup-before-content.png) with
[failed credential deletion](public-integration-2026-10-13/library-setup-clear-error-content.png).
The error appears below the client ID field; the window remains open and the
Save action is available for retry. Direct native content captures complement
window-server screenshots, whose compositor transform makes text too small.

Commands and full output remain in the ignored workspace
`.superpowers/sdd/2026-10-13-public-distribution-integration/`. Archive control:
`/private/tmp/bopify-public-integration-development-control.xcarchive`.
Setup: [releasing](../../releasing.md).

## Dependency security audit baseline — 2026-10-13

Ran cargo-audit 0.22.2 against the committed `rust/Cargo.lock`, without changing
it, using the current RustSec database and `--deny warnings`. Exit status: 1.
The scan covers all lockfile packages, with no platform filters or ignored
advisories. The production dependency graph was separately inspected with
`cargo tree --locked --offline --target aarch64-apple-darwin` and platform-filtered
Cargo metadata. SwiftPM has no external package dependencies in this checkout.

- Lockfile SHA-256: `2241d2bcedddb155496185cd5e6a4a3a3881bcb9a00e04052e237c3e64d30152`.
- RustSec database commit: `29d1a60c3361576d366b1740bba2254dc6173434`.
- Database advisory count: 1310; lockfile dependency count: 359.
- Full JSON report and official registry metadata are retained in the ignored
  evidence directory `dependency-audit/` alongside the other full logs.

| Finding | Inspected production use | Recommended treatment |
| --- | --- | --- |
| quick-xml 0.38.4: RUSTSEC-2026-0194 and RUSTSEC-2026-0195 | Only librespot-core consumes it; ProductInfo uses plain Reader/read_event_into, without attribute iteration or namespace resolution | Replace with current stable 0.42.0 through the reproducible librespot patch, migrate its text API and update the lockfile |
| time 0.3.45: RUSTSEC-2026-0009 | Librespot date parsing uses Iso8601; build metadata uses Rfc3339. No affected Rfc2822 parser use was found in those consumers | Update to current stable 0.3.55; it requires Rust 1.88 |
| rsa 0.9.10: RUSTSEC-2023-0071 | Sole consumer is librespot-core's handshake: fixed public key, PKCS#1 v1.5 signature verification; no RSA private key, signing or decryption | No patched version exists. Retain finding and review a narrowly scoped non-reachability assessment for this revision/version/callsite |
| yoke-derive 0.8.3: yanked version | Compile-time macro through yoke/ICU/idna/url | Update the lockfile to non-yanked 0.8.4; the yoke requirement permits it |

This is a source/dependency assessment, not a dynamic exploit test or a clean
audit claim. The advisory-specific paths were not found in this build, but the
raw findings remain visible. Reassess if dependency versions, features, consumers
or the librespot revision change. No audit ignore configuration was added.

The XML input arrives over Spotify's signature-verified AP transport, with a
verified packet MAC and a u16 payload length. These boundaries add context; they
are not a substitute for fixing vulnerable dependency versions.

The proposed update keeps the existing librespot revision and folds manifest
and XML API changes into its checked patch. Editing only `.build/` would violate
the preparation script's exact-patch check. The selected current stable versions
require raising Bopify's declared Rust minimum from 1.85 to 1.88. The installed
Rust 1.98 toolchain meets that requirement; minimum-version compatibility has not
been tested. Source dependencies and toolchain requirements were unchanged at that
baseline. The user subsequently approved the updates and requested latest stable
Rust; the completed update is recorded below.

Verification after an update must include a fresh audit (preserving any RSA
assessment), locked native build/tests, Clippy, regenerated license notices and
the Swift/build controls that consume the rebuilt static library. Tests should
exercise Bopify's integration boundary rather than the third-party parser alone.

[quick-xml attribute advisory](https://rustsec.org/advisories/RUSTSEC-2026-0194.html).
[quick-xml namespace advisory](https://rustsec.org/advisories/RUSTSEC-2026-0195.html).
[time advisory](https://rustsec.org/advisories/RUSTSEC-2026-0009.html).
[RSA advisory](https://rustsec.org/advisories/RUSTSEC-2023-0071.html).
Official registry metadata checked 2026-10-13:
[quick-xml](https://crates.io/api/v1/crates/quick-xml),
[time](https://crates.io/api/v1/crates/time),
[yoke-derive](https://crates.io/api/v1/crates/yoke-derive).

## Approved dependency and toolchain update — 2026-10-13

The user approved the three dependency updates and requested the latest stable
Rust release. Official Rust distribution metadata and the release announcement
identify Rust 1.99.0, released 2026-10-01. Official crates.io metadata identifies
quick-xml 0.42.0, time 0.3.55 and yoke-derive 0.8.4 as their latest stable,
non-yanked releases on this verification date.

- Bopify and the maintained librespot workspace now declare Rust 1.99 minimum.
  `rust-toolchain.toml` pins 1.99.0 with Clippy, rustfmt and the arm64 target.
  CI bootstraps rustup without floating stable, then selects the checked-in pin.
  The host environment forced 1.98.0, so verification unset `RUSTUP_TOOLCHAIN`
  for these commands; no global default or user configuration was changed.
- The release lockfile contains the three selected versions and required time
  dependency updates only. The dependency workspace's test lockfile is updated
  in the same checked patch; its required macro dependencies also changed.
- Librespot remains at `939dc5ee9d833e1980f9495241219d9d4868a061`.
  Its existing patch sections are unchanged. Manifest/test-lock updates and the
  XML API migration are reproduced through that patch, including on a fresh
  pinned checkout. Repeated preparation remains idempotent.
- ProductInfo retains full raw start-tag keys and XML 1.1 text normalization.
  An offline dispatch-to-session test verifies premium metadata, Unicode and
  CRLF/NEL/U+2028 normalization, raw keys and replacement of stale attributes.
  Before migrating the callsite, compilation reproduced four XML API errors;
  the corrected callsite and all core tests pass.
- Rust 1.99 Clippy reported one collapsible nested condition in recovery
  validation. A let-chain preserves its existing behavior; strict Clippy and
  the full wrapper suite pass after the change. No lint suppression was added.
- Regenerated notices contain all three selected versions and ship as matching
  0644 files in the fresh development-signed archive.

| Final check | Result |
| --- | --- |
| Rust compiler selected from pin | 1.99.0, verified with environment override removed |
| Locked native build | Passed without warnings/errors |
| Native suites and explicit sink contract | 171 passed, with the device-dependent ignored test explicitly run |
| Swift suites against final rebuilt library | 351 passed |
| Release-script/tooling/credential suites | 21 passed |
| Strict Clippy, ShellCheck and actionlint | Passed |
| Clean pinned-source preparation | Patch application, repeated preparation and actual source whitespace checks passed |
| Regenerated notices | New versions included; 0644; archived copies match |
| Development-signed Release archive | Passed: arm64, strict/deep signature, hardened runtime and required sandbox/network/file rights |
| Independent final review | No material findings; original patch sections unchanged and XML behavior preserved |
| Current RustSec scan, no ignores | Three advisories and one yanked package removed; only RSA remains; exit 1, no informational/yanked warnings |

Updated release lockfile SHA-256:
`25c4f40241f3aaece1d20c7c6e2c433e9e902c4faa4b47b443872814e043373d`.
Current database commit: `29d1a60c3361576d366b1740bba2254dc6173434`.

RSA 0.9.10 remains solely a public-key signature verifier in the pinned handshake.
The advisory concerns RSA private-key timing; no RSA private key, signing or
private-key decryption use was found in the inspected consumer. There is no
patched version. This is a source-based assessment for this exact consumer,
revision and usage, not a fix to the RSA crate or a zero-finding audit claim.
Reassess when that boundary changes; the raw finding remains visible.

Final output and metadata are retained under the ignored `dependency-update/`
evidence directory. Development archive:
`/private/tmp/bopify-dependency-update-development-control.xcarchive`.
This is a packaging control, not Developer ID export or notarized distribution.
Xcode still emits its supported-platform diagnostic while returning success.
The AppKit warning, actual Developer ID/notarization/Gatekeeper, clean-Mac and
hosted-CI acceptance, and user-deferred live checks remain pending. No app was
launched and no account credentials were accessed by these checks.

[Official Rust 1.99.0 release](https://blog.rust-lang.org/2026/10/01/Rust-1.99.0/).
[Rustup toolchain-file selection](https://rust-lang.github.io/rustup/overrides.html#the-toolchain-file).
[quick-xml 0.42.0 source](https://github.com/tafia/quick-xml/tree/v0.42.0).
[Current RSA advisory](https://rustsec.org/advisories/RUSTSEC-2023-0071.html).
