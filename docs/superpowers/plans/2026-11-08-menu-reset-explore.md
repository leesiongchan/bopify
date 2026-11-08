# Menu cleanup, Client ID reset and live Explore failure

The user again asked why Setup remains in the menu, how to delete the developer Client ID for first-run testing, and why Explore still fails.

## Changes and storage

- Removed the unconditional Setup menu item, obsolete selector and unused `menu.setup` localization entry. Automatic onboarding/recovery still calls `showOnboarding` directly.
- Client ID remains public preferences configuration: domain `com.leesiongchan.bopify`, key `library.clientID`; prior approval marker `library.approvedClientID`.
- Full account-onboarding reset instructions: Sign Out, quit Bopify, then delete those two targeted defaults keys. Sign-out clears OAuth grants, Soloist key and session; deleting only preferences is not a credential reset. The engine download and appearance preferences remain. No user data was reset by tools.

### Correction: use the explicit preferences path

The user reported that unqualified `defaults delete com.leesiongchan.bopify …` found neither key. Read-only inspection confirmed both literal keys exist in `~/Library/Preferences/com.leesiongchan.bopify.plist`, and the current app has sandbox disabled. On this Mac, the unqualified defaults domain resolves instead to `~/Library/Containers/com.leesiongchan.bopify/Data/Library/Preferences/com.leesiongchan.bopify`, which is absent. Explicit path-based reads succeed for both keys. Do not infer that the real keys were already deleted from that error.

After Sign Out and quit, use:

```sh
/usr/bin/defaults delete "$HOME/Library/Preferences/com.leesiongchan.bopify" library.clientID
/usr/bin/defaults delete "$HOME/Library/Preferences/com.leesiongchan.bopify" library.approvedClientID
```

The `.plist` extension is omitted per `defaults help`. At investigation time build 466 was running (PID61262); no app quit or preferences mutation was performed by tools. Checks printed only key-presence booleans, never stored values or Keychain data.

## Confirmed live failure

Safe logs prove profile HTTP 429 on the streaming grant after the library-account check succeeds. This prevents metadata-session creation before radio lookup. Latest actual run PID45066 repeated the same failure between 12:19 and 12:21 on 2026-11-08. Source: `/tmp/bopify-explore-current-failure.log`. Earlier mechanics/mock checks do not establish live provider availability.

The current architecture uses a user-configured library OAuth client and a separate built-in shared streaming client. Deleting the stored library Client ID does not remove the latter or clear server-side throttling.

Spotify's July 2026 rules distinguish rolling app rate limits from development-mode developer-account quotas (`error.reason = QUOTA_EXCEEDED`). Existing logs dropped this field and Retry-After, so they do not prove which quota/rate bucket caused this failure. Never claim a shared-client global quota is established from HTTP 429 alone.

Narrow diagnostic change complete: record normalized retry delay/deadline before optional body consumption, then an allowlisted quota classification from at most 8 KiB. No response messages, arbitrary reasons, tokens, IDs or payloads are logged. Cooldown/cancellation semantics and the existing resource timeout remain intact; authentication, identity guards, persistence and retry policy are unchanged.

## Own-client alternative research

A Dashboard client with `streaming` scope is documented for Web Playback SDK, which does not prove native librespot metadata compatibility. The pinned native fork defaults to a shared keymaster SessionConfig; AP login and later login5 metadata access are separate stages. Pinned login5 source requires matching client/stored-credential identity. An own-client migration requires an explicitly authorized compatibility test of consent, native AP login, login5 and actual lyrics/radio requests, plus refresh/restart and account verification. Do not switch tokens or bypass identity checks based only on scope names or successful AP login.

## Verification/progress

- Localization JSON parsing and reference search passed; no remaining `menu.setup`/`showSetup` source references.
- Final signed Release build 466 and `codesign --verify --deep --strict` succeeded at `build/menu-cleanup-test-20261108/Build/Products/Release/Bopify.app`; final log `/tmp/bopify-menu-cleanup-release-final.log`.
- Focused throttle checks: 3 tests covering 10 cases passed in `/tmp/bopify-throttle-diagnostics-verified.log`. Quota/malformed/oversized HTTP bodies preserve cooldown; controlled streaming verifies gating precedes body completion and cancellation is retained. No full suites were run.
- Explore's live account check remains unresolved; this build must not be presented as removing Spotify's server-side limit. The next actual response can distinguish quota classification and retry deadline safely.
- No credentials read, real playback/API requests, app launch/replacement, auth migration or commits performed.

## Primary references

- https://developer.spotify.com/documentation/web-api/concepts/quota-modes
- https://developer.spotify.com/documentation/web-api/references/changes/july-2026
- https://developer.spotify.com/documentation/web-api/concepts/rate-limits
- https://developer.spotify.com/documentation/web-playback-sdk/howtos/web-app-player/
- https://github.com/leesiongchan/librespot/blob/80f49d50bf46ac454255f02c2fe0ed46ddf01fa6/core/src/login5.rs
