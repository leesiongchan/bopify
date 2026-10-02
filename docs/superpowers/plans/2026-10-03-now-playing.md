# Media Keys and Now Playing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bopify shows its track in macOS Now Playing and answers media keys, headphone controls and Control Center while it is the device playing.

**Architecture:** A pure function in `BopifyPlayback` maps `PlaybackState` to a `NowPlayingInfo` value, or `nil` when Bopify should step aside. An app-side `NowPlayingController` observes the player and artwork store, writes that value to `MPNowPlayingInfoCenter`, and routes `MPRemoteCommandCenter` commands to the existing `PlayerModel` methods. `AppEnvironment` creates and stops the controller alongside the player.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Observation, MediaPlayer (macOS), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-03-now-playing-design.md`

## Global Constraints

- Deployment target macOS 14.0; the app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and Swift 6 language mode.
- No new package dependencies; MediaPlayer is a system framework.
- Claim Now Playing only while `isActiveDevice` and `currentTrack != nil`; otherwise clear the info, set `playbackState = .stopped`, and disable every command.
- Write to `MPNowPlayingInfoCenter` on state changes only, never on a timer; set `playbackState` explicitly on every write.
- Commands go through the existing `PlayerModel` methods (`togglePlayPause()`, `next()`, `previous()`, `seek(to:)`); handlers return `.commandFailed` when Bopify is not the active device.
- Logs: debug level in `BopifyLog.playback`, no track identifiers.
- Comments explain why, at most two sentences. Commit messages: subject under 72 characters, a body explaining why, and no Co-Authored-By line (AGENTS.md).

---

## File Structure

| File | Responsibility |
|---|---|
| `Packages/BopifyCore/Sources/BopifyPlayback/NowPlayingInfo.swift` (new) | `NowPlayingInfo` value and `nowPlayingInfo(for:positionMs:)` |
| `Packages/BopifyCore/Tests/PlaybackTests/NowPlayingInfoTests.swift` (new) | The mapping's rules |
| `Bopify/Bopify/NowPlayingController.swift` (new) | MediaPlayer adapter: observation, info writes, artwork, remote commands |
| `Bopify/Bopify/AppEnvironment.swift` | Creates the controller with the player, stops it wherever the player stops |

---

### Task 1: Map playback state to Now Playing

**Files:**
- Create: `Packages/BopifyCore/Sources/BopifyPlayback/NowPlayingInfo.swift`
- Test: `Packages/BopifyCore/Tests/PlaybackTests/NowPlayingInfoTests.swift`

**Interfaces:**
- Consumes: `PlaybackState`, `PlaybackPhase`, `Track` from `BopifyDomain`.
- Produces:
  - `public struct NowPlayingInfo: Equatable, Sendable` with `title: String`, `artist: String`, `album: String?`, `artworkURL: URL?`, `durationMs: Int64`, `elapsedMs: Int64`, `isPlaying: Bool`, `canNext: Bool`, `canPrevious: Bool`, `canSeek: Bool`.
  - `public func nowPlayingInfo(for state: PlaybackState, positionMs: Int64) -> NowPlayingInfo?`

- [ ] **Step 1: Write the failing tests**

Create `Packages/BopifyCore/Tests/PlaybackTests/NowPlayingInfoTests.swift`:

```swift
import Foundation
import Testing
import BopifyDomain
@testable import BopifyPlayback

@Suite("Now Playing info")
struct NowPlayingInfoTests {
    let track = Track(uri: SpotifyURI("spotify:track:a")!, title: "Night Bloom",
                      artists: [ArtistSummary(name: "The Lanterns"), ArtistSummary(name: "Odile")],
                      albumTitle: "Lanterns", artwork: Artwork(url: URL(string: "https://i.scdn.co/image/a")!),
                      durationMs: 187_000)

    func state(_ phase: PlaybackPhase, active: Bool = true, track: Track?) -> PlaybackState {
        var state = PlaybackState()
        state.phase = phase
        state.isActiveDevice = active
        state.currentTrack = track
        state.durationMs = track?.durationMs ?? 0
        state.canNext = true
        state.canPrevious = true
        state.canSeek = true
        return state
    }

    @Test func playingClaimsNowPlayingWithTheTrack() {
        let info = nowPlayingInfo(for: state(.playing, track: track), positionMs: 64_000)
        #expect(info == NowPlayingInfo(title: "Night Bloom", artist: "The Lanterns, Odile", album: "Lanterns",
                                       artworkURL: URL(string: "https://i.scdn.co/image/a"), durationMs: 187_000,
                                       elapsedMs: 64_000, isPlaying: true, canNext: true, canPrevious: true, canSeek: true))
    }

    @Test(arguments: [PlaybackPhase.paused, .loading, .buffering, .ended, .error(.networkUnavailable)])
    func otherPhasesOnThisDeviceReportPausedAndKeepTheTrack(_ phase: PlaybackPhase) {
        let info = nowPlayingInfo(for: state(phase, track: track), positionMs: 1_000)
        #expect(info?.isPlaying == false)
        #expect(info?.title == "Night Bloom")
    }

    @Test func anotherDevicePlayingStepsAside() {
        var mirroring = state(.idle, active: false, track: track)
        mirroring.remote = RemotePlayback(deviceName: "Kitchen Speaker", trackURI: track.uri, track: track,
                                          isPlaying: true, positionMs: 0, durationMs: track.durationMs)
        #expect(nowPlayingInfo(for: mirroring, positionMs: 0) == nil)
    }

    @Test func aLostSessionStepsAside() {
        #expect(nowPlayingInfo(for: state(.error(.playbackSessionLost), active: false, track: track), positionMs: 0) == nil)
    }

    @Test func noTrackStepsAside() {
        #expect(nowPlayingInfo(for: state(.idle, track: nil), positionMs: 0) == nil)
    }

    @Test func missingArtworkAndAlbumStayEmpty() {
        let bare = Track(uri: track.uri, title: "Night Bloom", artists: [], albumTitle: nil, artwork: nil, durationMs: 1_000)
        let info = nowPlayingInfo(for: state(.playing, track: bare), positionMs: 0)
        #expect(info?.artworkURL == nil)
        #expect(info?.album == nil)
        #expect(info?.artist == "")
    }

    @Test func availabilityFollowsThePlayer() {
        var limited = state(.playing, track: track)
        limited.canNext = false
        limited.canPrevious = false
        limited.canSeek = false
        let info = nowPlayingInfo(for: limited, positionMs: 0)
        #expect(info?.canNext == false)
        #expect(info?.canPrevious == false)
        #expect(info?.canSeek == false)
    }

    @Test func seekingNeedsAKnownDuration() {
        var unknown = state(.playing, track: track)
        unknown.durationMs = 0
        #expect(nowPlayingInfo(for: unknown, positionMs: 0)?.canSeek == false)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Packages/BopifyCore --filter NowPlayingInfo`
Expected: build failure, "cannot find 'nowPlayingInfo' in scope" / "cannot find 'NowPlayingInfo' in scope".

- [ ] **Step 3: Write the implementation**

Create `Packages/BopifyCore/Sources/BopifyPlayback/NowPlayingInfo.swift`:

```swift
import Foundation
import BopifyDomain

/// What macOS's Now Playing shows for Bopify's current track.
public struct NowPlayingInfo: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String?
    public let artworkURL: URL?
    public let durationMs: Int64
    public let elapsedMs: Int64
    public let isPlaying: Bool
    public let canNext: Bool
    public let canPrevious: Bool
    public let canSeek: Bool

    public init(title: String, artist: String, album: String?, artworkURL: URL?, durationMs: Int64, elapsedMs: Int64,
                isPlaying: Bool, canNext: Bool, canPrevious: Bool, canSeek: Bool) {
        self.title = title; self.artist = artist; self.album = album; self.artworkURL = artworkURL
        self.durationMs = durationMs; self.elapsedMs = elapsedMs; self.isPlaying = isPlaying
        self.canNext = canNext; self.canPrevious = canPrevious; self.canSeek = canSeek
    }
}

/// Nil unless Bopify is the device playing, so media keys reach other apps while it only mirrors another device.
/// `positionMs` is the player's display position, so Now Playing's clock matches Bopify's own.
public func nowPlayingInfo(for state: PlaybackState, positionMs: Int64) -> NowPlayingInfo? {
    guard state.isActiveDevice, let track = state.currentTrack else { return nil }
    return NowPlayingInfo(title: track.title, artist: track.artists.map(\.name).joined(separator: ", "),
                          album: track.albumTitle, artworkURL: track.artwork?.url, durationMs: state.durationMs,
                          elapsedMs: positionMs, isPlaying: state.phase == .playing, canNext: state.canNext,
                          canPrevious: state.canPrevious, canSeek: state.canSeek && state.durationMs > 0)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path Packages/BopifyCore --filter NowPlayingInfo`
Expected: all `Now Playing info` tests pass.

Then run the whole suite: `swift test --package-path Packages/BopifyCore`
Expected: every suite passes.

- [ ] **Step 5: Commit**

```bash
git add Packages/BopifyCore/Sources/BopifyPlayback/NowPlayingInfo.swift Packages/BopifyCore/Tests/PlaybackTests/NowPlayingInfoTests.swift
git commit -m "Map playback state to what Now Playing shows" -m "A pure rule for when Bopify claims macOS Now Playing and what it shows, so the MediaPlayer adapter only copies values and the rules stay testable."
```

---

### Task 2: Drive MediaPlayer from the player

**Files:**
- Create: `Bopify/Bopify/NowPlayingController.swift`
- Modify: `Bopify/Bopify/AppEnvironment.swift` (the `player` property near line 24, `signOut()`, `prepareForQuit()`, `connect()`)

**Interfaces:**
- Consumes: `nowPlayingInfo(for:positionMs:)` and `NowPlayingInfo` (Task 1); `PlayerModel.state`, `displayPositionMs(at:)`, `togglePlayPause()`, `next()`, `previous()`, `seek(to:)`; `ArtworkStore.images: [URL: NSImage]`.
- Produces: `@MainActor final class NowPlayingController` with `init(player: PlayerModel, artworkStore: ArtworkStore)` and `func stop()`.

The app has no unit tests for system adapters; this task's check is a clean Debug and Release build, and Task 3 checks it by hand.

- [ ] **Step 1: Create the controller**

Create `Bopify/Bopify/NowPlayingController.swift`:

```swift
import AppKit
import MediaPlayer
import Observation
import os
import BopifyDomain
import BopifyPlayback

/// Mirrors the player into macOS's Now Playing and routes media keys, headphone and Control Center commands back to it.
final class NowPlayingController {
    private let player: PlayerModel
    private let artworkStore: ArtworkStore
    private let center = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private var targets: [(command: MPRemoteCommand, token: Any)] = []
    private var artwork: (url: URL, item: MPMediaItemArtwork)?
    private var isClaimed = false
    private var isStopped = false

    init(player: PlayerModel, artworkStore: ArtworkStore) {
        self.player = player
        self.artworkStore = artworkStore
        addTargets()
        observe()
    }

    func stop() {
        isStopped = true
        for target in targets { target.command.removeTarget(target.token) }
        targets = []
        apply(nil)
    }

    private func observe() {
        guard !isStopped else { return }
        let info = withObservationTracking {
            let info = nowPlayingInfo(for: player.state, positionMs: player.displayPositionMs(at: .now))
            // Read the image so artwork that finishes loading later triggers another write.
            _ = info?.artworkURL.flatMap { artworkStore.images[$0] }
            return info
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        apply(info)
    }

    private func apply(_ info: NowPlayingInfo?) {
        guard let info else {
            if isClaimed { BopifyLog.playback.debug("now playing released") }
            isClaimed = false
            center.nowPlayingInfo = nil
            // macOS cannot infer this from an audio session, so it must be set on every change.
            center.playbackState = .stopped
            setEnabled(transport: false, next: false, previous: false, seek: false)
            return
        }
        if !isClaimed { BopifyLog.playback.debug("now playing claimed") }
        isClaimed = true
        var values: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.artist,
            MPMediaItemPropertyPlaybackDuration: Double(info.durationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(info.elapsedMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: info.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = info.album { values[MPMediaItemPropertyAlbumTitle] = album }
        if let item = artworkItem(for: info.artworkURL) { values[MPMediaItemPropertyArtwork] = item }
        center.nowPlayingInfo = values
        center.playbackState = info.isPlaying ? .playing : .paused
        setEnabled(transport: true, next: info.canNext, previous: info.canPrevious, seek: info.canSeek)
    }

    private func artworkItem(for url: URL?) -> MPMediaItemArtwork? {
        guard let url, let image = artworkStore.images[url] else { return nil }
        if let artwork, artwork.url == url { return artwork.item }
        let item = Self.makeArtwork(image)
        artwork = (url, item)
        return item
    }

    /// MediaPlayer asks for the image off the main thread, so the handler must not be main-actor isolated.
    private nonisolated static func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        nonisolated(unsafe) let image = image
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func setEnabled(transport: Bool, next: Bool, previous: Bool, seek: Bool) {
        commands.playCommand.isEnabled = transport
        commands.pauseCommand.isEnabled = transport
        commands.togglePlayPauseCommand.isEnabled = transport
        commands.nextTrackCommand.isEnabled = next
        commands.previousTrackCommand.isEnabled = previous
        commands.changePlaybackPositionCommand.isEnabled = seek
    }

    private func addTargets() {
        add(commands.playCommand, "play") { player, _ in
            if player.state.phase != .playing { player.togglePlayPause() }
        }
        add(commands.pauseCommand, "pause") { player, _ in
            if player.state.phase == .playing { player.togglePlayPause() }
        }
        add(commands.togglePlayPauseCommand, "togglePlayPause") { player, _ in player.togglePlayPause() }
        add(commands.nextTrackCommand, "next") { player, _ in player.next() }
        add(commands.previousTrackCommand, "previous") { player, _ in player.previous() }
        add(commands.changePlaybackPositionCommand, "changePosition") { player, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            player.seek(to: Int64(event.positionTime * 1000))
        }
    }

    private func add(_ command: MPRemoteCommand, _ name: StaticString,
                     _ perform: @escaping @MainActor (PlayerModel, MPRemoteCommandEvent) -> Void) {
        let token = command.addTarget { [weak self] event in
            Self.onMain {
                guard let self, self.player.state.isActiveDevice else { return .commandFailed }
                BopifyLog.playback.debug("remote command \(name, privacy: .public)")
                perform(self.player, event)
                return .success
            }
        }
        targets.append((command, token))
    }

    /// MediaPlayer does not document the handler's thread, so this runs the body on the main actor either way.
    private nonisolated static func onMain(_ body: @MainActor () -> MPRemoteCommandHandlerStatus) -> MPRemoteCommandHandlerStatus {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
}
```

Notes for the implementer:
- The class has no explicit `@MainActor` because the app target defaults to main-actor isolation; `makeArtwork` and `onMain` are explicitly `nonisolated`.
- `BopifyLog.playback.debug` with a `StaticString` interpolation: if the compiler rejects `\(name, privacy: .public)` for `StaticString`, change the parameter type to `String`.
- If the closure passed to `command.addTarget` is inferred main-actor isolated and the compiler complains about calling the `nonisolated` `onMain` from a `@Sendable` closure capturing `perform`, mark `perform` `@Sendable` as well (`@escaping @Sendable @MainActor (PlayerModel, MPRemoteCommandEvent) -> Void`). Do not use `MainActor.assumeIsolated` directly in the handler without the `Thread.isMainThread` branch.

- [ ] **Step 2: Wire it into `AppEnvironment`**

In `Bopify/Bopify/AppEnvironment.swift`:

Add a stored property after `private(set) var player: PlayerModel?`:

```swift
    @ObservationIgnored private var nowPlaying: NowPlayingController?
```

In `signOut()`, replace

```swift
            player?.stop()
            player = nil
            artworkStore.clear()
```

with

```swift
            nowPlaying?.stop()
            nowPlaying = nil
            player?.stop()
            player = nil
            artworkStore.clear()
```

In `prepareForQuit()`, replace

```swift
            clearLibrary()
            player?.stop()
            player = nil
```

with

```swift
            clearLibrary()
            nowPlaying?.stop()
            nowPlaying = nil
            player?.stop()
            player = nil
```

In `connect()`, replace

```swift
            await self.engine?.shutdown()
            player?.stop()
            clearLibrary()
            self.engine = engine
            player = model
```

with

```swift
            await self.engine?.shutdown()
            nowPlaying?.stop()
            player?.stop()
            clearLibrary()
            self.engine = engine
            player = model
            nowPlaying = NowPlayingController(player: model, artworkStore: artworkStore)
```

The preview initialiser does not create a controller, so previews never touch the system's Now Playing.

- [ ] **Step 3: Build Debug**

Run: `xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-now-playing-build build`
Expected: exit 0, no errors, no new warnings.

- [ ] **Step 4: Build Release**

Run: `xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/bopify-now-playing-release build CODE_SIGNING_ALLOWED=NO`
Expected: exit 0.

- [ ] **Step 5: Run the package suite**

Run: `swift test --package-path Packages/BopifyCore`
Expected: every suite passes.

- [ ] **Step 6: Commit**

```bash
git add Bopify/Bopify/NowPlayingController.swift Bopify/Bopify/AppEnvironment.swift
git commit -m "Show Bopify in Now Playing and answer media keys" -m "PRD PLAY-09 and PLAY-10: while Bopify is the device playing, macOS Now Playing shows its track and media keys, headphones and Control Center control it through the same PlayerModel methods as the on-screen buttons. It steps aside otherwise so the keys reach other apps."
```

---

### Task 3: Check it by hand

This task is for the controller and the user, not an implementer subagent: it needs the running app, a Spotify session and the user's keyboard.

- [ ] **Step 1: Launch the Debug build**

Run: `open /private/tmp/bopify-now-playing-build/Build/Products/Debug/Bopify.app`

Capture logs: `/usr/bin/log stream --predicate 'subsystem == "com.leesiongchan.bopify" AND category == "playback"' --level debug`

- [ ] **Step 2: The user checks**

1. Play a track in Bopify. The keyboard's play/pause, next and previous keys control it.
2. Control Center's Now Playing shows the title, artist and artwork, and the progress bar moves; dragging its scrubber seeks.
3. Pausing in Bopify's window updates Control Center to paused.
4. Headphone controls (AirPods or wired), where available.
5. Start playback on another device so Bopify only mirrors it; the media keys now reach Music or a browser, and the log shows `now playing released`.

- [ ] **Step 3: Record the result**

Note the outcome of each check in the reply to the user; fix anything that fails before merging.
