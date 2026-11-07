# Soloist Default Playback Implementation Plan

> REQUIRED: use superpowers:executing-plans and test-driven-development inline.

**Goal:** Prefer saved-key Soloist by default and keep local playback independent of Web API throttling.
**Spec:** docs/superpowers/specs/2026-11-06-soloist-playback-design.md, Soloist default and rate-limit isolation.
**Architecture:** Local paired/owned readiness and controls separate from verified mixed-account data/assisted commands. Shared cooldown, bounded/spaced background proof, explicit session override unchanged. No dependency changes.

## Constraints and review focus

- No auth/account gate bypass for companion data or assisted loads; local controls operate only on owned paired child.
- No competing audio, no unsolicited autoplay, re-pair/socket changes invalidate mixed proof.
- Respect Retry-After across retries, no account-proof Web polling while inactive (established-account remote mirroring may refresh every 30 polls), cancel/join background work.
- Preserve root appearance work and existing desktop signing/installation checks; no credential access for tests.

### Task1: Default routing and local/data separation
- [x] Add failing saved-key default regression and local Core readiness/control despite throttled Web token; preserve explicit session override.
- [x] Make local pairing/adoption independent of HTTP, support inactive readiness, keep verification required for data/assisted commands, and perform background account/device proof only while advancing.
- [x] Update affected regression expectations to the explicitly changed local-control contract; run focused tests.

### Task2: Cooldown, feedback and final build
- [x] Add failing shared cooldown/429 tests; implement Retry-After gate across default API instances and bounded/spaced verification retries.
- [x] Show local Soloist ready with limited services rather than failed audio. Verify native UI/default selection, core/probe/app checks.
- [x] One fresh final review and one material fix pass, then signed Release build + actual install check. Record unverified live account/audio limits and hand over app.


## Execution record

Saved-key setup now selects Soloist even when the earlier enabled flag is false. Local launch/pairing/adoption, inactive readiness, controls and direct URI loads no longer call Web APIs or wait for optional service authorization. Explicit librespot override still lasts only for the current session. Setup shows Preparing Soloist during handoff. Connect Spotify features authorizes/retries only companion services; it does not stop the local player.

Web account/device proof runs separately during active playback with two samples spaced five seconds apart. Both local and fresh Web positions must advance. Companion data and Web-assisted offsets remain gated. Retry-After cooldown is shared across API/engine recreation; background retries use at least30 seconds and the server deadline. Established verified remote mirroring is exempt from the no-inactive-proof-polling rule and refreshes only every30 polls.

One fresh review returned two Important issues: OAuth replacement could retain old proof, and the correlation helper did not require Web progress. Both were reproduced RED then corrected in one pass. Proof is revoked/paused before user authorization; exact credential binding and a data generation guard protect cached services and results. Credential replacement during verification cannot initialize a companion under old proof. Stationary fresh Web observations do not verify. No second review.

Verification: shared469 tests pass; probe36 pass; final native setup/rendering8 tests pass. Full app280 tests retains24 existing window-focus issues; no unrelated tests changed or skipped. Native cached screenshots inspected for new default copy and sizing; AppKit/glass button compositing remains incomplete in cached captures as before. Signed Release build succeeds and the actual-app fresh install check validates Spotify's signature/version1.3.10.51, executable launch, cache reuse and cleanup with hardened runtime enabled and App Sandbox absent. No actual key/account or user audio was accessed during tests.

Artifact: `build/soloist-default-test-20261107/Build/Products/Release/Bopify.app`. Interactive Spotify pairing/audio and real-account companion recovery remain acceptance checks, not claimed passing. Root appearance work preserved; no merge/push/release.

Final native Clippy/tests also pass (92 core,93 Connect,11 playback plus doctests; existing opt-in live tests unrun). No native code changed.
