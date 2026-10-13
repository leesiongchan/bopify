# Release pipeline evidence — 2026-10-13

Prepared in `/Users/leesiongchan/.codex/worktrees/4a21/bopify` on
`codex/release-pipeline`, through implementation commit `6ac714b`.
The main checkout and the active public-distribution checkout were not edited.

This is **automated preparation and packaging evidence**. It is not a completed
public release or a claim that the app has passed all production acceptance.

## Verified results

| Check | Result |
| --- | --- |
| Locked Rust static library, headers and XCFramework | Actual build passes; no compiler warnings/errors |
| Swift package suites | 332 tests pass: 177 playback, 56 library, 28 domain, 71 authentication |
| Release/tooling/credential tests | 21 tests pass, including deliberate failure boundaries |
| ShellCheck / actionlint 1.7.12 | Pass |
| Debug application build | Pass |
| Development-signed Release archive control | Pass; arm64, strict/deep signature, hardened runtime, four required sandbox/network/file capabilities |
| Bundled notices | Both files match source and are readable; 132 license text groups, nine exact-version MPL source links |
| Actual UDZO disk image control | Created and mounted read-only; application, Applications link and inside/outside notices verified; nested development signature remains valid; detached |
| Development signature rejected by release policy | Pass; cannot be mistaken for Developer ID acceptance |
| Clean local release preflight | Exits 1 before building: Developer ID Application identity unavailable |

The archive's missing app-category warning was reproduced and fixed with
`LSApplicationCategoryType = public.app-category.music`. Debug and archive builds
still emit Xcode's `IDERunDestination: Supported platforms for the buildables in
the current scheme is empty` diagnostic while returning success. It has not been
suppressed or declared resolved. The separately investigated AppKit recursive
layout warning also remains unresolved.

One fresh whole-branch review covered `a4602d0..a021b70`. Its four important
findings were reproduced by failing tests and fixed in one pass:

- Carry the selected certificate fingerprint through archive, export and DMG signing.
- Print Apple's retained log for rejected jobs, accepted jobs with issues, and nonzero submissions.
- Install app and standalone notices as `0644`, including under restrictive umask.
- Stop surviving members of the release process group when cancellation terminates its leader.

The complete 21-test suite passed after the fixes. No deferred minor findings.
The tests use synthetic credentials and subprocess boundaries; they do not
certify a real Developer ID export, Apple service acceptance or remote CI run.

## Open acceptance gates

1. Install the owner-controlled Developer ID Application certificate/private key
   and notarization profile, then run the actual release script.
2. Verify Developer ID export, Apple log acceptance, stapling and Gatekeeper;
   inspect/install the resulting artifact on a second Mac.
3. Integrate completed bring-your-own library work and test it with audio/auth fixes.
4. Perform the user-deferred installed-account Keychain, playback, output-change
   and sleep/wake checks. Preserve the AppKit warning investigation.
5. Configure protected GitHub signing secrets/environment and reviewed tags before
   enabling publication. No secrets, protection settings, tags or releases were
   created or changed during preparation.

[Maintainer setup and commands](../../releasing.md).
[Signed acceptance limitations](2026-10-12-signed-acceptance.md).
[AppKit warning evidence](2026-10-12-appkit-layout-investigation.md).

## Rulings and costs

Recorded in execution order; all acceptance limitations remain explicit.

1. Prepare Tasks 1–4 independently of the active library-client checkout; defer
   public README claims. Cost: release waits for integrated library acceptance.
2. Preserve base-entitlement injection and check exported capabilities. Cost:
   signing fails closed if required capabilities are missing.
3. Pin cbindgen 0.29.4 and cargo-about 0.9.2; use Cargo.lock and propagate tool
   failures. Cost: explicit setup failures instead of silently using other tools.
4. Fetch notarization logs and reject unresolved issues/nonzero submission exits.
   Cost: even accepted submissions with warnings block release pending diagnosis.
5. Put notices inside the app before signing, retain per-run evidence and refuse
   final overwrite atomically. Cost: failed runs consume disk and require inspection;
   existing artifacts must be handled deliberately.
6. Use the small credential wrapper rather than Apple-Actions/import-codesign-certs
   v7.1.0: that action replaces the search list and does not restore the original
   list or remove its generated P12. Cost: our lifecycle needs its own regression
   coverage, including cancellation.
7. Separate read-only signing/build and write-permitted publishing jobs; preserve
   the accepted future tag trigger. Require owner-configured environment protection.
   Cost: artifact transfer and no enforced approval until protection is configured.
8. Hold actual Developer ID/notary/second-Mac acceptance: no certificate is installed.
   Cost: distribution readiness remains unverified.
9. Keep installed-account, playback/output/sleep and AppKit acceptance deferred as
   requested. Cost: those live guarantees remain unverified and AppKit unresolved.
10. Hold BYO integration/Task 5 claims while its separate checkout is active.
    Cost: public release waits for completed integration.
11. Leave GitHub protections and publication to the owner. Cost: remote acceptance
    and approval enforcement remain unverified until configured and run.
12. Accept this turn's actual DMG mount control without an independent remount by
    the reviewer. Cost: it still does not replace distribution/second-Mac acceptance.

Detailed command output and the execution ledger remain in the ignored workspace
`.superpowers/sdd/2026-10-11-release-pipeline/`. The development archive is
`/private/tmp/bopify-release-development-control.xcarchive`; the disk-image control
is `/private/tmp/bopify-dmg-control-zr7ccc0z/Bopify-development-control.dmg`.
These temporary controls are not release artifacts and have not been launched.
