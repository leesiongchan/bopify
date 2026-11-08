# Soloist-only Playback Implementation Plan

**Approved requirement:** The user explicitly removed librespot as a playback option. Soloist is the sole audio engine; librespot remains limited to missing data services. This supersedes historical fallback requirements in earlier plans.

**Approach:** Remove provider/preference/session fallback state and all alternate playback factory calls. Derive readiness from an owned adopted Soloist engine; propagate failures and keep incomplete setup visible. Cancel setup joins the candidate and pending pairing retry while preserving the saved key. Production recovery uses only Soloist; fixtures explicitly own prepared preview engines or inject an actual engine factory.

- [x] Read current controller, environment, UI and affected fixtures/tests.
- [x] Add no-fallback/missing-key/cancel/retry tests and observe red from removed factory/cancel API requirements.
- [x] Remove alternate playback wiring, session preferences, buttons and obsolete copy; retain companion data repair.
- [x] Run focused app checks, then one complete app suite and record actual failures.
- [x] Review final diff and report live integration limitations.

No credentials, real app launch, live playback process or audio is accessed by this task. Shared-package data adapter changes and signed application verification are owned by root integration.

## Verification and final behavior

- Complete app suite: **298 tests across 43 suites passed**, Xcode exit 0, 63.623 seconds (`/tmp/bopify-soloist-only-final-all.log`).
- Final review added setup-intent revision checks inside the serialized restart, including sign-out guards, so queued restarts cannot outlive cancellation. The affected lifecycle/controller/onboarding/authorization/lyrics suites then passed **53 tests across 5 suites**, Xcode exit 0 (`/tmp/bopify-soloist-only-lifecycle-final.log`).
- Regression coverage includes missing-key account restoration without starting audio, startup failure propagation, no alternate engine construction, ownership-based readiness observation, cancellation of late candidates and pending pairing retry, saved-key retry, and data-service repair preserving the live core. SDK key rejection and discovery initialization failures have distinct recovery messages.
- Localization JSON duplicate-key validation and diff whitespace checks pass. No remaining app playback provider/session/preference APIs, librespot engine calls, or user-facing alternate playback copy remain. The librespot client ID remains for companion data authentication.

Previews own a prepared synthetic engine explicitly; injected recovery factories are actual fixture dependencies rather than fallback callbacks. Live account pairing, real audio, and signed runtime verification remain outside this agent's checks. No credentials, real app launches, or commits were performed.

## Root integration: discovery, data boundary, and normal app launch

The shared `LibrespotEngine` playback adapter and its audio tests were removed. `LibrespotServices` now owns a direct metadata-only FFI session with unconditional `servicesOnly:true`; its native boundary contains only create/destroy, lyrics, radio and artist requests. Rust's existing audio ABI remains for compatibility but has no app Swift playback entry point. Review verified that concurrent native destruction joins workers before the callback context is released.

Discovery experiments isolated the missing advertisement: an official signed Soloist daemon created its ZeroConf server and answered `/zc?action=getInfo` with the expected name and status 101, while a native Spotify Bonjour browser observed an existing Spotify service but not this SDK instance. A standard direct multicast query failed with `EHOSTUNREACH` despite an active IPv4 interface and route in the tool context; this is not proof of the normal app's privacy state. Publishing the same verified SDK endpoint with native DNS-SD made it immediately discoverable. The production implementation uses Foundation's native Bonjour APIs, not an external `dns-sd` process or an alternate audio engine.

`SoloistBonjourPublisher` validates a bounded, redirect-free loopback SDK identity response, publishes `_spotify-connect._tcp` with `VERSION=1.0` and `CPath=/zc`, and awaits native observation of its own registration. The owned engine coalesces publication and unregisters/joins before stopping the SDK child. Restored paired sessions remain independent of LAN publication. A reproduced concurrent-pairing race now preserves successful pairing if publication reports a late error; its regression was observed red then green.

SDK verbose output is drained through an owned bounded reader and reduced to eight fixed diagnostic categories. Raw vendor output and key material are never logged. The parser covers real signed-CLI formatting, including the ANSI reset after the pairing path, and reports actual key rejection or discovery startup failures only after an observed unpaired auth state. Installation makes one fresh official-release check per app launch, retaining existing offline/cache behavior for subsequent retries.

Final verification:

- **496 shared Swift tests passed**, including signed CLI restarts and fixed diagnostics: Playback 268, Auth 105, Domain 36, Library 87 (`/tmp/bopify-soloist-only-core-final.log`).
- **298 app tests across 43 suites passed** on the integrated sources (`/tmp/bopify-soloist-only-app-final.log`). The subsequently reproduced publication/pairing race passed its focused three-test set and the final complete shared suite.
- The final signed Release app passed strict signature/security/metadata validation and fresh official **Soloist 1.3.10.51** installation, restart, protocol and **native Bonjour observation** (`/tmp/bopify-soloist-only-signed-check.log`). The acceptance check now explicitly includes native discovery rather than equating a WebSocket endpoint with discoverability.
- Fresh read-only review found no confirmed important issue; the pairing race considered during review was reproduced and corrected in the material fix pass. Diff whitespace, source/project plist lint and shell syntax passed. The existing unchanged `CoverFlowView` actor-isolation warning remains.
- After verification, root opened the signed app normally through LaunchServices with the user's saved setup. The normal app restored its account, started its owned Soloist child, validated the public pairing server and logged native Bonjour observation. A separate native browse confirmed the exact device name shown by that normally running instance. No tool read or printed the user's saved API key, OAuth token or stored session credentials; the app used its own existing credential stores.
- The artifact is `build/soloist-only-test-20261107/Build/Products/Release/Bopify.app`; it was left running for interactive pairing. Spotify desktop device-picker confirmation and audible playback still require the user's selection. No playback/transfer command was sent during these checks.

Native publication follows the standard Spotify discovery service/TXT contract demonstrated in [librespot's discovery implementation](https://github.com/librespot-org/librespot/blob/dev/discovery/src/lib.rs). The SDK continues to handle the authentication exchange and all audio itself.

## Follow-up: Recents selection and idle Explore access

Recent and Explore song selections now send the exact selected track URI to the owned Soloist socket. They no longer request a historical context offset or claim to restore the rest of that playlist/mix. The current [Soloist WebSocket reference](https://developer.spotify.com/documentation/soloist/reference/websocket-api) documents URI playback without a context-offset field.

The removed librespot audio adapter means metadata access no longer needs proof that the local device is already playing. A paired, adopted Soloist engine can resolve radio, lyrics and artist songs while idle, paused or inactive, using a separate ordinary library token and streaming token. Both grants must return the same nonempty immutable `/me.account_id`; missing identifiers and mismatches fail closed, without substituting legacy `id`. Spotify identifies this public field as the account-linking identifier in its [profile reference](https://developer.spotify.com/documentation/web-api/reference/get-current-users-profile) and [May 2026 changes](https://developer.spotify.com/documentation/web-api/references/changes/may-2026). No additional private-profile, email or playback scope is requested solely for that field; this is a field-level documentation inference, and no personal account was used to verify endpoint scope behavior.

Concurrent first metadata requests join one account check and one data-only session creation. Credential replacement, authorization suspension, Core authentication changes and shutdown invalidate old results, including replies already in flight. Device ID and advancing-playback correlation remain separate requirements for Web API playback mutations and remote observation; optional playback consent or HTTP rate-limit failures do not revoke an authorized metadata session. Tests that previously required moving-device proof before metadata were changed because they enforced the obsolete combined audio/data boundary.
