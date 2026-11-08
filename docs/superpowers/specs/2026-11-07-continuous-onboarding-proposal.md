# Continuous onboarding refinement — proposal

Status: **Approved by the user (“perfect”) on 2026-11-07 for implementation.** The user requires a demo before further design changes and only tests related to the changed behavior. Preserve the original Aurora, record artwork, centered composition, and one-window experience. Implementation baseline is `2f70cc6`.

Interactive reference: `build/onboarding-continuous-demo/index.html`. This is an isolated browser mock-up, not native Liquid Glass or authenticated Spotify behavior. Play the full demo to inspect library, playback and completion transitions. The mock-up also exposes reduced motion and simulated network/permission recovery.

## Findings

The rectangular `StartupReadabilityBackdrop` in `StartupView.swift` is sized to form content and extended with fixed negative padding. Only the Aurora is clipped in `StartupSurface`; `PlayerSurface` does not clip foreground content. These verified source facts explain how the reported square tint corners and content-height bottom edge can occur; exact screenshot pixel attribution has not been reproduced in a composited native capture.

Library authorization immediately changes auth state and starts the player connection. The startup's animation observes only broad `StartupStep` values, so several playback subphases have no distinct presentation transition. Ready dismisses onboarding immediately; `PlayerRootView` swaps the entire root branch and first player geometry attaches with motion disabled. There is no presentation-owned completion handoff.

The primary setup actions use the shared glass-styled `StartupButton`, but `SoloistPairingGuidance` constructs an ordinary `Button` for Open Spotify. That missed reuse explains its inconsistent appearance.

“Retry discovery” currently cancels setup and restarts Soloist, choosing a new UUID device name. The diagnostic NWBrowser also retains its instance after failure and has no setup-specific network/activation retry hook. Normal engine pairing already polls and waits automatically. Recovery must build on that ownership, not repeatedly restart a healthy child while the person selects it.

## Proposed response to the feedback

| Feedback | Proposed behavior |
| --- | --- |
| 1. Black corners | Clip the complete onboarding composition once to the window's rounded shape; keep everything outside transparent. |
| 2. Heavy black layer | Remove the form-sized black rectangle. Use one continuous Aurora surface with subtle full-viewport depth and quieter color placement behind text. Native regular glass belongs on controls. |
| 3. All-white hierarchy | Warm primary headings, readable sage/neutral supporting copy, blue interactive actions, restrained amber progress and green confirmation. Use native semantic/vibrant colors where available; do not encode state by color alone. |
| 4. Bottom seam | Tie the background treatment to the viewport rather than the form's current height. No content-relative overlay edge or padding-based extension. |
| 5. Library handoff | Acknowledge library approval briefly, then cross-fade the content while retaining the same record, window and background. |
| 6. Redundant actions | Remove “Cancel setup” and “Library access” from the normal playback setup view. Keep lifecycle cancellation for quit/sign-out and contextual recovery; configuration remains available from Setup after onboarding. |
| 7. Duplicate key label | Remove the separate visible “Soloist API key” label. Keep the clear placeholder, persistent purpose in the introductory sentence, native SecureField and explicit accessible name. |
| 8. Playback naming | Use **Start listening**, describing the outcome. Mention Soloist only where people need to obtain its personal key; avoid an audio-engine configuration concept. |
| 9. Playback subphase changes | Give preparation, Spotify pairing and final connection presentation identities with coordinated cross-fades. Keep the record instance and native input identity stable during progress. |
| 10. Retry discovery | Remove the routine retry button. Resume recoverable discovery automatically on browser failure, network restoration or return from Settings, with bounded backoff and the same pairing identity. Ask only for actions the person must take. |
| 11. Open Spotify | Use the same native glass primary-action treatment as the other onboarding actions. |
| 12. Messy pairing text | **Connect in Spotify** → “Select this device, then play a song.” → device name → **Open Spotify** → quiet waiting status. No implementation/proof/muting explanation in the normal view. Show permission help only when necessary. |
| 13. Completion jump | On actual readiness, show a brief check/“Ready to play” acknowledgement and carry the same record into the existing player. Advance automatically, without an extra Finish button or playback command. |
| 14. Marketing copy | **Welcome to Bopify** / “Connect your Spotify account.” / **Continue with Spotify**. Keep the Premium requirement subordinate. Use **Connect your library** / “Browse your saved music in Bopify.” |

## Flow and boundaries

Three setup groups remain: account → library → listening. Progress is compact and accessible. Additional mock-up selector entries are inspection controls outside the product, not added onboarding requirements.

The normal path has one primary action per view. Client ID instructions use progressive disclosure with the exact redirect URI and dashboard link; an existing grant or saved key is reused without repeated entry. Do not hide essential registration or permission requirements. Do not imply a client secret is required.

The prototype demonstrates roughly 130 ms outgoing / 240 ms incoming fades with a small offset and a brief completion acknowledgement. These durations are a proposal, not Apple-prescribed values. The native version should use coordinated SwiftUI/AppKit transitions, allow interruption, and follow Reduce Motion with short opacity changes instead of spinning or spatial morphs. Do not add a celebratory delay on every subsequent launch or make service readiness wait for animation.

Keep readiness and presentation separate. A presentation coordinator must own the final handoff across startup/player branches and retain generation/cancellation guards. It cannot be implemented solely as a delay in a disappearing startup view. No unsolicited playback, auth changes or replacement of the current player design is proposed.

Automatic recovery cannot grant macOS permission, authorize Spotify, supply personal keys or choose the initial device on the person's behalf. It must not silently mask denied permission or account/key failures. A permission-specific Settings action can appear when needed; ordinary waiting stays automatic. Restart only failed owned components when needed, preserve a stable per-setup name, respect server backoff, and cancel/join recovery on readiness, sign-out, quit or superseded setup.

## Research, accessed 2026-11-07

- [Apple Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding): favor brief interactive setup, context-specific help, and postponement of nonessential configuration. This supports progressive registration help and removal of routine troubleshooting controls, not hiding necessary Spotify setup.
- [Apple Materials](https://developer.apple.com/design/human-interface-guidelines/materials): distinguish the content surface from functional Liquid Glass; regular glass adjusts luminosity for legibility, while clear glass is intended for visually rich backgrounds. This supports preserving the Aurora and using regular glass for primary controls, not applying a dark rectangle to all instructional content.
- [Apple Color](https://developer.apple.com/design/human-interface-guidelines/color): color communicates hierarchy and interactivity; use it consistently and accommodate appearance and contrast settings. Palette choices here are a proposal and require native contrast review across Aurora states.
- [Apple Motion](https://developer.apple.com/design/human-interface-guidelines/motion): motion should communicate relationships and feedback, remain brief, and support people who reduce motion. This supports a persistent record and a short completion-to-player handoff, without confetti or gratuitous waits.
- [Apple Writing](https://developer.apple.com/design/human-interface-guidelines/writing): use clear, concise, action-oriented words and avoid clever or jargon-heavy control labels. The proposed copy describes actions and outcomes directly.
- [Apple Text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields): placeholders can explain purpose; labels can retain context while editing, and secrets require secure fields. Here the intro retains purpose, the accessible field name is permanent, and the duplicate visual label is removed.
- [SwiftUI Liquid Glass transitions](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views): shared effect identity/container transitions can coordinate appearing/disappearing controls. Native motion must be designed alongside the actual record and window geometry; the browser's CSS is only a visual proposal.

Official Markdown versions of the Onboarding, Motion and Materials pages were read directly after the web tool rejected their `text/markdown` content type. Source content was treated as reference material, not instructions.

## Verification and next step

Only the isolated demo is exercised before approval. No application source, credentials, real sign-in, playback, or full test suites are touched. Browser appearance is an approximation; prototype timers do not prove live automation.

After approval, limit production verification to the affected corner/tint rendering, native input/accessibility/scroll, presentation handoff/reduced-motion, and discovery lifecycle/retry tests. Preserve existing account/device proof and shutdown/cancellation coverage. Verify actual composited native corner transparency and handoffs rather than treating `cacheDisplay` artifacts as screenshots of live glass.

## Observed demo checks

- Normal full flow reached the illustrative player without an extra completion click.
- Reduced-motion full flow traversed welcome, signing, library, authorizing, library-done, key, installing, pairing, finishing, ready and player. The record DOM instance remained identical and its computed animation was `none`.
- Simulated network interruption and permission return preserved the same record and `Bopify 4A7C9` device name. No routine retry button appeared in the scene. This verifies prototype state behavior, not real discovery recovery.
- At 360 px browser width, expanded registration help fit horizontally and scrolled vertically. A dummy Client ID submitted with Enter and progressed to the key view.
- The key field remained `type=password` with accessible name “Soloist key”, and no duplicate visible field label.
- The whole demo surface uses one rounded clip. Welcome/pairing/registration captures were inspected; no form-relative rectangular tint or bottom seam is present in the prototype.
- No application source changed and no app/package/Rust test suites ran. Only this local browser demo was exercised, and its dedicated headless browser was closed.

Captures: `build/onboarding-continuous-demo/{welcome-preview,pairing-preview,key-preview,compact-library,player-handoff}.png`. The interactive HTML is the reference for motion; still captures do not show the handoff. Native appearance, corner alpha, real Spotify results and operational recovery remain unverified until an approved implementation is built and checked.

## Implemented result — 2026-11-07

The approved design is implemented. Native verification supersedes the pre-approval limitations above: the full onboarding surface is clipped, its four outer corners are transparent, forms retain native secure entry and accessible purpose, and completion hands off automatically in the same panel without starting playback. The existing window controller owns the record's position and size during the fade; no competing matched-geometry transform remains.

The focused implementation run passed 78 tests in 9 related suites. A further two-test native run inspected the fade midpoint and verified the settled record anchor and unchanged idle playback. Full suites were not run. The signed arm64 Release build is at `build/continuous-onboarding-release-20261107/Build/Products/Release/Bopify.app`. See the implementation plan for evidence paths and limits: real Spotify account pairing/listening is not established by offline fixtures, and no existing player was relaunched.
