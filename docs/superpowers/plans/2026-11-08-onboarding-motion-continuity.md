# Onboarding Motion Continuity Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for the coordinated native rendering work. Independent scale and presentation lifecycle changes may be delegated under AGENTS.md. Preserve all prior uncommitted work.

**Goal:** Keep setup's compact vinyl and carry one visible record naturally into the native player.

**Architecture:** Preserve the completion-settlement gate. Precompute the final player geometry, drive the handoff from one progress value, and finish via its actual animation completion. Reuse the existing native record rendering and existing animation facilities; no dependencies or account changes.

**Tech Stack:** SwiftUI, AppKit, Swift Testing, Xcode native fixtures.

**Spec:** `docs/superpowers/specs/2026-11-08-onboarding-motion-continuity-proposal.md`, now approved.

## Global Constraints

- Keep the approved Aurora, glass, artwork, permission list and main player design.
- Keep Soloist as the only audio engine; no live playback, credential access, app replacement or auto-launch.
- Run only related checks. Preserve unrelated work; do not commit the whole dirty tree.
- Native capture must target isolated fixture windows only.

## Review Focus

- Direct playback setup and fast ready paths must not restore the larger hero.
- Screen clamps must be resolved before starting the shared record's path.
- Hiding, Reduce Motion, readiness loss and stale animation completions must not strand setup or finish a newer session.
- Incoming player controls must not become interactive while their transition is incomplete.
- The final native frame commit must not change the settled record's screen position.

## Tasks and ledger

- [x] **Compact sizing:** library→playback→completion and direct playback share the compact cap. RED: 18 expected issues; GREEN: 16 layout tests. Logs `/tmp/bopify-compact-motion-{red,green}.log`.
- [x] **Completion lifecycle:** visible handoffs use UUID-guarded `handoffSettled(for:)`; hidden/reduced/no-view completion remains bounded. RED: old 650 ms timer removed a visible handoff; GREEN: 20 presentation tests. Logs `/tmp/bopify-handoff-lifecycle-{red,green}.log`.
- [x] **Native geometry and visual transfer:** RED reproduced attention changes retargeting the record. Controller now precomputes clamped geometry, stages final player layout hidden, and drives all layers from one non-bouncing progress. The pocket recedes before the exposed disc transfers. Its drawing is reused at measured bounds, then material changes only after arrival. Actual animation completion commits the native bounds and signals the presenter. Log `/tmp/bopify-shared-record-red.log`.
- [x] **Integration and capture:** final 84 tests in seven related suites passed, including six native cases. `/tmp/bopify-shared-record-final-tests.log`. Native screenshots inspected: key entry `build/test-artifacts/onboarding-composited/772CB22D-5BAF-4590-9442-6AAADC925D42`; compact completion/handoff/player `build/test-artifacts/onboarding-composited/6108DF2E-E58A-40A7-9C55-E25028B9F4D8`. Four initial captured native cases passed in `/tmp/bopify-shared-record-native.log`. Final native cases also verify actual menu-bar dismissal and the Reduce Motion coordinator. Native fixtures omit some production localization/Metal resources, so captures establish layout and transition geometry rather than full production resource fidelity.
- [x] **Delivery:** Release 1.6.0 (468) built successfully and passed `codesign --verify --deep --strict`: `build/shared-record-test-20261108/Build/Products/Release/Bopify.app`. Log `/tmp/bopify-shared-record-release.log`. No auto-launch, app replacement, live account or playback command. Final diff check passed.

## Final review and interruption repairs

Read-only review found four lifecycle issues in the initial implementation. Each was reproduced before repair: queued attention starting a new transition while hiding; an obsolete queued compact mode surviving a later expanded request; Reduce Motion finishing the presenter before native geometry; actual menu dismissal bypassing the controller's settling path. Logs: `/tmp/bopify-transfer-interruption-red.log` and `/tmp/bopify-native-transfer-interruption-red.log`. Native tests wait for the actual transfer to mount, rather than only its preceding model phase.

Hiding now drops queued attention and settles the native bounds first. Every request replaces or clears the queue. Actual menu dismissal routes through controller hiding. The shared `AppEnvironment.updateOnboardingReadiness(reduceMotion:)` boundary settles native geometry before updating the presenter, covering the real view callback without changing the user's system accessibility settings. Review confirmed all four repairs and no further blockers. Timeout messages in the final combined log belong to deliberate missing-callback regressions; captured native handoffs use actual completion.

## Implementation rulings

- No new design approval is needed: the user explicitly approved the carry-record demo.
- A transfer rendering may reuse the same record drawing at captured geometry; preserving perceptual identity matters, not SwiftUI struct identity. Only one full-opacity disc may be visible at once.
- Keep a brief pocket-recede phase before the disc moves so the exposed disc can transfer without popping in front of its sleeve.
- Do not commit until explicitly requested; this worktree contains many earlier uncommitted changes.
