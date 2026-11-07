# Soloist first-pairing discovery correction

The user reported that the advertised onboarding device is absent from Spotify. Continue the authorized seamless Soloist onboarding work; no new account integration is introduced.

## Evidence and limits

- The actual owned child was running and replied with `auth_state.logged_in=false`. `get_state` is authenticated, so its error before pairing is expected and does not prove a key failure.
- The app bundle lacks Local Network purpose text and Spotify Bonjour declarations. Spotifast has both; Apple attributes helper networking to the parent application. These are concrete packaging omissions, but current evidence does not establish a live permission denial.
- A loopback WebSocket response does not verify LAN discovery. Terminal-based checks may have a different privacy attribution from a normally launched app. No personal keys or stored credentials were read.

Sources: [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy), [Spotifast Info.plist](https://github.com/crmne/spotifast/blob/main/packaging/macos/Info.plist#L17-L22), [Spotify query commands](https://developer.spotify.com/documentation/soloist/reference/websocket-api#query-commands), accessed 2026-11-07.

## Implementation and verification

1. Add meaningful regression coverage for actual Bonjour policy denial versus ordinary network errors; verify red before implementing the monitor.
2. Merge a source Info.plist with generated metadata, declaring the purpose string and `_spotify-connect._tcp` as an array. Extend signed-app verification to reject missing declarations and reproduce that rejection on the prior artifact.
3. Observe real Spotify Bonjour browsing only during pairing; show Local Network settings when the OS explicitly reports policy denial. Guard callbacks across view cancellation/restart and log fixed categories only. Never report browsing as successful account pairing.
4. Make pairing headings truthful, launch the native Spotify desktop app, and retain an explicit safe retry for SDK discovery after permission changes. Restart only unpaired owned setup; preserve existing fallback playback and saved key.
5. Run focused policy/native UI tests and the app suite, build a distinct signed artifact, inspect its effective Info.plist and run signed runtime acceptance. Do not claim personal-key pairing or audio succeeded without live evidence.

Progress and actual results are appended after verification.

## Completed implementation and observed verification

- Added a source Info.plist merged with generated Debug/Release metadata. The final signed bundle contains a nonempty Local Network purpose and an actual Bonjour service array containing `_spotify-connect._tcp`; existing desktop-migration purpose text remains present. The strengthened verifier rejected the previous signed artifact before runtime execution because these declarations were absent.
- Added a pairing-only native Bonjour browser. Only explicit OS PolicyDenied maps to permission recovery; unrelated network failures have separate guidance. Callback generation guards prevent stale state after stopping/restarting. Browsing is never represented as successful Soloist pairing or key validation.
- Pairing now launches the installed Spotify desktop application, offers actual Local Network settings, uses phase-specific headings, and can join/restart an unpaired setup using its saved key. Explicit fallback and sign-out/quit invalidate retry continuation. A regression verifies cancellation, exactly one outgoing shutdown, saved-key reuse, and preservation of fallback track/playback.
- Final focused app run passed **17 tests in 3 suites**, exit 0 (`/tmp/bopify-pairing-final-focused.log`). This covers policy classification, recovery UI actions, disabled busy retry, truthful headings, Return-key submission, library scrolling/validation, and retry lifecycle.
- Full app run executed **293 tests across 43 suites**, exit 65, with **24 issues in nine unchanged window-focus tests** in MusicBrowser, PlayerLyrics, PlayerShortcuts, and PlayerWindow. All new discovery/pairing tests passed. Exact failing test names are recorded in the follow-up section of `2026-11-07-inline-onboarding.md`; no tests were removed or weakened.
- Final signed Release build succeeded. `scripts/verify-desktop-app.sh` passed effective metadata, signature, hardened runtime/no Sandbox, official **Soloist 1.3.10.51** publisher/version/cache checks, daemon start/restart, real loopback replies, and temporary cleanup (`/tmp/bopify-discovery-signed-check.log`). Source/project plist lint, shell syntax, localization JSON, and diff whitespace checks passed.
- Read-only final review found no critical or important issue. Its wording correction for policy denial during a pending OS prompt was applied and retested.
- Test artifact: `build/soloist-discovery-test-20261107/Build/Products/Release/Bopify.app`.

The live process's unauthenticated state was confirmed before its five-minute pairing timeout. No key, token, or stored session credential was read. Historical OS log category checks did not establish an explicit permission denial. Correcting the packaging omission and surfacing future denial is verified; actual LAN advertisement, personal-key pairing, and audible playback still require normal app launch and user approval/testing in Spotify. Loopback acceptance is explicitly not evidence of successful discovery.
