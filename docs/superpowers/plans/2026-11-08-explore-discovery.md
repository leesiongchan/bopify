# Explore Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Independent source/protocol tasks may be delegated under AGENTS.md.

**Goal:** Implement the approved discovery and recommendation-continuation mechanics while preserving the existing UI.

**Architecture:** The library owns signal collection, pure seed/ranking policies and cached anchor feeds. Domain requests carry bounded upcoming tracks; Soloist owns acknowledged local playback/queue operations. Existing account boundaries and metadata-only librespot remain intact.

**Tech Stack:** Swift 6, Observation, Swift Testing, URLSession WebSockets, SwiftUI/macOS 26; existing pinned native metadata bridge.

**Spec:** `docs/superpowers/specs/2026-11-08-explore-discovery.md`

## Global Constraints

- No visual redesign, new dependencies/services/permission types or undocumented playback commands. Bundle existing playback scopes into explicit library consent; older grants upgrade only on an explicit selection.
- Soloist is the only audio engine; never write recommendations into the manual queue or issue a queue-clear operation.
- Preserve previous uncommitted onboarding/regression changes in this worktree.
- Only related tests. No saved-credential reads, live playback mutations or automatic app replacement.
- No duplicate approval request: user already authorized the recommendation and implementation.

## Review Focus

- In-flight old-account data must never repopulate a cleared feed.
- Partial candidate failures must retain healthy candidates; auth/throttle failures must remain visible.
- Pagination and refresh must not reorder the current selection or repeat tracks already shown.
- New selections, same-song restarts and disconnects must stop stale queue writes.
- Queue rejection/timeouts must finish with an error and close the temporary socket.

## Task 1: Signals and pure discovery policy

Files: Domain `ListeningHistoryService.swift`; library `SpotifyLibraryClient.swift`, new `ExploreDiscovery.swift`; focused library tests.

Interfaces: add `TopItemTimeRange` and `topItems(_:timeRange:)`, preserving old conformers through a forwarding default. `ExploreDiscovery.seeds(recent:shortTermTracks:shortTermArtists:familiarTracks:liked:)` returns at most 12 real seeds. `rank(candidates:recentlyPlayed:excluding:preceding:)` returns stable deduplicated candidates; optional preceding tracks support artist diversity at append boundaries.

- [x] Write/observe RED for exact time-range query, old-method compatibility, source interleaving, deduplication, recent demotion and sparse/unknown artist handling.
- [x] Implement minimal policy/source changes and run only the new policy and affected source tests. Eleven Library tests and one Domain compatibility test pass; explicit existential dispatch also passes all three ranges.

## Task 2: Acknowledged recommendation continuation

Files: Domain `PlaybackEngine.swift`; playback `SoloistEngine.swift`, optional focused helper; focused engine/state tests. Root owns Domain request and preview support; protocol agent owns Soloist changes.

Interface: `PlayRequest.followingTrackURIs: [SpotifyURI] = []`. Validate at most 50 following tracks, track-only context, no offset/start position, before playback mutation. Deduplicate followers and exclude the selected track.

- [x] RED: selected play acknowledgement and fresh active state precede context replacement; synchronous rejection; timeout; superseding selection; auth/socket/occurrence change; invalid input causes zero mutation.
- [x] Implement an owned temporary local play socket with bounded acknowledgement waits and cleanup; require granular selection proof plus a fresh snapshot. Install the finite URI-list context in a managed background task through the existing verified-device Web API route. Keep existing ordinary loads unchanged; do not use local queue appends for recommendation contexts.
- [x] Run only affected Soloist tests and playback-model integration tests. The related set passed 88 tests; final parser/cancellation/continuation/shutdown subset passed after cleanup.
- [x] Pin the permission consumer: explicit/prepared library consent request the existing control scopes together; metadata-only grant validity and quiet launch remain unchanged. Test intent-only missing-scope upgrade and cancellation; wire the controller callback to that actor method. Thirty-four focused Auth tests passed, including client-change guards.

## Task 3: Feed orchestration

Files: `ExploreModel.swift`, `ExploreModelTests.swift`. Preserve all UI-facing property/method names.

Consume Task 1 helpers and Task 2 request. Each anchor feed stores order, selection, attempted seeds and cache time. Gather up to three candidate sources per batch, merge in source order, preserve successful candidates, and append new unique candidates near the end. Refresh only on reveal after TTL; seed change/hide/clear cancel stale work. Keep transient retry budgets bounded.

- [x] RED: multi-source initial feed, partial failure retention, cold account, auth/throttle stop, anchor caching, stable selection/append, cache expiry, stale-provider/identity races and retry bounds.
- [x] Implement orchestration and selected-track request with up to 20 following URIs.
- [x] Run only Explore tests and affected library source tests. Thirty-eight ExploreModel tests passed; the source/policy set passed 11 Library tests and one Domain compatibility test.

## Task 4: Integration and review

- [x] Update preview behavior for continuation without introducing a separate UI flow. Two focused tests reproduced three failures, then passed after selected-song and queue-order repair.
- [x] Review only task-related diffs and required consumers; repair findings with focused regression checks. Final independent review found no blocking issues.
- [x] Build the native app and run related app playback checks. Produce/verify a signed local test artifact without launching it. Sixteen native integration checks passed; final Release build and strict signature verification passed.
- [x] Record exact checks, actual provider limitations and artifact path. No commit may sweep earlier user work into this task.

## Progress

Implementation and focused verification are complete. Review findings were repaired: both event orders require explicit selection proof; repeated selections replace the automatic URI-list context; older grants upgrade only on an explicit selection; OAuth/client changes and paused playback cancel stale continuation. Removed final background writes to the shared query socket so cancellation cannot disconnect normal controls.

Artifact: `build/explore-discovery-test-20261108/Build/Products/Release/Bopify.app`, version 1.6.0, build 464. Final build and `codesign --verify --deep --strict` passed. No app was launched or replaced; no commit includes earlier user work.

Evidence: `/tmp/bopify-context-final-related.log` (88), `/tmp/bopify-context-last-checks.log` (final 4-test subset), `/tmp/bopify-playback-consent-final-green.log` (34), `/tmp/bopify-explore-discovery-final.log` (38), `/tmp/bopify-discovery-green.log` (11 Library + 1 Domain), `/tmp/bopify-explore-native-final.log` (16). Only affected suites were selected.

Live Spotify candidate retrieval, audio continuity and provider handling of existing manual queue entries remain unverified. The documented API confirms targeted URI-list playback but does not explicitly guarantee manual-queue preservation or atomic ordering with other Player endpoints; code issues no manual-queue additions/clears. The current running user app is the earlier adaptive-onboarding build. To test, quit that build, open the artifact, browse Explore and select a song; an older account grant may request playback permission once. Inspect the safe stage/status diagnostics if provider retrieval fails.
