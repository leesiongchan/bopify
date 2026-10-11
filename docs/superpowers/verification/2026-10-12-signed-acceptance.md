# Signed acceptance preflight and real Keychain verification

Date: 2026-10-12. Base revision: `c2eba77`; branch `codex/audio-output-recovery`, isolated worktree `/Users/leesiongchan/.codex/worktrees/db27/bopify`. Host: macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), arm64. The only production change enables hardened runtime in the existing Release target. No installed app, saved Spotify credentials, live playback, or production authentication/storage implementation was changed.

## Corrected acceptance artifact

The earlier development Release at `/private/tmp/bopify-audio-release-build/Build/Products/Release/Bopify.app` had a valid signature and hardened runtime, but no embedded capability entitlements. Its build override `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` removed this project's generated sandbox/network capabilities as well as debugger permission. Signature validity alone therefore did not establish sandbox parity. The earlier auth/audio build records remain historical results, not signed sandbox acceptance.

Initial preflight enabled hardened runtime with a command-line override. The Release target now enables it by default; this final normal Release build used normal base-entitlement injection and no signing overrides:

```sh
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-signed-acceptance-build -quiet build
```

The generated and signed dictionaries both contained sandbox, client/server networking, user-selected read-only files, and the development debugger entitlement. A temporary copy at `/private/tmp/bopify-signed-acceptance/Bopify.app` was re-signed with the same Apple Development identity and hardened runtime, using the verified dictionary with **only** `com.apple.security.get-task-allow` removed. The original build product was retained. The copy was not launched or installed.

Before acceptance, the final signed dictionary was compared against this exact capability set:

| Entitlement | Signed value |
| --- | --- |
| `com.apple.security.app-sandbox` | true |
| `com.apple.security.network.client` | true |
| `com.apple.security.network.server` | true |
| `com.apple.security.files.user-selected.read-only` | true |
| `com.apple.security.get-task-allow` | absent |

[Retained entitlement plist](signed-acceptance-2026-10-12/acceptance.entitlements), [extracted signed dictionary](signed-acceptance-2026-10-12/acceptance-entitlements.log), [strict/deep verification](signed-acceptance-2026-10-12/acceptance-verify.log), and [signature/runtime metadata](signed-acceptance-2026-10-12/acceptance-signature.log) confirm those checks. Team identifier remained `6RS6K2N242`. Personal certificate identity text is redacted in committed logs; diagnostic contents otherwise retain the run output with whitespace normalized.

Before this change, effective Release settings reported hardened runtime disabled. The one-line Release target correction now resolves to `ENABLE_HARDENED_RUNTIME=YES`; Debug retains its previous value. [Final Release settings](signed-acceptance-2026-10-12/final-release-settings.json), [Debug settings](signed-acceptance-2026-10-12/final-debug-settings.json), [normal-build signature/runtime](signed-acceptance-2026-10-12/default-release-signature.log), [normal-build entitlements](signed-acceptance-2026-10-12/default-release-entitlements.log), and [strict verification](signed-acceptance-2026-10-12/default-release-verify.log) confirm hardened runtime and all intended capabilities without overrides. The temporary debugger-free copy was prepared with the same hardened setting during preflight. Development signing still includes debugger permission in the normal build; the distribution export must remove it. Apple's build-setting reference describes base-entitlement injection. [Xcode Build Settings Reference](https://developer.apple.com/documentation/xcode/build-settings-reference), checked 2026-10-12.

For public distribution, use Xcode's archive/export signing workflow and verify the resulting artifact's full capabilities and hardened runtime. Apple explains that standard distribution export removes debugger permission; globally disabling injection is insufficient for this project's generated capabilities. [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues), checked 2026-10-12. The temporary re-signing here prepares a development acceptance candidate, not a release pipeline or Developer ID/notarization result.

The initial and final normal builds passed with no compiler warning in [initial output](signed-acceptance-2026-10-12/build.log) and [normal-build output](signed-acceptance-2026-10-12/default-release-build.log). Xcode still emitted its existing supported-platform tool diagnostic. A sandbox-restricted XML entitlement display also emitted a misleading invalid-blob warning; normal macOS signing-service access produced the valid dictionary and passed strict signature verification.

## Real signed sandbox Keychain boundary

[SignedKeychainProbe.swift](SignedKeychainProbe.swift) links the freshly built production `BopifyAuth` and `BopifyDomain` Release objects. It calls the production `KeychainTokenStore`, with two services constructed from a fixed validation-only prefix and a validated UUID. Every value is synthetic. It never accepts arbitrary service names or falls back to the production default.

The probe is a separate Apple Development signed app, `com.leesiongchan.bopify.validation.keychain-probe`, under the same team, with the four capabilities above, hardened runtime, and no debugger permission. Its signature and actual embedded dictionary were checked before execution. It does not use fake Keychain status results or start Spotify.

| Phase | Verified behavior | Exit |
| --- | --- | ---: |
| `write` | Both services absent; add two synthetic grants; complete `TokenSet` round-trip equality | 0 |
| `verify` (fresh process, same signed app) | Both grants persist; update every playback field; delete playback while library remains intact | 0 |
| `cleanup` (fresh process) | Clear both exact test services; verify both absent | 0 |

[Signed probe output](signed-acceptance-2026-10-12/keychain-probe.log) records each successful invocation and signature checks. [Run UUID and exact phase commands](signed-acceptance-2026-10-12/probe-commands.txt) identify the original synthetic namespace. The runner attempted cleanup in `finally`, including on a write/verify failure. No test entries remain from this run.

To compile the fixture against fresh Release objects:

```sh
swiftc -parse-as-library -swift-version 6 -warnings-as-errors -target arm64-apple-macosx14.0 -module-cache-path /private/tmp/bopify-signed-acceptance/module-cache -I /private/tmp/bopify-signed-acceptance-build/Build/Products/Release docs/superpowers/verification/SignedKeychainProbe.swift /private/tmp/bopify-signed-acceptance-build/Build/Products/Release/BopifyAuth.o /private/tmp/bopify-signed-acceptance-build/Build/Products/Release/BopifyDomain.o -framework Security -o /private/tmp/bopify-signed-acceptance/KeychainProbe
```

Put the executable in a fresh `.app` bundle with the probe identifier and `CFBundleExecutable=KeychainProbe`, sign it using the retained entitlements and `codesign --options runtime --timestamp=none --sign 'Apple Development' --entitlements ...`, then verify the strict signature, runtime/team identity, and embedded dictionary before running it. Reuse the same signed app for all three phases. Generate a fresh UUID for every new test. Always attempt cleanup:

```python
import subprocess
import uuid

exe = "/private/tmp/bopify-signed-acceptance/KeychainProbe.app/Contents/MacOS/KeychainProbe"
identifier = str(uuid.uuid4())
try:
    subprocess.run([exe, "write", identifier], check=True, timeout=30)
    subprocess.run([exe, "verify", identifier], check=True, timeout=30)
finally:
    subprocess.run([exe, "cleanup", identifier], check=True, timeout=30)
```

If a process is force-killed or the machine shuts down before cleanup, the runner cannot guarantee cleanup; retain its UUID and run the cleanup phase explicitly. The fixture prints checks and status errors, never token values. Invalid phase/UUID arguments exit 2 before constructing a store. The fixture's compiled deployment target is macOS 14; older-OS execution remains unverified.

## Acceptance limits

This establishes real synthetic Keychain add/read/update/delete and persistence under the probe's signed sandbox identity. It does not establish access to an existing installed grant's ACL, signing-upgrade continuity, locked-Keychain behavior, or Data Protection Keychain semantics. The production store's existing file-based Keychain identity and format are unchanged.

Physical live testing was deferred by the user. The prepared signed Bopify copy is ready for that later run, which must verify normal installed-account access, audible audio-output loss/recovery, and sleep/wake behavior. The AppKit layout warning remains separately unresolved. Developer ID signing, notarization, distribution-export verification and clean installation remain open. This is completed automated preflight evidence, not production-release sign-off.
