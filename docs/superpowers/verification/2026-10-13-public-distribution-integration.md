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
| Integrated Swift suites | 347 passed: 177 playback, 59 library, 28 domain, 83 authentication |
| Native tests | 151 passed: 57 wrapper, 85 Connect, 7 playback, 1 doctest, 1 explicit faulted-sink contract |
| Release-script/tooling/credential tests | 21 passed |
| Locked native build | Passed without warnings/errors |
| Clippy with `-D warnings` | Passed |
| ShellCheck and actionlint | Passed |
| Debug app build and development-signed archive | Passed |
| Library composition fixture | Passed: consent guards, scope widening, no playback, teardown, dual-store sign-out and stale consent |
| Same-ID Save fixture | Passed: rotated grant survives Save and retry needs no second refresh/browser |
| Archive policy checks | arm64, strict/deep signature, hardened runtime, required sandbox/network/file rights, Music category, matching0644notices |
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

The public branch's existing client-change path logs Keychain deletion failure
through nonthrowing `signOut`; this edge is recorded for final review. It must
not be mistaken for a verified credential-removal guarantee.

Commands and full output remain in the ignored workspace
`.superpowers/sdd/2026-10-13-public-distribution-integration/`. Archive control:
`/private/tmp/bopify-public-integration-development-control.xcarchive`.
Setup: [releasing](../../releasing.md).
