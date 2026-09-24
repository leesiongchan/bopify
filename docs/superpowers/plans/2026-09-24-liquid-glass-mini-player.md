# Liquid Glass Mini-Player Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Bopify's static transient panel with the approved circular player, real Up Next carousel, radial seeking, compact mode, and persistent native window.

**Architecture:** Preserve local librespot playback and the engine-event → `PlayerModel` → SwiftUI flow. Add authoritative queue snapshots and safe occurrence selection below the Swift boundary, keep presentation/animation state above it, and use one shared artwork loader. Genuine Spotify favorites are an independent integration covered by the [companion plan](2026-09-24-spotify-favorites.md); both plans are required for full brief completion.

**Tech Stack:** Swift 6, SwiftUI/Observation, AppKit, Foundation/Core Image, Swift Testing, Rust/Tokio, librespot pinned at `939dc5ee9d833e1980f9495241219d9d4868a061`, existing cbindgen C ABI. macOS 14 minimum; native Liquid Glass on macOS 26+ with the existing material fallback.

**Spec:** [Approved replacement design](../specs/2026-09-24-liquid-glass-mini-player-design.md).

**Status:** Ready for plan review, not execution approval. No implementation or live Spotify validation has occurred in this planning session.

## Global Constraints

- “The deliverable contains only the native player UI.” All artwork remains front-facing and circular.
- “Approved scope: the list is **Up Next**, representing the active playback queue.” Saved-playlist browsing is outside scope.
- “Favorite means Spotify saved-track state, consistent with `PRD.md`, not a local-only heart toggle.”
- Expanded: **410 × 560 pt**, widths **390–430 pt**; compact: **380 × 88 pt**, widths **340–420 pt**.
- Disc **310 pt**; central art **204 pt**; neighbors **80 pt**; queue row art **48 pt**.
- Canvas `#08090D`; transitions **720 ms** for tracks, **550 ms** for queue, **160 ms** for microinteractions.
- “Do not duplicate the playback clock, current-track selection, or queue order in presentation code.”
- “The window remains visible after outside clicks and uses normal window ordering by default.” Keep on Top is opt-in.
- “A visual-only subset remains incomplete against the supplied brief.”
- Preserve existing uncommitted work as the execution baseline. Never reset, stash, or commit unrelated user changes silently.
- No new third-party library, telemetry, remote playback path, or broad refactor. Existing build floors and lifecycle contracts remain intact.
- Use existing local logging at commands, state transitions, and failures; do not log credentials or public listening-history identifiers.

## Review Focus

1. Repeated identical songs and stale clicks must select the intended occurrence or reject without changing playback (Tasks 1–3).
2. Rapid navigation, external changes, and delayed metadata must converge on the last confirmed track without stale thumbnails or title (Tasks 2, 3, 5, 7).
3. Scrubbing across twelve o'clock, pausing, and losing the active device must not produce a backwards jump, false clock advance, or unintended resume (Tasks 3, 6).
4. Missing/bright art, long text, 390 pt width, and accessibility settings must keep essential actions legible and reachable (Tasks 4–8).
5. Window movement, collapse, display removal, and focused text entry must preserve the window and avoid stealing input (Task 8).

## Changes requiring explicit approval in this plan

The spec did not authorize a dependency change. **This plan proposes a small local patch against the exact pinned librespot revision**, because its public API cannot select an existing queued occurrence. Keep the upstream revision; prepare a separate ignored checkout, apply a committed patch, and resolve every librespot crate from that tree. Do not modify the Cargo cache or publish a fork.

Selection uses `(snapshot generation, raw upcoming index)`, not URI or upstream UID. UID is not unique across repeated contexts, and upstream's queue revision hashes URIs, so it cannot detect duplicate-only changes. Validate the locator atomically on the Spirc event task, then promote the selected occurrence once. This is a proposed contract, not an API that already exists.

The initial patch must prove exact selection, history/context preservation, one audio load, and stale-command rejection before the rest of the feature relies on it. If those tests expose a larger dependency rewrite, stop that task and present the evidence; do not substitute context reloads or repeated Next commands. Independent visual work can continue against honest fixtures, but the full feature remains incomplete.

## File map and ownership

Paths below are existing files unless marked **new**. All code fragments describe proposed implementation.

| Files | Responsibility |
| --- | --- |
| **new** `scripts/prepare-librespot.sh`, **new** `rust/patches/librespot-queue-selection.patch`, `rust/Cargo.toml`, `rust/Cargo.lock`, `.gitignore`, `scripts/build-rust.sh`, `README.md` | Reproducible pinned source preparation and its focused patch. |
| `rust/crates/bopify-core/src/{engine,event,ffi,error}.rs`, **new** `queue.rs`, `lib.rs` | Queue forwarding, metadata hydration, command delivery, nonfatal rejection. |
| `artifacts/include/bopify_core.h` | Generated through `scripts/gen-header.sh`; never hand-edit or force-add ignored artifacts. |
| **new** `Packages/BopifyCore/Sources/BopifyDomain/PlaybackQueue.swift`, existing `{PlaybackState,PlaybackEvent,PlaybackEngine}.swift` | Queue value types, events, and commands. |
| `Packages/BopifyCore/Sources/BopifyPlayback/{PlayerModel,LibrespotEngine,StubPlaybackEngine}.swift` | Ordered command submission and observed state. |
| **new** `Packages/BopifyCore/Sources/BopifyPlayback/PlayerPresentation.swift` | Testable mode/escape and carousel-continuity decisions; no AppKit or independent playback state. |
| **new** `Bopify/Bopify/Views/ArtworkStore.swift` | Cached image loading and palette extraction. |
| `Bopify/Bopify/Views/{PlayerSurface,ArtworkView,MiniPlayerView,TransportControls,SignedOutView,PlayerPreviews}.swift` | Existing surface, shared art primitive, shell, controls, auth/empty states, previews. |
| **new** `Bopify/Bopify/Views/{ArtworkCarouselView,RadialProgressView,CompactPlayerView,QueueView}.swift` | The four distinct new interactive view responsibilities. |
| `Bopify/Bopify/MenuBar/{StatusPanel,StatusItemController}.swift`, `AppEnvironment.swift`, `BopifyApp.swift`, `Localizable.xcstrings` | Window ownership, shared presentation, wiring and visible copy. |
| Existing `DomainTests`/`PlaybackTests`, **new** `PlaybackQueueTests.swift`/`PlayerPresentationTests.swift` | Boundary and state regressions. SwiftUI is verified through native previews and interaction checks. |

The app uses a synchronized source folder: ordinary new SwiftUI files do not need manual project source entries. Do not introduce an app test target solely to test fixed view constants.

## Execution baseline

At execution time, load using-git-worktrees and preserve the dirty baseline before choosing isolation. A clean worktree from HEAD alone omits the current UI/model changes; copy their patch and the two untracked view files into isolation, or preserve the current checkout if it is already isolated. Record baseline `git status --short` and `git diff --stat`. Begin with the existing test/build baseline before making changes; retain pre-existing failures as explicit evidence.

Use these checks where their inputs change:

```sh
cargo test --manifest-path rust/Cargo.toml
./scripts/build-rust.sh
swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-mini-player-tests
xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-mini-player-build build
git diff --check
```

`scripts/build-rust.sh` rebuilds only generated artifacts and regenerates the header. Run it after Rust/ABI changes and before Swift consumes the changed symbols. The Swift suite contains an invalid-token engine creation test that may use the network; distinguish its environmental failure from an assertion failure. Request sandbox escalation for blocked required commands rather than weakening tests. On this Nix machine, retry a missing CLI through comma.

## Task 1: Prove and implement exact queue selection in the pinned adapter

**Files:** source-preparation files from the map; patch targets upstream `playback/src/player.rs`, `connect/src/{spirc,state}.rs`, and `connect/src/state/tracks.rs` inside the prepared checkout. Tests for our new behavior live in the patch alongside the altered state/command code.

**Interfaces:** Consume pinned `ProvidedTrack`, `ConnectState::next_track`, `SpircCommand`, and `PlayerEvent::SetQueue`. Produce these *new* selection types/API:

```rust
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct QueueSelection {
    pub generation: u64,
    pub raw_next_index: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QueueSelectionError { Stale, OutOfRange, Unavailable }

// New Spirc method: channel closure remains librespot_core::Error.
pub fn select_queue_entry(
    &self,
    selection: QueueSelection,
) -> Result<tokio::sync::oneshot::Receiver<Result<(), QueueSelectionError>>, librespot_core::Error>;
```

- [ ] **Prepare the pinned checkout reproducibly.** `scripts/prepare-librespot.sh` creates `.build/librespot-939dc5e` only when absent, checks out the full revision, verifies `git rev-parse HEAD`, then applies the tracked patch strictly. If a prepared tree is already patched, accept only a verified reverse-apply check plus an unchanged base revision; reject unrelated edits. Never reset or delete an unexpected checkout. Use path dependencies for the five currently declared librespot dependencies; upstream's workspace then resolves its remaining crates from the same tree. Exclude `.build` from the root Rust workspace if Cargo's workspace discovery requires it. Add preparation to the documented build entry point; keep Cargo.lock changes limited to source identity.

```sh
git -C .build/librespot-939dc5e rev-parse HEAD
git -C .build/librespot-939dc5e apply --check ../../rust/patches/librespot-queue-selection.patch
cargo tree --manifest-path rust/Cargo.toml -d
```

The replacement workspace dependency paths are relative to `rust/Cargo.toml`:

```toml
[workspace.dependencies]
librespot-core = { path = "../.build/librespot-939dc5e/core" }
librespot-playback = { path = "../.build/librespot-939dc5e/playback" }
librespot-connect = { path = "../.build/librespot-939dc5e/connect" }
librespot-metadata = { path = "../.build/librespot-939dc5e/metadata" }
librespot-oauth = { path = "../.build/librespot-939dc5e/oauth" }
```

Keep the exact source URL/revision and preparation instructions beside these entries. Re-run preparation before direct Cargo commands on a fresh checkout. Once the patch passes its tests, derive the committed patch from the prepared tree's `git diff --binary`; the preparation script compares that full diff with the tracked patch, in addition to checking its base revision, so unrelated checkout modifications are rejected.

- [ ] **Write failing tests for the new selection locator and promotion helper.** Proposed pure validator `validate_selection(current_generation: u64, selection: QueueSelection, next_len: usize) -> Result<usize, QueueSelectionError>`:

```rust
#[test]
fn stale_selection_never_becomes_an_index() {
    let target = QueueSelection { generation: 8, raw_next_index: 1 };
    assert_eq!(validate_selection(9, target, 3), Err(QueueSelectionError::Stale));
    let current = QueueSelection { generation: 9, raw_next_index: 1 };
    assert_eq!(validate_selection(9, current, 3), Ok(1));
    assert_eq!(validate_selection(9, current, 1), Err(QueueSelectionError::OutOfRange));
}
```

Add state fixtures using `ProvidedTrack { uri, uid, ..Default::default() }`: two same-URI entries with distinguishable metadata must select the second instance and keep the exact suffix. Include identical UIDs from a repeated context. Snapshot all relevant state before stale/out-of-range rejection and assert equality afterward. Run patched crate tests and observe failure before implementing.

- [ ] **Add authoritative snapshots and atomic selection.** Extend the exported snapshot with a monotonic generation, upstream UID/provider and raw indices before delimiter filtering. Maintain structural-generation changes on every mutation path, including normal skip, end-of-track, shuffle, remote replacement, and duplicate-only reorder. Factor the existing next-track promotion rules into one bulk-prefix operation that preserves queued/context/autoplay history, delimiters, context indices, shuffle and repeat semantics, and refills once. Validate playability before mutation. Dispatch one `player.load` and publish the resulting snapshot; resolve the acknowledgement after state application. Do not interpret that acknowledgement as successful audio playback.

```rust
fn validate_selection(
    current_generation: u64,
    selection: QueueSelection,
    next_len: usize,
) -> Result<usize, QueueSelectionError> {
    if selection.generation != current_generation {
        return Err(QueueSelectionError::Stale);
    }
    let index = selection.raw_next_index as usize;
    if index >= next_len { return Err(QueueSelectionError::OutOfRange); }
    Ok(index)
}
```

Keep stable visual keys separate from command locators. Add an opaque occurrence key to each published entry and carry keys through known local moves; reconcile unchanged unique entries conservatively. Ambiguous external duplicate sequences receive new keys, which the Swift direction classifier treats as a fade. Never use URI, raw UID, or list index alone as a permanent visual identity.

- [ ] **Verify the full owned behavior.** Add tests for single audio-load count; manual queue/context/autoplay/delimiter handling; repeat-track explicit skip behavior; duplicate-only invalidation; rapid stale clicks; and snapshot publication following next/previous/end-of-track. Run `cargo test --manifest-path .build/librespot-939dc5e/connect/Cargo.toml`, existing adapter tests, and source-identity inspection. Inspect the actual patch before integrating. Live confirmation is required in Task 9.
- [ ] **Commit the focused dependency patch and build wiring** after its tests pass, excluding generated checkout contents. Suggested subject: `Support exact occurrence selection in the pinned playback adapter`.

## Task 2: Carry queue, metadata, shuffle and repeat across the existing boundary

**Files:** `rust/crates/bopify-core/src/{queue,engine,event,ffi,lib}.rs`; new `PlaybackQueue.swift`; existing domain event/state/engine files; `LibrespotEngine.swift`, `StubPlaybackEngine.swift`; `PlaybackQueueTests.swift`, `PlaybackEventTests.swift`, existing FFI tests.

**Interfaces:** Task 1's snapshot/selection contract becomes the following Swift contract. Public structs include public memberwise initializers with the listed labels; those initializers are required for app and test callers.

```swift
public enum RepeatMode: String, Codable, Hashable, Sendable { case off, context, track }
public struct QueueTarget: Hashable, Sendable {
    public let generation: UInt64
    public let rawNextIndex: UInt32
}
public struct QueueEntry: Hashable, Sendable, Identifiable {
    public let id: String                 // visual occurrence key
    public let uri: SpotifyURI?           // nil for a non-playable item
    public let target: QueueTarget?       // nil for current/history/unavailable
    public var track: Track?
    public var metadataFailed: Bool
}
public struct PlaybackQueue: Hashable, Sendable {
    public let generation: UInt64
    public var previous: [QueueEntry]
    public var current: QueueEntry?
    public var next: [QueueEntry]
}
// Add to PlaybackEngine; implement in both real and stub engines:
func selectQueueEntry(_ target: QueueTarget) async throws
func setShuffle(_ enabled: Bool) async throws
func setRepeat(_ mode: RepeatMode) async throws
// Add PlaybackEvent cases:
// queueChanged(PlaybackQueue)
// queueMetadata(generation: UInt64, entryID: String, track: Track?)
// shuffleChanged(Bool), repeatChanged(RepeatMode)
// commandRejected(String) — fixed local reason codes, no provider payload
```

- [ ] **Pin wire formats with failing Rust serialization and Swift decoding tests.** Use this exact fixture; all entry fields are present, `track` is not sent in a structural snapshot:

```json
{"type":"queueChanged","generation":12,"previous":[],"current":null,"next":[{"id":"a","uri":"spotify:track:same","rawNextIndex":0},{"id":"b","uri":"spotify:track:same","rawNextIndex":1}]}
```

```swift
@Test func duplicateURIsKeepDistinctTargets() throws {
    let data = Data(#"{"type":"queueChanged","generation":12,"previous":[],"current":null,"next":[{"id":"a","uri":"spotify:track:same","rawNextIndex":0},{"id":"b","uri":"spotify:track:same","rawNextIndex":1}]}"#.utf8)
    guard case let .queueChanged(queue) = try JSONDecoder().decode(PlaybackEvent.self, from: data) else {
        Issue.record("expected queueChanged"); return
    }
    #expect(queue.next[0].id != queue.next[1].id)
    #expect(queue.next[1].target == QueueTarget(generation: 12, rawNextIndex: 1))
}
```

Also pin `shuffleChanged` with `enabled: Bool`, `repeatChanged` with `mode: String`, `commandRejected` with `reason: String`, and `queueMetadata` with generation/entryID plus nullable nested `track` using the existing trackChanged field names. Reject unknown repeat values and duplicate visual IDs; preserve an unsupported entry as unavailable instead of discarding the whole queue. Run `cargo test` and `swift test --filter PlaybackEventTests` to confirm red.

- [ ] **Translate structural events immediately; hydrate separately.** Clone the current session before passing it to `Spirc::new`, enable queue events, and put queue-specific forwarding in `queue.rs`. Do not await network metadata in the transport event drain. Use one bounded worker with at most four metadata lookups in flight, a session-lifetime cache capped at 128 tracks, and generation-tagged results. Fetch current/nearest neighbors first, then remaining visible queue. Cancellation/generation changes stop obsolete work. `AudioItem::get_file` is available at the pin; an unavailable/unsupported item becomes a row-level unavailable state, not a terminal playback error. Map titles/artists/duration/covers through the same conversion used for current-track metadata.

- [ ] **Add narrow C commands and asynchronous rejection forwarding.** Proposed declarations, generated from Rust:

```c
int32_t bopify_select_queue(BopifyEngine *handle, uint64_t generation, uint32_t raw_next_index);
int32_t bopify_set_shuffle(BopifyEngine *handle, bool enabled);
int32_t bopify_set_repeat(BopifyEngine *handle, uint8_t mode); /* 0 off, 1 context, 2 track */
```

Immediate return still means enqueued. The Rust runtime awaits Task 1's acknowledgement and emits fixed `staleQueue`, `unavailable`, or `rejected` reasons without poisoning the playback phase. Channel closure maps to existing session loss. Repeat commands set both upstream context/track flags consistently; observed events determine UI state. Preserve all pointer/null/destroy guards and `@concurrent` Swift FFI entry points.

- [ ] **Verify boundary lifecycle and malformed data.** Extend destroyed/null-handle tests to every new command; reject invalid repeat bytes. Test metadata arriving after replacement, malformed URI, missing artwork, lookup failure, and snapshot ordering without exercising Spotify's network internals. Rebuild the Rust artifact/header, then run DomainTests and PlaybackTests.
- [ ] **Commit** the domain/adapter boundary together. Suggested subject: `Expose observed queue and playback modes to Swift`.

## Task 3: Add commands and state reconciliation to PlayerModel

**Files:** `PlayerModel.swift`, `PlaybackState.swift`, `StubPlaybackEngine.swift`, `PlayerModelTests.swift`.

**Interfaces:** Extend state with `queue: PlaybackQueue?`, `shuffleEnabled: Bool`, `repeatMode: RepeatMode`, `commandNotice: String?`. Add model methods `seek(to: Int64)`, `seek(by: Int64)`, `selectQueueEntry(_ target: QueueTarget)`, `setShuffle(_ enabled: Bool)`, `setRepeat(_ mode: RepeatMode)`, `setVolume(_ value: Double)`.

- [ ] **Write failing tests for observed-only state and stale metadata.** Retain the existing test fixture helper and expand StubPlaybackEngine command recording for the proposed methods:

```swift
@Test func seekIsClampedWithoutPretendingItSucceeded() async {
    let engine = StubPlaybackEngine()
    let model = PlayerModel(engine: engine)
    model.start()
    defer { model.stop() }
    await settle(model, engine, [.trackChanged(makeTrack()), .paused(positionMs: 20_000)])
    model.seek(to: 900_000)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(engine.recordedCommands.contains("seek:240000"))
    #expect(model.state.positionMs == 20_000)
    #expect(model.state.phase == .paused)
}
```

Add generation-12 snapshot → generation-13 replacement → generation-12 metadata and assert generation-13 entries are unchanged. Test shuffle/repeat commands leave observed values unchanged until events arrive. Run `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-mini-player-tests --filter PlayerModelTests`.

- [ ] **Implement guarded commands and event folding.** Serialize command submission using an observed-independent task chain so fast clicks keep order; do not wait for audio completion before allowing the next enqueue. Clamp seeking to current duration, use `displayPositionMs(at:)` for relative seek, and reject controls when inactive/non-seekable. Queue selection must match the current generation before enqueue; the adapter validates again atomically. Preserve existing event-authoritative position and phase. Apply metadata only to a matching generation and entry ID, update all matching cached instances deliberately, and never let queue metadata overwrite confirmed current-track playback metadata. Nonfatal rejection updates localized notice copy, not `.error` playback phase.

```swift
public func seek(to milliseconds: Int64) {
    guard state.isActiveDevice, state.canSeek else { return }
    let target = min(max(0, milliseconds), max(0, state.durationMs))
    enqueue { [engine] in try await engine.seek(to: target) }
}
```

`enqueue(_ operation: @escaping @Sendable () async throws -> Void)` is a new private helper: await the previous command task, check cancellation, execute, and log a sanitized command failure. `stop()` cancels pending commands and the consumer; cancelled tasks must not start more commands.

- [ ] **Verify rapid next/previous ordering, device loss, and nonfatal rejection.** Assert recorded command order; stale metadata cannot resurrect a removed row; inactive seek is ignored; rejection does not pause a playing track; pausing freezes interpolated position. Run the entire PlaybackTests suite.
- [ ] **Commit** with subject `Reconcile queue commands and seeking with observed playback`.

## Task 4: Build the shared artwork pipeline and dark content surface

**Files:** new app `ArtworkStore.swift`; existing `PlayerSurface.swift`, `ArtworkView.swift`, `PlayerPreviews.swift` and callers in `MiniPlayerView.swift`/`SignedOutView.swift`.

**Interfaces:** `@MainActor @Observable final class ArtworkStore` exposes `images: [URL: NSImage]`, `palettes: [URL: ArtworkPalette]`, `func load(_ url: URL) async`, `func clear()`. `ArtworkPalette` stores `primary: Color` and `secondary: Color` for upper and edge glow. `ArtworkView(image: Image?, diameter: CGFloat)` remains a crisp, circular primitive; decorative disc rendering moves to the carousel.

- [ ] **Create native preview fixtures and capture the old baseline.** Existing previews already cover long text/loading/error/idle. Add fixtures for bright, floral-color, abstract-color and tropical-color artwork using local test artwork with known provenance. Preview-only generated patterns must be labeled samples and never substituted for live missing art. Render 390/410/430 pt and a no-image case.
- [ ] **Implement one cached load per artwork URL and one palette calculation per image.** Use URLSession and native image decoding; no new image package. Bound completed image cache to the current queue plus a small recent set, coalesce duplicate requests, and cancel view-owned work on changes. Do not attach a Spotify bearer token to artwork requests. Work from decoded/downsampled images, use Core Image's `CIFilter.areaAverage()` on upper/lower regions, then restrain brightness/saturation for the glow. Native filter documentation is linked below; no custom clustering algorithm is needed.

```swift
let filter = CIFilter.areaAverage()
filter.inputImage = inputImage
filter.extent = inputImage.extent
// Render the one-pixel output once through a reused CIContext.
```

Check HTTP status, image decoding failure and cancellation; retain a neutral fallback without retry loops. Invalid metadata URLs produce missing art. Fetching must not block the main thread. Keep NSImage/SwiftUI publication on MainActor and avoid unsafe Sendable assertions.

- [ ] **Replace the surface composition.** Remove fixed 360 × 460 geometry from the surface; the shell/window owns size. Use an opaque near-black base and localized upper radial gradients from the cached palette. Keep transport area dark. Apply a dark appearance within the canvas, keep system chrome native, and retain reduced-transparency/high-contrast fallbacks. The same surface palette supplies expanded and queue modes. Use native regular glass only for functional regions and fallback materials below macOS 26.

```swift
Color(red: 8.0 / 255, green: 9.0 / 255, blue: 13.0 / 255)
    .overlay(alignment: .top) {
        RadialGradient(colors: [palette.primary.opacity(0.32), .clear],
                       center: .topLeading, startRadius: 0, endRadius: 340)
    }
```

Here `palette` is the selected `ArtworkPalette`; a neutral palette is used until the current artwork resolves. Ignore a finished request for a different selected URL when choosing the current palette.

- [ ] **Verify visually and build.** Native captures must show a black lower region in both appearances, circular unblurred artwork, no white fallback panel, and readable missing-art/error/auth states. Verify slow/failed artwork with a local URLSession stub or disconnected preview session, and confirm cached track return causes no new decode. No unit tests that merely restate pixel constants.
- [ ] **Commit** with subject `Restore the dark artwork-led player composition`.

## Task 5: Implement carousel continuity and curved track transitions

**Files:** new `PlayerPresentation.swift`, new `ArtworkCarouselView.swift`; modify `ArtworkView.swift`, `MiniPlayerView.swift`, `PlayerPreviews.swift`; new `PlayerPresentationTests.swift`.

**Interfaces:** `PlayerPresentation` owns `mode: PlayerMode`, `keepOnTop: Bool`, `setMode(_:)`, `dismissQueue() -> Bool`. `PlayerMode: String, Codable` has expanded/compact/queue. New pure `CarouselDirection` has next/previous/fade; `carouselDirection(old: PlaybackQueue?, new: PlaybackQueue) -> CarouselDirection` uses occurrence keys and confirmed queue moves, not URI equality. SwiftUI animation values remain in ArtworkCarouselView.

- [ ] **Write the direction tests before animation code.** Add public initializers from Task 2 to construct simple queue fixtures; the local helper is defined in the test:

```swift
func entry(_ id: String) -> QueueEntry {
    QueueEntry(id: id, uri: SpotifyURI("spotify:track:same"), target: nil,
               track: nil, metadataFailed: false)
}
@Test func confirmedOccurrenceMovementDefinesDirection() {
    let old = PlaybackQueue(generation: 1, previous: [entry("p")], current: entry("a"), next: [entry("b")])
    let new = PlaybackQueue(generation: 2, previous: [entry("a")], current: entry("b"), next: [])
    #expect(carouselDirection(old: old, new: new) == .next)
}
```

Add reversed movement and externally replaced identical-URI/different-key cases; the latter must fade. Run PlayerPresentationTests and observe failure.

- [ ] **Recompose metadata and draw the fixed disc.** Place title and artist above the disc, with regular SF typography and restrained favorite/options actions. Remove the duplicated below-disc metadata placement and the rounded semibold title styling. Use 310 pt outer diameter at 410 pt width, central art 204 pt, neighbors 80 pt. Layout scales down at 390 pt. Upper-left and lower-right neighbor centers remain far enough inside the content bounds for their 40 pt radii. Use fixed smoked disc fills, three thin circular strokes and a directional perimeter highlight.
- [ ] **Animate artwork identities.** Render one layer per occurrence key. Define a quadratic path between slot centers with a small perpendicular control-point offset; animate position and diameter together with a 720 ms restrained spring. Never transform the whole canvas in perspective or rotate the album art.

```swift
func point(onCurveFrom start: CGPoint, through control: CGPoint,
           to end: CGPoint, progress: CGFloat) -> CGPoint {
    let t = min(1, max(0, progress)), u = 1 - t
    return CGPoint(x: u*u*start.x + 2*u*t*control.x + t*t*end.x,
                   y: u*u*start.y + 2*u*t*control.y + t*t*end.y)
}
```

Keep this private to ArtworkCarouselView, used by an animatable modifier. Retarget from current presentation values when a confirmed track arrives mid-transition; a completion callback carries a generation token and cannot remove a newer layer. Crossfade title/artist/palette together toward the confirmed track. Reduce Motion uses a short fade without curved travel or overshoot.

- [ ] **Verify native motion, including interruption.** Record next twice within 200 ms, next→previous, external skip, duplicate songs, no previous/next entry, missing incoming art, and metadata arriving mid-transition. After settling there must be exactly one center occurrence and at most two neighbors, matching PlayerModel. Test with Reduce Motion. Run presentation tests and app build.
- [ ] **Commit** with subject `Animate confirmed tracks through the circular artwork carousel`.

## Task 6: Integrate radial seeking and complete transport controls

**Files:** new `RadialProgressView.swift`; `TransportControls.swift`, `MiniPlayerView.swift`, `PlayerPresentation.swift`, `PlayerPresentationTests.swift`, `Localizable.xcstrings`.

**Interfaces:** `RadialProgressView(positionMs: Int64, durationMs: Int64, canSeek: Bool, seek: (Int64) -> Void)`; pure `radialProgress(x: Double, y: Double) -> Double?` added next to presentation math; Task 3 model commands.

- [ ] **Write cardinal-point and invalid-duration tests.** Coordinates are relative to the center in screen coordinates (positive y down); zero is twelve o'clock. The exact center returns nil, avoiding undefined seeking.

```swift
@Test func radialProgressStartsAtTwelveAndRunsClockwise() {
    #expect(radialProgress(x: 0, y: -1) == 0)
    #expect(radialProgress(x: 1, y: 0) == 0.25)
    #expect(radialProgress(x: 0, y: 1) == 0.5)
    #expect(radialProgress(x: -1, y: 0) == 0.75)
    #expect(radialProgress(x: 0, y: 0) == nil)
}
```

- [ ] **Implement geometry and accessible seeking.** Use the same progress fraction to draw Circle.trim rotated −90° and position the marker. A TimelineView interpolates through `player.displayPositionMs(at:)` while playing; pause its schedule only while playback is stopped or the window is hidden. Reduce Motion uses periodic one-second updates rather than smooth travel, so the clock still advances. Text timestamps and marker must read that same sampled value.

```swift
public func radialProgress(x: Double, y: Double) -> Double? {
    guard x.isFinite, y.isFinite, x*x + y*y > 0 else { return nil }
    let turns = (atan2(y, x) + .pi / 2) / (2 * .pi)
    return turns < 0 ? turns + 1 : turns
}
```

Accept pointer scrubs only in a ring hit band. During an active drag, unwrap crossing at twelve o'clock relative to the previous fraction and clamp to 0...1 so the end does not jump to the beginning accidentally. Submit one seek on release; cancel on device/track change. Add adjustable accessibility increment/decrement actions using five-second seeks, a position/duration label and keyboard support. Duration zero disables seek and draws an empty arc. Place elapsed/remaining labels near the disc lower edge.

- [ ] **Extend transport with observed shuffle/repeat, hover and press feedback.** Keep one glass region. Use explicit accessible on/off/repeat-track values, a filled indicator beyond color, and 160 ms symbol transitions. Previous/play/next retain functional gating. Add volume in the contextual menu wired to the existing engine. Favorite is wired only through the companion plan's state machine; never create a temporary local saved boolean.
- [ ] **Verify ring wrap and interaction.** Add unwrapped-drag tests (0.99→0.01 clamps at end; 0.01→0.99 clamps at start), seeking while paused, cancel on external track change, and inactive controls. Native test VoiceOver adjustment, keyboard, reduced motion and tiny/zero durations. Run affected tests and app build.
- [ ] **Commit** with subject `Add radial seeking and complete observed transport controls`.

## Task 7: Add Up Next and compact presentations with shared artwork

**Files:** new `QueueView.swift`, `CompactPlayerView.swift`; `MiniPlayerView.swift`, `PlayerPresentation.swift`, `PlayerPreviews.swift`, `Localizable.xcstrings`.

**Interfaces:** Both views consume PlayerModel, ArtworkStore, and PlayerPresentation. Queue rows call `player.selectQueueEntry(entry.target)` only for nonnil targets; no row calls `load(contextURI:)`. CompactPlayerView is the same component in queue and compact mode.

- [ ] **Pin presentation escape behavior with a failing test.** Define the proposed `PlayerPresentation` public init with defaults expanded/Keep on Top false:

```swift
@MainActor @Test func escapeReturnsFromQueueBeforeHiding() {
    let presentation = PlayerPresentation()
    presentation.setMode(.queue)
    #expect(presentation.dismissQueue())
    #expect(presentation.mode == .expanded)
    #expect(!presentation.dismissQueue())
}
```

Also check mode transitions never issue playback commands. Run PlayerPresentationTests.

- [ ] **Build a single shell with one artwork namespace.** Render the 48 pt square queue thumbnails in a LazyVStack and the floating compact controls above protected bottom scroll space. Show current plus available upcoming entries; duration/title fallback never reorders rows. Empty/loading/error queue states retain transport. For 380 × 88 pt compact mode, keep circular 48 pt current art, truncating title/artist, play/pause, next, expand. Support 340 pt with lower-priority action moved to the context menu.

```swift
@Namespace private var currentArtworkNamespace
// Exactly one active source for the current occurrence in each mode:
artwork
    .matchedGeometryEffect(id: "current-artwork", in: currentArtworkNamespace)
```

In the real body, `artwork` is the shared current ArtworkView at the mode's target diameter; attach the modifier at its single rendered source. Keep carousel occurrence identity separate from the persistent current-artwork slot. Animate queue mode with a 550 ms transition; contract/fade the disc and neighbors while moving the art into the lower compact region. Reduce Motion crossfades. Synchronize mode/track changes so a concurrent skip does not create two sources.

- [ ] **Verify scrolling and changing track during transformations.** Native previews with 0, 1, 80 next rows, duplicate titles, long metadata, missing thumbnails and loading failures. Click a row after an external reorder and confirm safe rejection. Record entering/exiting queue during a skip, rapidly expanding/collapsing, and the last row scrolling fully above the compact player. Build and run state tests.
- [ ] **Commit** with subject `Transform the player into Up Next and compact presentations`.

## Task 8: Make the native window persistent, movable and input-correct

**Files:** `StatusPanel.swift`, `StatusItemController.swift`, `AppEnvironment.swift`, `BopifyApp.swift`, `MiniPlayerView.swift`, `PlayerPresentation.swift`, `PlayerPresentationTests.swift`.

**Interfaces:** AppEnvironment owns one `PlayerPresentation` and ArtworkStore for the session; StatusItemController observes mode/topmost changes and configures the existing panel. Add `StatusPanel.onSeek: ((Int64) -> Void)?`, `onDismissQueue: (() -> Bool)?`, and an internal `setPresentation(mode: PlayerMode, keepOnTop: Bool, reduceMotion: Bool)`.

- [ ] **Implement and verify frame math before changing window lifetime.** Keep top-left screen position across expanded/compact transitions and clamp to the current screen visibleFrame. New pure `clampedPlayerFrame(origin: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGRect` lives alongside presentation helpers and is tested for screen edges, removed screens, and screens smaller than the preferred height. Respect the visible screen by reducing size within usable limits and scrolling expanded content if required.

```swift
@Test func windowClampsInsideVisibleScreen() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let frame = clampedPlayerFrame(origin: CGPoint(x: 950, y: 650),
                                   size: CGSize(width: 410, height: 560), visibleFrame: screen)
    #expect(screen.contains(frame))
    #expect(frame.size == CGSize(width: 410, height: 560))
}
```

- [ ] **Replace transient dismissal with native utility behavior.** Remove the outside-click monitor; set normal window level by default and floating only for Keep on Top. Preserve nonactivating/key-window input behavior where compatible, allow movement through a deliberate drag region, and resize the same panel for modes. Remember frame/mode/Keep on Top in UserDefaults (presentation only); clamp restored frame before showing. Status click toggles visibility without destroying the player. Use genuine native title-bar controls if adopting a titled style; never draw imitations. Observe mode changes without rebuilding the hosting root or resubscribing PlayerModel.

- [ ] **Route keyboard actions without intercepting editors.** Let NSTextView/field-editor and focused standard controls handle input before panel shortcuts. Space controls playback; Command-Left/Right changes tracks; unmodified arrows seek ±5 seconds only in player focus. Escape first dismisses a menu/queue, then hides the panel. No key-monitor that intercepts typing globally. Keep sign-out and quit routing through AppEnvironment serialization.
- [ ] **Verify the actual window.** Open from menu bar, drag, switch apps, collapse, reopen, toggle Keep on Top, use multiple displays/Spaces and remove a display. Test Space/arrows inside URI input and while a menu/control owns focus. Confirm playback survives hiding, and auth/error states remain usable at compact/expanded sizes; expand automatically when text entry is required. Capture native screenshots before and after.
- [ ] **Commit** with subject `Keep the mini-player movable and persistent across presentations`.

## Task 9: Verify integrated behavior and brief compliance

**Files:** existing previews/test fixtures; **new** `docs/superpowers/verification/2026-09-24-mini-player.md` and native evidence captures. Incorporate fixes only in the files responsible for failures.

- [ ] **Run affected tests and full app build.** Use the baseline commands after rebuilding the Rust artifact. Run the patched dependency tests for our added behavior. Inspect complete failures; fix root causes. Do not call the result finished on the strength of an app build alone.
- [ ] **Run real queue validation.** With the user's own running session, use a queue containing two occurrences of one song. Select the second; check the exact retained suffix, shuffle/repeat preservation, no intermediate song, stale click rejection, next/previous, external changes and end-of-track. Record observed behavior without dumping tokens or provider payloads. If the account is unavailable, state exactly which live checks remain unverified.
- [ ] **Finish the companion favorites plan.** Confirm genuine saved-state round trip and denied-consent/403/refresh failures without disrupting playback. Do not mark the original brief complete with an inert or local-only heart.
- [ ] **Record the visual acceptance matrix.** Capture expanded/compact/queue at supported widths, dark/light wallpaper, system appearances, bright/missing art, long labels, loading/error/empty/end states, increased text, increased contrast, Reduce Transparency and Reduce Motion. Record carousel and queue transitions at normal speed and during repeated commands. Reuse the original audit captures for before/after comparison.
- [ ] **Profile a short sustained playback session and review scope.** No continuous album spin or animation when hidden/paused; no repeated palette extraction; no unbounded artwork/metadata cache; no transport blocked by metadata. Check the diff for unrelated edits and regenerate localization entries only for changed copy. Write observed test/build/visual results and limitations into the verification file.
- [ ] **Obtain a whole-change review and integrate through the selected execution workflow.** The reviewer reads the approved spec, both plans, actual diff, and verification evidence. Resolve substantive findings, then present the final result with before/after captures and honest remaining limitations.

## Coverage and handoff

| Spec requirement | Owning task |
| --- | --- |
| Dark composition, correct disc/art sizes and native material | 4–6 |
| Real neighbors, exact queue selection, duplicate safety | 1–3 |
| Curved transitions, rapid-input convergence and palette synchronization | 4–5, 7 |
| Shared clock, radial progress, accessible seek | 3, 6 |
| Shuffle/repeat/favorite | 2–3, 6, companion plan |
| Queue/compact transformation, scrolling and persistent controls | 7 |
| Movable persistent window, topmost option and keyboard behavior | 8 |
| Loading/error/empty/inactive/end states, accessibility and performance | 3–9 |

Implementation starts only after the user reviews this plan, the companion plan, the proposed pinned-source patch, and chooses an execution method. Recommended execution: **Native**, because the queue contract, model, and presentation changes share interfaces and are easier to keep coherent in one implementation context, with a fresh whole-change review at the end.

## Primary references checked 2026-09-24

- [librespot pinned source](https://github.com/librespot-org/librespot/tree/939dc5ee9d833e1980f9495241219d9d4868a061): source of the current queue and Spirc constraints; the new selection API above is our proposal.
- [Apple — Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views): native control treatment and grouping.
- [Apple — Core Image areaAverage](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/areaaverage()): native average-color reduction for cached palette extraction.
- [Apple — GeometryEffect](https://developer.apple.com/documentation/swiftui/geometryeffect): geometry synchronization and animatable transforms.
- [Apple — Accessible controls](https://developer.apple.com/documentation/swiftui/accessible-controls): adjustable actions for the radial seek control.
