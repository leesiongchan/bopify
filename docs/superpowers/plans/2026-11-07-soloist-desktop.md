# Soloist Desktop Execution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans task-by-task.

**Goal:** Ship a signed test build using Spotifast's ordinary hardened desktop model, with no Soloist installation-folder prompt and safe preservation of existing setup.
**Architecture:** Existing SoloistInstaller/owned process remain unchanged. Remove sandbox permission glue, migrate legacy local data before auth construction, and add an opt-in real-app installation check that never accesses credentials.
**Tech Stack:** Existing Swift6/AppKit/Foundation/Security, Xcode27, macOS26 arm64. No new dependencies.
**Spec:** docs/superpowers/specs/2026-11-06-soloist-playback-design.md, Approved desktop execution model.

## Global Constraints

- User explicitly authorizes App Sandbox removal; retain hardened runtime, stable signing identity and all artifact validation.
- Preserve unrelated root appearance changes; work in existing isolated branch.
- Never strip quarantine/re-sign Spotify, read actual credentials for tests, guess queue restoration, or run competing audio.
- Migrate non-secret preferences and logout intent before auth; no old executable cache import.
- Actual native container access may prompt; denial must fail closed with retry, never lose data or restore pending grants.

## Review Focus

- Migration failure/permission denial cannot restore retained Keychain grants.
- Old/new pending logout namespaces union; later logout cannot be undone by reimport.
- Existing desktop values/session must never be overwritten; active old process blocks migration.
- Fresh download, original signature and --version work from signed actual app with effective sandbox absent/runtime present.
- No installation bookmark/prompt remains; cancellation, live-child ownership and fallback behavior remain covered.

### Task1: Desktop setup and storage transition

Files: project.pbxproj, AppEnvironment.swift, BopifyApp.swift, SoloistPlaybackController.swift, SoloistSetupView.swift, Localizable.xcstrings, remove SoloistInstallationAccess.swift/Soloist.entitlements; new DesktopDataMigration.swift and DesktopDataMigrationTests.swift; SoloistSetupTests.swift.
- [x] Add failing migration tests: preserve new values, exclude bookmark/cache, union cleanup, one-time import, held lock/live PID, corrupt metadata and conflicting sessions fail safely.
- [x] Run targeted tests RED; implement bounded read-only preference import, cleanup preservation and inactive-session atomic move with marker. Retry startup on failed migration before AppEnvironment exists.
- [x] Remove the permission dependency/phases/copy and obsolete test; add setup assertion that stale bookmark cannot gate installation. Disable Sandbox and enable runtime in both configurations; remove sandbox-only capabilities/entitlements.
- [x] Run focused app/core checks GREEN, inspect diff and commit.

### Task2: Real app validation and test artifact

Files: new SoloistInstallationCheck.swift, BopifyApp.swift, reusable scripts/verify-desktop-app.sh; README and active spec/plan records.
- [x] Add explicit --verify-soloist-installation path before migration/auth. Use a private temporary root, production installer/signature/version checks and cache reuse, fixed output, cleanup on completion.
- [x] Build signed Release app. Verify strict signature, runtime flag, arm64, effective App Sandbox absent, stable designated requirement. Run actual-app fresh installation check with no key/account.
- [x] Run relevant full package/app/native checks, inspect native setup screenshots/keyboard/accessibility. Report baseline GUI focus failures accurately rather than weakening tests.
- [x] One fresh independent review of this desktop delta; one material fix pass, record minor follow-ups. Final build/verification if code changes.
- [x] Commit, preserve resumable evidence and provide exact app plus in-app test steps. Authenticated audio remains explicitly unverified until exercised.


## Execution record

User-authorized desktop model implemented. Both build configurations disable App Sandbox and enable hardened runtime; obsolete entitlement file, folder dialog, bookmark dependency and permission copy removed. Keychain service/account and designated signing requirements are unchanged. Migration runs before AppEnvironment, preserves current values, imports prior preferences without obsolete bookmarks, unions pending cleanup and atomically moves inactive pairing data without executable caches. Another running Bopify instance or orphaned live Soloist blocks startup before authentication. macOS may ask for previous-container access; denial fails closed with Retry/Quit.

TDD: migration tests first failed for missing implementation; focused8 tests then passed. Independent review returned two Important findings (legacy app still running; cleanup loaded before bounded validation) and one Minor (record.hasScrubbed omitted). One fix pass added regressions, blocks other instances before even the migration marker, decodes validated old/new cleanup bytes directly, and preserves scrub learning. Focused10 tests pass. No second review.

Fresh actual certificate-signed Release app at `build/soloist-desktop-test-20261107/Build/Products/Release/Bopify.app` passes strict signature, runtime, arm64 and no-sandbox capability checks. Its opt-in no-credentials check freshly downloads official Soloist1.3.10.51, validates Spotify publisher and --version, verifies cache reuse, then removes the temporary installation. An ad-hoc signed copy matching release signing also passes. The verification script initially misread combined ad-hoc/runtime flag text; it now checks CS_RUNTIME bit16 and passed both positive modes. Negative controls reject non-runtime and hardened-but-sandboxed app copies before launching them. Release packaging invokes this check to prevent recurrence. The full DMG packaging/publishing workflow was not run.

Shared462 tests, probe36, native Clippy/tests (92 core/93 Connect/11 playback plus doctests) and framework build pass. Final full app277 tests reports24 existing window-focus issues; all migration/Soloist suites pass. The search focus failure was previously reproduced on unchanged baseline69922b1. No unrelated tests changed or skipped. Native cached screenshots inspected for secure input, localized text, wrapping and retry height; cached AppKit button/glass compositing remains incomplete, as before. Keyboard/accessibility regressions pass. Existing CoverFlowView Sendable warning unchanged.

Actual user-data migration permissions, Keychain interaction, Spotify pairing, audio and data-service coexistence remain interactive acceptance checks; no actual credentials were accessed or user audio started during automated verification. Test artifact and branch retained; no merge, push or release.
