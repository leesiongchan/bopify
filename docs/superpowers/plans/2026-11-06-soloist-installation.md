# Managed Soloist Installation

User direction, 2026-11-06: automatically download the latest Soloist and install it; use Spotifast as reference. Continue native execution on `codex/soloist-feasibility`. This supersedes manual executable selection and authorizes installation work independently of the pending playback feasibility checks.

## Contract

- Download only the official macOS arm64 HTTPS archive directly from Spotify; no bundled/mirrored binary, new remote dependency or administrator install.
- Bound archives to 80 MiB, expanded data to 160 MiB and 64 entries. Use the system libarchive parser; reject traversal, links, special files, duplicate output names and missing executables. Preserve the two supplied notice/changelog files.
- Validate thin arm64 Mach-O and the intact Apple-issued Spotify signing requirement (`com.spotify.soloist`, team `2FNC3A47ZF`) before a bounded `--version` invocation. Preserve OS security policy and quarantine; do not use the inapplicable app-bundle `spctl` assessment.
- Private installation with immutable SHA-256 directories and atomically written current/pending metadata. A local digest detects changes; it is not an independent Spotify checksum.
- Initial installation chooses current. Daily checks stage newer builds; active/paused playback keeps its current build. Activation before launch is explicit. Expiry is 90 days from build time; expired or corrupted builds force renewal. Download failure retains a valid build and reports the update problem.
- Installer needs no Spotify key or OAuth grant. The probe installs automatically before interactive authentication; `--soloist` becomes an optional developer override and `--install-only` verifies installation without playback.

## Tasks and verification

1. Add system-libarchive extraction target to BopifyCore and installer metadata/validation tests in PlaybackTests. Observe missing-interface/behavior failures before implementing archive boundaries, build-date rules, signing validation and installation state. No vendor tests or generated binaries in git.
2. Implement the installer actor in BopifyPlayback with internal injectable network/validator/clock boundaries for deterministic offline tests. Test first install, daily reuse, staging, activation, failure rollback, tamper detection, expired builds, cancellation and concurrent requests. Retain valid current pointers on failed updates.
3. Wire the probe to automatic installation with an install-only mode and retain its explicit-path override. Replace the erroneous standalone-CLI trust assessment with the shared publisher check. Test CLI behavior; run the full probe/package suites and build.
4. Perform an authorized real CDN download, safe extraction, signature verification, version check and repeat cache lookup without any playback login. Record actual results and remaining playback prerequisites. Request one independent review and fix material findings with regression coverage.

Keep the app's playback integration behind the existing live feasibility gates. Do not claim an enabled Soloist app engine merely because installation passes. Preserve all unrelated work.

## Execution evidence

Implemented on `codex/soloist-feasibility`. On 2026-11-06, install-only mode downloaded, verified and privately installed official Soloist `1.3.10.50`, build `1793966524`. A second run reused it without downloading. No key, OAuth, pairing or playback was used.

Independent review found three material defects: conflicting policies shared an in-flight result; expiry/tampering bypassed blocked activation; extraction lost quarantine metadata. Each was reproduced by failing regression assertions and fixed in one pass. Conflicting policies now return `installationBusy`; renewal with blocked activation preserves the pointer, stages the replacement and returns `activationRequired` if no usable current exists. Archive-level and embedded quarantine attributes survive extraction. All 13 installer tests pass, including parameterized expiry/tamper and quarantine cases. Final shared-package suite: 441 passing tests; probe: 36 passing tests; macOS app: 267 passing tests, `xcodebuild` exit 0. C compilation with `-Wall -Wextra -Werror` and diff whitespace checks pass.

Deferred review minors: old build directories remain retained, including duplicate downloads of a pending release. Safe pruning needs runtime ownership knowledge so an in-use build is never removed. Cancellation of the initiating caller cancels its shared download; a canceled joining caller still waits for that bounded flight to finish before cancellation returns. The current probe has one initiating caller; refine waiter cancellation before a multi-caller app integration.

Authenticated playback gates remain pending the user's private key-file path, public developer client ID and interactive pairing. No executable path is needed. Retain the feasibility worktree and progress record for that continuation.
