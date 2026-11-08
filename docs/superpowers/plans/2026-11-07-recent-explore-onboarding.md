# Recent playback, Explore, and onboarding refinement

The user reported Recent playback and Explore failures, and requested a researched onboarding refinement with Liquid Glass inputs and readable steps. Soloist remains the sole audio engine; librespot remains a metadata-only service.

## Diagnosis and approach

Recent and Explore selected-song requests contain a context offset. Soloist's documented local play command accepts a URI, while the implementation sends offsets through Web API playback. That path requires a verified device with already advancing playback. Explore's metadata session shares that proof gate, producing an idle-to-playback dependency loop; it can also cache a failure while background setup is still pending.

Clicked songs will load the exact selected URI through Soloist. Metadata access will validate the library and streaming OAuth accounts independently, using matching immutable `account_id` values and retained token/revision guards. Reads cannot register a playback device or issue audio commands. Strong local-device correlation remains required for Web API playback mutations and remote playback observations. A metadata request will join pending identity/session setup instead of failing merely because warmup is still in progress.

This intentionally replaces the historical combined companion/device gate: read-only radio, lyrics, and artist data belong to the two matching authorized OAuth accounts, and do not require the paired audio device to be playing. A direct selected-track load does not preserve the previous playlist or radio context's continuation; no undocumented Soloist offset command or guessed queue replacement is introduced.

The app will supply a separate ordinary library-grant token for metadata identity, keeping the existing optional playback-scope provider separate. No new private/email scope is added based on a guess: Spotify documents `account_id` as public/immutable, although the endpoint's scope header is less specific. Missing identity or authorization still fails closed.

For onboarding, keep one main-window flow and record animation. Use native regular Liquid Glass for labeled interactive inputs, a stable instructional surface, semantic foreground colors, readable named step progress, and concise numbered instructions. Preserve secure entry, saved-key reuse, focus, Return/Tab, cancellation, scrolling, and reduced-transparency/high-contrast/reduced-motion settings.

## Work and verification

1. Reproduce the request/proof and warmup gates with regressions, then fix Recent/Explore and data-only authorization without weakening playback-device proof.
2. Wire separate metadata credentials through the app/controller and review consent behavior; avoid extra permissions for basic read-only identity.
3. Implement and render onboarding changes in light/dark and accessibility configurations; keep inputs secure and keyboard accessible.
4. Run affected shared/native suites, full checks as appropriate, inspect final diff and signed artifact, and document live-provider limits. No real playback command is authorized merely for testing without an intentional user action.

Research: [Soloist WebSocket API](https://developer.spotify.com/documentation/soloist/reference/websocket-api), [Spotify profile](https://developer.spotify.com/documentation/web-api/reference/get-current-users-profile), [May 2026 Web API changes](https://developer.spotify.com/documentation/web-api/references/changes/may-2026), [Apple materials](https://developer.apple.com/design/human-interface-guidelines/materials), [text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields), and [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), accessed 2026-11-07. The detailed UI research and rendering evidence is tracked in `2026-11-07-onboarding-readability.md`.

## Final implementation and verification

Recent and Explore now construct direct selected-track requests. The obsolete historical-context storage in Recent is removed. Metadata account/session setup is independent of optional playback proof and single-flight; a creation task owns publication, concurrent first requests join it, and credentials are re-read before results are returned. Suspension, re-pairing, logout, token replacement and stale in-flight replies remain guarded. Optional playback proof and remote observation retain their separate credential/device correlation and cannot downgrade a functioning metadata session merely because Web playback is throttled.

The app supplies an ordinary library-grant `dataToken` separately from playback-scoped `webToken`; required scopes are unchanged. Onboarding uses native labeled editors with interactive regular Liquid Glass chrome and visible focus, a semantic opaque content background, readable named step numbers, and numbered registration instructions. The native scroll bridge, secure-entry semantics and keyboard behavior remain in place.

Observed results on 2026-11-07:

- Initial regressions exposed the old context requests/combined gate and missing field labels/native bezel. Final focused groups passed 42 shared and 21 native UI tests.
- Full `swift test`: **499 tests passed**, exit 0 (`/tmp/bopify-playback-onboarding-core.log`).
- Full `BopifyAppTests` scheme: **303 tests across 44 suites passed**, Xcode exit 0 (`/tmp/bopify-playback-onboarding-app.log`).
- Signed arm64 Release build passed (`/tmp/bopify-playback-onboarding-release.log`). The existing unrelated CoverFlow coordinate-space actor-isolation warning remains.
- `scripts/verify-desktop-app.sh` passed for `build/playback-onboarding-test-20261107/Build/Products/Release/Bopify.app`. Strict signature/hardened-runtime/local-network metadata checks and the actual app's isolated installation check passed: official Soloist **1.3.10.51**, publisher/version validation, fresh install plus cached reuse, daemon start/restart, local protocol, native Bonjour observation, and temporary cleanup (`/tmp/bopify-playback-onboarding-desktop.log`). This path does not load user credentials.
- One fresh read-only review found no actionable correctness/security/regression issue. Final `git diff --check` passed. Native Rust code and ABI were unchanged; native Rust checks were not repeated for this Swift/UI change.

Light/dark compact/regular instructional captures were inspected. Native cacheDisplay omits GPU transforms/glass compositing; those captures establish wrapping/layout evidence, not full live composited appearance. See `2026-11-07-onboarding-readability.md` for capture paths and accessibility/keyboard evidence.

Authenticated Spotify playback, real radio/lyrics/artist responses, and full live composited onboarding appearance remain unverified in this change. No credential files/Keychain values were read by tools and no real playback/transfer command was sent. To validate the account-dependent behavior, quit the previous build, open the new app, play a centered Recent cover, open Explore while idle, and inspect Setup from the app menu.
