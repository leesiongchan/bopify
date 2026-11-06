# Soloist In-App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Let the user enable and test Soloist entirely from Bopify, including key entry, automatic installation, Spotify pairing and observed playback, with data-only librespot support and an explicit librespot option.

**Architecture:** Keep the stable PlayerModel/recovery coordinator. A Soloist managed engine owns its process/socket, normalizes authoritative events and composes a service-only librespot session. App setup reuses existing OAuth actors/Client ID, validates immutable account IDs and observes owned Soloist playback before allowing cross-provider data or targeted commands. Native setup exposes progress, pairing, retry, cancel and fallback.

**Tech Stack:** Existing Swift 6/SwiftUI/AppKit, Foundation WebSocket/Process, Security Keychain, pinned Rust/librespot, existing SoloistInstaller. No new remote dependencies.

**Spec:** `docs/superpowers/specs/2026-11-06-soloist-playback-design.md`, including 2026-11-07 continuation authorization.

## Global Constraints

- macOS 26, Apple Silicon; preserve root checkout appearance work.
- Never mix accounts or activate two audio engines. Await old teardown before switching; socket loss alone does not prove silence.
- Use managed signed binaries and private persistent session/cache directories. Never log keys, tokens, content or raw provider errors.
- Preserve user grants; request extra playback scopes only from explicit setup. Never prompt on launch.
- Queue occurrence selection unavailable on Soloist: show that limitation; do not fabricate targets or reconstruct queues automatically.
- Live account/coexistence/audio behavior remains unverified until exercised with the user's account; make setup failures actionable.

## Review Focus

1. Cancellation, sign-out or quit during install/pairing must join owned work and prevent later activation.
2. A remote owner or live-but-disconnected Soloist must never trigger automatic competing audio.
3. Wrong account, ambiguous devices, stale observations and re-pairing must disable mixed data/control.
4. Expired builds and invalid keys must offer retry/librespot without erasing an unrelated grant.
5. Unsupported queue actions and service failures must preserve working Soloist audio.

### Task 1: Data-only services and secure configuration

Files: Rust `engine.rs`/`recovery.rs`; Swift `LibrespotEngine.swift`, new `LibrespotServices.swift`; BopifyAuth new `SoloistKeyStore.swift`; existing logout-intent/auth files and tests.

Interfaces: optional `servicesOnly` engine creation flag (default false); native optional Spirc with playback commands rejected when absent. `LibrespotServices` exposes only radio/lyrics/artist and shutdown. Dedicated `SoloistKeyStoring` saves/loads/clears key; `.soloist` cleanup namespace includes owned pairing files. `LibraryAuthorization.authorize(additionalScopes:)` retains existing library scopes and adds read/modify playback only on request.

- [ ] Add failing tests for services-only creation options/command rejection, key validation/storage boundaries and incremental consent.
- [ ] Run targeted tests, observe failure, implement the mode before Player/Mixer/Spirc construction and separate Swift service facade.
- [ ] Verify native checks and shared auth tests; rebuild framework/header as required. Commit focused changes.

### Task 2: Owned process, Web API and wire state

Files: new shared playback `SoloistProcess.swift`, `SoloistWebAPI.swift`, `SoloistState.swift`; PlaybackTests.

Interfaces: process launch holds exclusive directory lock and owns termination/join; dynamic loopback endpoint only. Typed state decodes auth, playback, metadata, actions and duplicate queue occurrences into domain events. Web API exposes profile account IDs, fresh devices/playback and explicitly targeted play/transfer with fixed errors/Retry-After. Bound frames, HTTP bodies, subprocess output and deadlines; no raw diagnostics.

- [ ] Add failing fixtures for wrong endpoints, malformed frames, inactive snapshots, duplicate tracks, permissions/capabilities, stale position and wrong account/device correlation.
- [ ] Implement using verified official schemas and existing probe ownership principles, preserve data across restart.
- [ ] Run playback tests, verify cancellation/owned-process cleanup and commit.

### Task 3: Managed Soloist playback and provider selection

Files: new `SoloistEngine.swift`, app `SoloistPlaybackController.swift`; domain events/PlayerModel only for intentional capabilities/idle updates; tests.

Interfaces: `SoloistEngine: ManagedPlaybackEngine` implements supported socket controls, explicit targeted assisted loads, observation-based readiness and service composition. Reconnect to the live child on socket loss; fail visibly while retaining ownership rather than silently launching librespot. A provider controller chooses ready Soloist on startup and explicit retry, allows librespot selection, and exposes fixed setup status. Initial correlation gates data-only service creation; reauthentication invalidates association.

- [ ] Add failing state/control routing, lifetime and setup tests, including no promotion after cancellation and no guessed queue selection.
- [ ] Implement sequential outgoing teardown and incoming creation, epoch-safe state and service errors isolated from audio.
- [ ] Run meaningful targeted suites and commit. Keep actual live behavior explicitly unverified.

### Task 4: Native setup, lifecycle and testable build

Files: new `SoloistSetupView.swift`/window controller, AppEnvironment, status menu, localizations, app tests; existing player/queue feedback as needed.

Interfaces: status menu `Playback Engine…` opens native window with secure key field, official key link, automatic install progress, pairing instructions, current engine, retry/cancel and explicit librespot action. Reuse current library client/grants and request added consent in-app. Sign-out records cleanup intent before clearing Soloist key/session; quit cancels setup and joins owned child without deleting grants.

- [ ] Add failing app model tests for key/setup progress, cancellation/sign-out generations and engine selection; implement native flow and localized copy.
- [ ] Run native checks, framework rebuild, all package/app tests and focused accessibility/UI verification with screenshots where available.
- [ ] Request one independent review of the integration delta; reproduce/fix material findings in one pass, record deferred minors.
- [ ] Build and signature-verify a fresh runnable app. Report exact tests and remaining live observations; no Terminal prerequisite for the user.
