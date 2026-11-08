# Playback, Explore, and lyrics regression checkpoint

User request: explain Client ID/key storage and sign-out, repair shuffle/repeat and related controls, rework Explore, and restore lyrics. Preserve the existing design until a visual demo is approved. Run only relevant tests. Existing adaptive-onboarding changes in this worktree belong to earlier approved work and must be preserved.

## Findings and implementation

- Storage policy is unchanged: public library Client ID and prior-approval marker stay in preferences; OAuth grants and Soloist API key are separate Keychain items. Sign-out clears grants, API key, and Soloist session locally, retaining client configuration. No credentials were read or reset.
- Read-only inspection of the running Soloist process found active single-track playback with no advertised `shuffle` or `set_repeat` actions. Bopify previously enabled both controls and rejected the click. New capability events flow through state/model/UI; unavailable controls are disabled. Supported controls retain observed-state confirmation.
- Repeat-track now uses the two-command transition documented by Spotify. Related pause/resume, next/previous, seek, and volume paths have focused protocol coverage.
- Queue refreshes previously changed the current occurrence ID and repeatedly invalidated lyrics. Current occurrence identity now survives queue-only changes; consecutive same-song occurrences remain distinct.
- Transient lyric failures previously remained failed indefinitely. Visible, unchanged occurrences get bounded retries after 2, 5, and 15 seconds, canceled on hide/stop/replacement. Missing/malformed lyrics remain terminal.
- Explore no longer discards healthy station seeds when one top-items source fails. Authorization and rate-limit failures remain explicit. Transient station failures receive bounded 2/5/15-second recovery, canceled on hide/seed change/clear. A reproduced view-replacement race now restarts the canceled initial station request after joining the shared seed load.
- Safe diagnostics now distinguish metadata credential, account-check, native-session, and request failures, without credentials, IDs, content, or arbitrary error text.

## Verification

- Controls/model/state: 76 focused tests passed; `/tmp/bopify-controls-final.log`.
- Lyrics/session/app routing/native player interaction: 41 focused tests across three suites passed; `/tmp/bopify-regressions-app.log` (includes the earlier 28 lyric checks).
- Explore source isolation/retry/lifecycle: 23 focused tests passed; `/tmp/bopify-explore-handoff-green.log`.
- Explore demo: `build/explore-recovery-demo/index.html`, verified desktop/390px/keyboard and simulated recovery/empty/offline states. Preview and compact screenshots alongside.
- Focused total: 140 tests. Final read-only code review found no blocking issues. `git diff --check` passed.
- Final Release test build and `codesign --verify --deep --strict` passed. Artifact: `build/playback-repair-test-20261108/Build/Products/Release/Bopify.app`, version 1.6.0, build 463. Any approved Explore visual changes remain pending. Actual authenticated provider retrieval remains unverified; no live playback was changed and the running app was not replaced.

## Explore design approval

The user clarified that rework refers to Explore mechanics, not visual design. The visual proposal and its approval request are superseded. Production visuals stay unchanged. The researched mechanics direction was approved and is tracked in `2026-11-08-explore-discovery.md`.

## References

- https://developer.apple.com/documentation/foundation/userdefaults
- https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow
- https://developer.spotify.com/documentation/soloist/reference/websocket-api
- https://developer.spotify.com/documentation/web-api/reference/get-users-top-artists-and-tracks
- https://developer.spotify.com/documentation/web-api/references/changes/may-2026
