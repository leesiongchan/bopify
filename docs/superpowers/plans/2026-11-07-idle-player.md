# Keep the regular player visible after setup

The user's screenshot exposed a legacy URI-entry idle screen left behind by the onboarding redesign. It is content inside the main window, triggered by the absence of track metadata. The intended single-window experience should use the existing record player, search, and library controls after setup, including while idle.

1. Reproduce the idle route selecting startup geometry after completed setup.
2. Use one shared record-player presentation predicate for root content, mode, and native window geometry. Track presence must not select a different interface.
3. Remove the obsolete idle URI form, placeholder startup content, their unused routing model/tests, and exclusive copy. Preserve transport/library behavior and onboarding precedence.
4. Verify idle/playing/onboarding routing, native panel geometry, relevant shared/app tests, and the signed test build. Keep existing user work and the running app intact.

Results are recorded after verification.

## Completed behavior and verification

- Reproduced the old idle route with two failing expectations: completed setup still forced the startup mode instead of the player's normal mode (`/tmp/bopify-idle-player-red.log`).
- Root content, native geometry, and mode now share `isShowingPlayer`, based on completed setup and player existence, independent of track metadata. Onboarding still takes precedence. The regular player already contains Search and LibraryShelf.
- Removed the private URI-entry/idle-placeholder views, five exclusive localization entries, and the unused shared `PlayerContent` routing enum with its six obsolete tests. Preserved the remote-device localization still used by the regular status line.
- Empty regular-player metadata now says “Ready to play” and “Choose from your library.” Loading without metadata uses the loading label; mirrored/unknown track behavior remains intact.
- **28 focused native/app tests passed** (`/tmp/bopify-idle-player-final-focused.log`). These include idle record geometry, onboarding transitions, empty/loading metadata accessibility, and lyrics before first playback.
- **300 app tests across 44 suites passed**, exit 0 (`/tmp/bopify-idle-player-app-all.log`). The shared suite reported **490 tests**, exit 0 (`/tmp/bopify-idle-player-core.log`); the six tests of removed URI-screen routing no longer apply. Standalone signed-CLI integration remains opt-in; the final signed-app check exercised the real SDK separately.
- Signed Release build succeeded and passed signature/security/metadata, official Soloist **1.3.10.51** start/restart/protocol and native Bonjour observation (`/tmp/bopify-idle-player-signed-check.log`). Artifact: `build/idle-player-test-20261107/Build/Products/Release/Bopify.app`.
- Final native metadata capture was generated and visually inspected at `build/test-artifacts/idle-player/metadata.png`; its rendering test passed again after capture generation. Read-only review found no important regression. Localization JSON uniqueness and diff whitespace checks passed.

The previously running app was left untouched. The user must open the new build to receive this UI change; no playback or credential action was performed for this cleanup.
