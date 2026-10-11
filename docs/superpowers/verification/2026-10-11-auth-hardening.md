# OAuth callback and credential-storage verification — 2026-10-11

Worktree: `/Users/leesiongchan/.codex/worktrees/db27/bopify`; branch: `codex/audio-output-recovery`. This follows audio recovery commit `e8b4c9f`. The main checkout and its existing uncommitted work were preserved.

## Corrected behavior

The loopback listener accepts only a complete bounded GET request at the configured callback path with one matching state and an unambiguous nonempty code or provider error. Unrelated paths, wrong/missing state, duplicate parameters, empty provider errors, fragments, incomplete requests and oversized headers cannot complete active consent. Connections have an 8 KiB header limit, a five-second deadline and a 32-connection bound. The first validated result survives concurrent callbacks and stop; listener identifiers prevent old connections affecting a restart. Browser response sending finishes before normal consent completion stops the listener.

OAuth error callbacks must carry the original state when it was supplied. [RFC 6749 §4.1.2.1](https://www.rfc-editor.org/rfc/rfc6749#section-4.1.2.1), checked 2026-10-11. Existing native-app PKCE and loopback transport are retained. [RFC 8252 §7.3](https://www.rfc-editor.org/rfc/rfc8252#section-7.3), checked 2026-10-11.

Keychain reads return nil only for `errSecItemNotFound`. Inaccessible, denied, unexpected and malformed stored items now throw; failed restoration preserves cached and stored credentials. Existing service/account, stored format and Keychain implementation remain compatible with installed grants. Credential errors have user-facing explanations and manual retry actions, with separate progress text for saved-sign-in checks. Corrupt credentials and failed initial-consent saves offer explicit sign-in again; retrying saved credentials does not open consent. Network changes and wake do not restart a credential failure automatically.

A shared refresh now includes persistence: every waiter either receives a saved result or fails together. A newly returned refresh grant survives temporary save failure in memory and can be saved on manual retry without another token request. If it expires while waiting, the retained grant is saved before renewal using its replacement refresh token. Sign-out, cancellation and new consent invalidate pending refresh results before they can persist. Spotify documents replacement refresh tokens and retaining the old token when omitted. [Spotify: Refreshing tokens](https://developer.spotify.com/documentation/web-api/tutorials/refreshing-tokens), checked 2026-10-11.

## Verification

Logs are under `/private/tmp/` on this machine.

| Check | Result | Evidence |
| --- | --- | --- |
| Callback regressions before implementation | Failed for interference, fragmentation and truncated responses | `bopify-auth-red-callback.log` |
| Storage regressions before implementation | Corruption returned nil; one refresh waiter returned an unsaved token | `bopify-auth-red-storage.log` |
| Manual persistence retry before fix | Repeated refresh instead of saving the retained grant; credential retry unavailable | `bopify-auth-red-retry.log` |
| Independent-review regressions before correction | Empty provider errors consumed consent; expired pending token returned | `bopify-auth-red-review.log` |
| Full Swift package suite | 332 tests passed: 177 playback, 56 library, 28 domain, 71 auth; no compiler warnings | `bopify-auth-final-swift.log` |
| Debug app build | Passed | `bopify-auth-final-debug-build.log` |
| Hardened development Release build | Passed | `bopify-auth-final-release-build.log` |
| Release deep/strict signature verification | Passed with macOS trust services outside sandbox | `bopify-auth-final-signature.log` |
| Credential UI fixture | Passed startup unavailable/denied/corrupt states, narrow layout, actual accessibility retry, no unsolicited browser, stable player/frame in compact/expanded/queue, and UI diagnostic checks | `bopify-auth-ui-after.log`; captures in `bopify-auth-ui-after/` |
| Offline library fixture | Passed consent, teardown, dual-store sign-out and late-consent ordering with isolated Keychain services | `bopify-auth-library-probe.log` |
| Updated live recovery probe | Compile passed; not executed | `bopify-auth-live-probe-compile.log` |
| Independent code review | No remaining blocking OAuth or credential findings | Final read-only reviews after correcting both reproduced findings |
| Whitespace check | Passed | `git diff --check` |

Reproduce automated checks:

```sh
swift test --package-path Packages/BopifyCore
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-audio-debug-build -quiet build
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-audio-debug-build --output /private/tmp/bopify-auth-ui-after --probe credentials
python3 docs/superpowers/verification/run-monolith-probe.py --derived-data /private/tmp/bopify-audio-debug-build --output /private/tmp/bopify-auth-library-probe --probe library
```

Visual inspection confirmed localized credential messages and an accessible retry button at 320 × 480, plus the existing recovery row and compact menu. Long recovery messages use the existing truncation/help behavior; actions remain visible and full messages remain available to accessibility. The fixture runner now includes the existing test engine required by its library fixture. The live probe was only compiled; no real Spotify credential or live session was accessed.

## Remaining acceptance limits

The baseline general recovery UI probe still fails its existing AppKit layout-diagnostic assertion (`bopify-auth-ui-before.log`); the isolated credential-panel probe passes the same diagnostic checks. This change does not establish an AppKit fix. Xcode still emits its supported-platform tool diagnostic despite successful builds. The first sandboxed signature check could not evaluate trust; repeating it with normal macOS trust-service access succeeded.

Tests inject Keychain status results and use separate test-only services for actual storage operations. Physical locked-Keychain/ACL behavior and signed installed-app access still need acceptance testing. Pending unsaved refresh grants are memory-only: quitting during a persistent storage outage cannot make them durable. Hardware audio recovery, signed end-to-end acceptance, Developer ID/notarization, and public distribution remain open gates. This is a tested auth correction, not a claim that the entire app is ready for public production release.
