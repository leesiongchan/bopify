import Nuke
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
    private var artwork = NowPlayingArtwork()
    private var artworkTask: Task<Void, Never>?
    private var isClaimed = false
    private var isStopped = false
    private var requestedArtwork: ArtworkLoadRequest?

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
            let info = nowPlayingInfo(for: player.state, positionMs: player.displayPositionMs(at: .now), connectionReady: player.isEngineReady)
            // Read the image so artwork that finishes loading later triggers another write.
            _ = info?.artworkURL.flatMap { artworkStore.image(for: $0) }
            _ = artworkStore.retryRevision
            _ = artworkStore.sessionRevision
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
            requestedArtwork = nil
            artworkTask?.cancel()
            artworkTask = nil
            artwork = NowPlayingArtwork()
            center.nowPlayingInfo = nil
            // macOS cannot infer this from an audio session, so it must be set on every change.
            center.playbackState = .stopped
            setEnabled(transport: false, next: false, previous: false, seek: false)
            return
        }
        if !isClaimed { BopifyLog.playback.debug("now playing claimed") }
        isClaimed = true
        loadArtworkIfNeeded(info.artworkURL)
        var values: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.artist,
            MPMediaItemPropertyPlaybackDuration: Double(info.durationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(info.elapsedMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: info.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = info.album { values[MPMediaItemPropertyAlbumTitle] = album }
        if let item = artwork.item(for: info.artworkURL, image: info.artworkURL.flatMap { artworkStore.image(for: $0) }) { values[MPMediaItemPropertyArtwork] = item }
        center.nowPlayingInfo = values
        center.playbackState = info.isPlaying ? .playing : .paused
        setEnabled(transport: true, next: info.canNext, previous: info.canPrevious, seek: info.canSeek)
    }

    /// The record view only loads artwork while it is on screen, so the controller asks for it when the URL changes.
    private func loadArtworkIfNeeded(_ url: URL?) {
        let request = ArtworkLoadRequest(url: url, retryRevision: artworkStore.retryRevision,
                                         sessionRevision: artworkStore.sessionRevision)
        guard request != requestedArtwork else { return }
        if requestedArtwork?.sessionRevision != request.sessionRevision { artwork = NowPlayingArtwork() }
        requestedArtwork = request
        artworkTask?.cancel()
        artworkTask = nil
        guard let url, artwork.item(for: url, image: artworkStore.image(for: url)) == nil else { return }
        artworkTask = Task { [weak self, artworkStore] in
            guard let response = await artworkStore.load(url), !Task.isCancelled,
                  let self, requestedArtwork == request, !isStopped else { return }
            _ = artwork.item(for: url, image: response.image)
            apply(nowPlayingInfo(for: player.state, positionMs: player.displayPositionMs(at: .now), connectionReady: player.isEngineReady))
        }
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
        add(commands.playCommand, "play") { player, _ in Self.toggle(player, whenPhaseIs: .paused) }
        add(commands.pauseCommand, "pause") { player, _ in Self.toggle(player, whenPhaseIs: .playing) }
        add(commands.togglePlayPauseCommand, "togglePlayPause") { player, _ in
            Self.toggle(player, whenPhaseIs: .playing, .paused)
        }
        add(commands.nextTrackCommand, "next") { player, _ in player.next() }
        add(commands.previousTrackCommand, "previous") { player, _ in player.previous() }
        add(commands.changePlaybackPositionCommand, "changePosition") { player, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent, event.positionTime.isFinite else { return }
            player.seek(to: Int64(event.positionTime * 1000))
        }
    }

    /// Mirrors Bopify's own button and the Space key, which ignore loading and buffering.
    private static func toggle(_ player: PlayerModel, whenPhaseIs phases: PlaybackPhase...) {
        guard phases.contains(player.state.phase) else { return }
        player.togglePlayPause()
    }

    private func add(_ command: MPRemoteCommand, _ name: StaticString,
                     _ perform: @escaping @Sendable @MainActor (PlayerModel, MPRemoteCommandEvent) -> Void) {
        let token = command.addTarget { @Sendable [weak self] event in
            // The caller blocks until onMain returns, so the event is never used concurrently.
            nonisolated(unsafe) let event = event
            return Self.onMain {
                BopifyLog.playback.debug("remote command \(name, privacy: .public)")
                guard let self, self.player.isEngineReady, self.player.state.isActiveDevice else { return .commandFailed }
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

struct NowPlayingArtwork {
    private var retained: (url: URL, item: MPMediaItemArtwork)?

    mutating func item(for url: URL?, image: NSImage?) -> MPMediaItemArtwork? {
        guard let url else { retained = nil; return nil }
        if let retained, retained.url == url { return retained.item }
        retained = nil
        guard let image else { return nil }
        let item = Self.makeArtwork(image)
        retained = (url, item)
        return item
    }

    /// MediaPlayer requests images off the main thread.
    private nonisolated static func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
