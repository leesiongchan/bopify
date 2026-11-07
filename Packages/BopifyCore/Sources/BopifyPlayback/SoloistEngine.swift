import Foundation
import BopifyDomain

public enum SoloistEngineStatus: Equatable, Sendable {
    case checkingAccount, pairing(String), verifying, prepared, ready, servicesUnavailable, reconnecting
    case failed(SoloistPlaybackError)
}

/// Soloist owns audio; its companion has no audio output or Connect registration.
public actor SoloistEngine: PreparedPlaybackEngine {
    public nonisolated let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let child: any SoloistProcessHandle
    private let api: SoloistWebAPI
    private let baseline: Set<SoloistDevice>
    private let name: String
    private let webToken: @Sendable () async throws -> String
    private let streamingToken: @Sendable () async throws -> String
    private let transportFactory: @Sendable (URL) -> any SoloistTransport
    private let progress: @Sendable (SoloistEngineStatus) -> Void
    private let publisherFactory: SoloistPairingPublisherFactory?
    private var pairingPublication: (any SoloistPairingPublishing)?
    private var publicationTask: Task<any SoloistPairingPublishing, any Error>?
    private var transport: (any SoloistTransport)?
    private var receiver: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var verifier: Task<Void, Never>?
    private var socketID = UUID()
    private var state = SoloistState()
    private var connected = false
    private var stopped = false
    private var shutdownTask: Task<Void, Never>?
    private var verifiedRevision: UInt64?
    private var deviceID: String?
    private var verifiedCredentials: (web: String, streaming: String)?
    private var dataRevision: UInt64 = 0
    private var dataAuthorizationPaused = false
    private var services: (any SoloistDataServices)?
    private var servicesFlight: Task<any SoloistDataServices, any Error>?
    private var serviceFlightID: UUID?
    private var servicesWarmup: Task<Void, Never>?
    private var servicesWarmupID: UUID?
    private var nextServiceAttempt = Date.distantPast
    private let verificationInterval: Duration
    private var adopted = false
    private let serviceFactory: @Sendable (String) async throws -> any SoloistDataServices
    private var bootstrapped = false
    private var latestStatus: SoloistEngineStatus?
    private var polls = 0
    private var preferredVolume: Double = 0.5
    public var isPaired: Bool { state.paired }
    public var isConnected: Bool { connected }

    init(child: any SoloistProcessHandle, api: SoloistWebAPI, baseline: Set<SoloistDevice>, name: String,
        webToken: @escaping @Sendable () async throws -> String,
        streamingToken: @escaping @Sendable () async throws -> String,
        transportFactory: @escaping @Sendable (URL) -> any SoloistTransport = { SoloistSocket(endpoint: $0) },
        serviceFactory: @escaping @Sendable (String) async throws -> any SoloistDataServices = { try await LibrespotServices(accessToken: $0) },
        progress: @escaping @Sendable (SoloistEngineStatus) -> Void,
        verificationInterval: Duration = .seconds(5), publisherFactory: SoloistPairingPublisherFactory? = nil) {
        self.verificationInterval = verificationInterval
        self.child = child; self.api = api; self.baseline = baseline; self.name = name
        self.webToken = webToken; self.streamingToken = streamingToken
        self.transportFactory = transportFactory; self.progress = progress; self.serviceFactory = serviceFactory
        self.publisherFactory = publisherFactory
        let pair = AsyncStream<PlaybackEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        events = pair.stream; continuation = pair.continuation
    }

    public static func launch(executable: URL, key: String, name: String,
        webToken: @escaping @Sendable () async throws -> String,
        streamingToken: @escaping @Sendable () async throws -> String,
        progress: @escaping @Sendable (SoloistEngineStatus) -> Void) async throws -> SoloistEngine {
        let api = SoloistWebAPI()
        do {
            try Task.checkCancellation()
            let child = try await SoloistProcess.start(executable: executable, key: key, name: name, volume: 0)
            let engine = SoloistEngine(child: child, api: api, baseline: [], name: name,
                webToken: webToken, streamingToken: streamingToken, progress: progress,
                publisherFactory: { port, name in try await SoloistBonjourPublisher.publish(port: port, name: name) })
            await engine.begin()
            return engine
        } catch { await api.close(); throw error }
    }

    func begin() async {
        await connect()
        setStatus(.pairing(name))
        let child = self.child
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                if !child.isRunning { await self?.processExited(); return }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    public func preparePairing() async throws {
        let deadline = Date().addingTimeInterval(300)
        let publicationDeadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try Task.checkCancellation()
            guard !stopped, child.isRunning else { throw SoloistPlaybackError.startupFailed }
            if isLocallyReady {
                try await query("get_state")
                setStatus(.prepared)
                return
            }
            if state.authRevision > 0, !state.paired {
                if let failure = child.diagnosticFailure, failure != .discoveryUnavailable || publisherFactory == nil { throw failure }
                if let factory = publisherFactory {
                    if let port = child.pairingPort {
                        do { try await ensurePairingPublication(port: port, factory: factory) }
                        catch { if !isLocallyReady { throw error } }
                    } else if Date() >= publicationDeadline { throw SoloistPlaybackError.discoveryUnavailable }
                }
            }
            setStatus(.pairing(name))
            try await Task.sleep(for: .milliseconds(250))
        }
        throw SoloistPlaybackError.pairingRequired
    }

    private func ensurePairingPublication(port: UInt16, factory: @escaping SoloistPairingPublisherFactory) async throws {
        if let pairingPublication {
            guard await pairingPublication.isPublished else { throw SoloistPlaybackError.discoveryUnavailable }
            return
        }
        let task: Task<any SoloistPairingPublishing, any Error>
        if let publicationTask { task = publicationTask }
        else {
            let name = self.name
            task = Task { try await factory(port, name) }
            publicationTask = task
        }
        do {
            let publication = try await task.value
            guard !stopped, !Task.isCancelled else { await publication.stop(); throw CancellationError() }
            pairingPublication = publication; publicationTask = nil
        } catch {
            if error is CancellationError { throw error }
            throw SoloistPlaybackError.discoveryUnavailable
        }
    }

    public func adopt(initialVolume: Double) async throws {
        try Task.checkCancellation()
        guard isLocallyReady else { throw SoloistPlaybackError.pairingRequired }
        preferredVolume = initialVolume
        let requestedAt = Date()
        try await query("set_volume", values: ["volume": max(0, min(1, initialVolume)) * 100])
        try await query("get_state")
        while (state.observedAt < requestedAt || abs((state.volume ?? -1) - initialVolume) > 0.01)
                && Date().timeIntervalSince(requestedAt) < 20 {
            try Task.checkCancellation()
            guard isLocallyReady else { throw SoloistPlaybackError.unavailable }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard isLocallyReady, state.observedAt >= requestedAt,
              abs((state.volume ?? -1) - initialVolume) <= 0.01 else { throw SoloistPlaybackError.pairingRequired }
        adopted = true
        state.resetPublication()
        let publishAt = Date()
        try await query("get_state")
        while state.observedAt < publishAt && Date().timeIntervalSince(publishAt) < 20 {
            try Task.checkCancellation()
            guard isLocallyReady else { throw SoloistPlaybackError.unavailable }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard isLocallyReady, state.observedAt >= publishAt else { throw SoloistPlaybackError.unavailable }
        try await query("get_queue", values: ["limit": 0])
        if !bootstrapped {
            if state.active, let raw = state.itemURI, let uri = SpotifyURI(raw) {
                continuation.yield(.startupResolved(.restored))
                continuation.yield(.connectionReady(.local(PlaybackIdentity(trackURI: uri, contextURI: state.context?.rawValue))))
            } else {
                continuation.yield(.startupResolved(.nothing))
                continuation.yield(.connectionReady(.remote))
            }
            bootstrapped = true
        }
        setStatus(.ready)
        _ = startDataSetup()
    }

    public func suspendDataServices() async {
        dataAuthorizationPaused = true
        let warmup = servicesWarmup
        revokeDataProof()
        await releaseServices()
        await warmup?.value
    }

    private func revokeDataProof() {
        dataRevision &+= 1
        verifiedRevision = nil; deviceID = nil; verifiedCredentials = nil
        servicesWarmup?.cancel()
        nextServiceAttempt = .distantPast
        if isLocallyReady, adopted { setStatus(.servicesUnavailable) }
    }

    public func retryDataServices() async {
        guard isLocallyReady, adopted else { return }
        dataAuthorizationPaused = false
        await startDataSetup().value
    }

    private func startDataSetup() -> Task<Void, Never> {
        if let servicesWarmup { return servicesWarmup }
        let id = UUID(); servicesWarmupID = id
        let work = Task<Void, Never> { [weak self] in await self?.prepareDataServices(id: id) }
        servicesWarmup = work
        return work
    }

    private func prepareDataServices(id: UUID) async {
        defer { if servicesWarmupID == id { servicesWarmup = nil; servicesWarmupID = nil } }
        guard isLocallyReady, adopted, !dataAuthorizationPaused else { return }
        let revision = state.authRevision, scope = dataRevision
        do {
            if !isVerified {
                nextServiceAttempt = max(nextServiceAttempt, await api.retryDate())
                guard Date() >= nextServiceAttempt, state.active, state.playing else {
                    setStatus(.servicesUnavailable); return
                }
                nextServiceAttempt = Date().addingTimeInterval(30)
                let web = try await webToken(), streaming = try await streamingToken()
                let first = try await api.account(token: web), second = try await api.account(token: streaming)
                guard first == second else { throw SoloistPlaybackError.accountMismatch }
                var proof = SoloistCorrelation(baseline: baseline, name: name)
                for attempt in 0..<2 {
                    try Task.checkCancellation()
                    guard isLocallyReady, adopted, state.authRevision == revision, dataRevision == scope else { return }
                    try await query("get_state")
                    let playback = try await api.playback(token: web)
                    let devices = try await api.devices(token: web)
                    guard isLocallyReady, adopted, state.authRevision == revision, dataRevision == scope else { return }
                    if let id = try proof.observe(state, devices: devices, playback: playback, at: .now) {
                        deviceID = id; verifiedRevision = revision
                        verifiedCredentials = (web, streaming)
                        break
                    }
                    if attempt == 0 { try await Task.sleep(for: verificationInterval) }
                }
            }
            guard isVerified else { throw SoloistPlaybackError.pairingRequired }
            _ = try await dataService()
            if isVerified && adopted { setStatus(.ready) }
        } catch {
            guard !Task.isCancelled, isLocallyReady, adopted, state.authRevision == revision, dataRevision == scope else { return }
            nextServiceAttempt = max(Date().addingTimeInterval(30), await api.retryDate())
            setStatus(.servicesUnavailable)
        }
    }

    private var isLocallyReady: Bool { !stopped && child.isRunning && connected && state.paired }
    private var isVerified: Bool { isLocallyReady && !dataAuthorizationPaused && verifiedCredentials != nil && deviceID != nil && verifiedRevision == state.authRevision }

    private func setStatus(_ status: SoloistEngineStatus) {
        guard latestStatus != status, !stopped else { return }
        latestStatus = status; progress(status)
    }

    private func connect() async {
        guard !stopped, child.isRunning else { return }
        let id = UUID(); socketID = id
        receiver?.cancel()
        await transport?.close()
        await receiver?.value
        guard !stopped else { return }
        let socket = transportFactory(child.endpointURL)
        transport = socket; connected = true
        receiver = Task { [weak self] in
            do {
                for try await frame in socket.messages {
                    try Task.checkCancellation()
                    try await self?.ingest(frame, socketID: id)
                }
            } catch {}
            await self?.socketLost(id)
        }
    }

    private func ingest(_ frame: SoloistFrame, socketID id: UUID) async throws {
        guard id == socketID, !stopped else { return }
        let revision = state.authRevision
        let events = try state.ingest(frame.data, at: frame.receivedAt)
        if adopted || verifiedRevision != nil, state.authRevision != revision {
            revokeDataProof(); adopted = false
            state.resetPublication()
            continuation.yield(.playbackIdle)
            continuation.yield(.activeDeviceChanged(isActive: false))
            continuation.yield(.availableActions(canSeek: false, canNext: false, canPrevious: false))
            if state.paired { try? await query("set_volume", values: ["volume": 0]) }
            await releaseServices()
            setStatus(.pairing(name))
            return
        }
        guard isLocallyReady, adopted else { return }
        for event in events {
            if case let .volumeChanged(volume) = event { preferredVolume = volume }
            continuation.yield(event)
        }
    }

    private func socketLost(_ id: UUID) async {
        guard id == socketID, !stopped else { return }
        connected = false; adopted = false
        revokeDataProof()
        continuation.yield(.playbackRate(0))
        continuation.yield(.availableActions(canSeek: false, canNext: false, canPrevious: false))
        setStatus(.reconnecting)
        await releaseServices()
        // The child may still be audible. Recovery reconnects to it instead of declaring session loss.
    }

    private func poll() async {
        guard !stopped, child.isRunning else { return }
        if !connected { await connect(); return }
        do {
            if state.paired { try await query("get_state") }
            polls += 1
            if polls % 10 == 0, state.paired { try await query("get_queue", values: ["limit": 0]) }
            if bootstrapped, !adopted, verifier == nil, state.paired {
                verifier = Task { [weak self] in await self?.reverify() }
            }
            if adopted, !dataAuthorizationPaused, !isVerified || services == nil, servicesWarmup == nil, state.active, state.playing, Date() >= nextServiceAttempt {
                _ = startDataSetup()
            }
            if isVerified, bootstrapped, !state.active, polls % 30 == 0 {
                let token = try await webToken()
                let playback = try await api.playback(token: token)
                guard !state.active, !stopped else { return }
                if let playback, let raw = playback.uri, let uri = SpotifyURI(raw) {
                    continuation.yield(.remotePlayback(RemotePlayback(deviceName: playback.deviceName,
                        trackURI: uri, track: playback.track, isPlaying: playback.playing,
                        positionMs: Int64(min(playback.positionMs, 31_536_000_000)), durationMs: playback.track?.durationMs ?? 0)))
                } else { continuation.yield(.remotePlayback(nil)) }
            }
        } catch {
            if !state.active { continuation.yield(.remotePlayback(nil)) }
            if error as? SoloistPlaybackError == .rateLimited { setStatus(.servicesUnavailable) }
            // HTTP/service errors do not change the audio owner.
        }
    }

    private func reverify() async {
        defer { verifier = nil }
        do { try await preparePairing(); try await adopt(initialVolume: preferredVolume) }
        catch { if !Task.isCancelled { setStatus(.failed(error as? SoloistPlaybackError ?? .unavailable)) } }
    }

    private func processExited() {
        guard !stopped else { return }
        connected = false
        setStatus(.failed(.startupFailed))
        continuation.yield(.sessionLost(.sessionDisconnected))
    }

    private func query(_ command: String, values: [String: Any] = [:]) async throws {
        guard !stopped, connected, let transport else { throw SoloistPlaybackError.unavailable }
        var frame = values; frame["type"] = "command"; frame["command"] = command
        try await transport.send(JSONSerialization.data(withJSONObject: frame))
    }

    private func control(_ command: String, action: String? = nil, values: [String: Any] = [:], local: Bool = true) async throws {
        guard isLocallyReady, adopted else { throw SoloistPlaybackError.pairingRequired }
        if local && !state.active { throw SoloistPlaybackError.unavailable }
        if let action, !state.actions.contains(action) { throw SoloistPlaybackError.unsupported }
        try await query(command, values: values)
        try await query("get_state")
    }

    public func activateForSetup() async throws {
        guard !stopped, connected, state.paired else { throw SoloistPlaybackError.pairingRequired }
        try await query("activate")
        try await query("play")
        try await query("get_state")
    }

    public func playHere() async throws {
        try await control("activate", local: false)
        try await control("play", local: false)
    }
    public func resume() async throws { try await control("play", action: "play") }
    public func pause() async throws { try await control("pause", action: "pause") }
    public func next() async throws { try await control("skip_next", action: "skip_next") }
    public func previous() async throws { try await control("skip_prev", action: "skip_prev") }
    public func seek(to milliseconds: Int64) async throws {
        try await control("seek", action: "seek", values: ["position_ms": max(0, milliseconds)])
    }
    public func setVolume(_ value: Double) async throws {
        guard value.isFinite else { throw SoloistPlaybackError.invalidState }
        try await control("set_volume", values: ["volume": max(0, min(1, value)) * 100])
    }
    public func selectQueueEntry(_ target: QueueTarget) async throws { throw SoloistPlaybackError.unsupported }
    public func setShuffle(_ enabled: Bool) async throws { try await control("set_shuffle", action: "shuffle", values: ["enabled": enabled]) }
    public func setRepeat(_ mode: RepeatMode) async throws {
        guard state.actions.contains("set_repeat") else { throw SoloistPlaybackError.unsupported }
        try await control("set_repeat_track", values: ["enabled": false])
        try await control("set_repeat_context", values: ["enabled": mode == .context])
        if mode == .track { try await control("set_repeat_track", values: ["enabled": true]) }
    }

    public func load(_ request: PlayRequest) async throws {
        guard isLocallyReady, adopted else { throw SoloistPlaybackError.pairingRequired }
        if request.startTrackURI != nil || request.startPositionMs != 0 {
            guard isVerified, let deviceID else { throw SoloistPlaybackError.pairingRequired }
            let revision = state.authRevision, scope = dataRevision
            let token = try await webToken()
            guard isVerified, state.authRevision == revision, dataRevision == scope else { throw SoloistPlaybackError.pairingRequired }
            guard token == verifiedCredentials?.web else {
                revokeDataProof(); await releaseServices()
                throw SoloistPlaybackError.pairingRequired
            }
            try await api.play(request, deviceID: deviceID, token: token)
            try await query("get_state")
        } else { try await control("play", values: ["uri": request.contextURI.rawValue], local: false) }
    }

    private func dataService() async throws -> any SoloistDataServices {
        guard isVerified, adopted, let credentials = verifiedCredentials else { throw SoloistPlaybackError.pairingRequired }
        let revision = state.authRevision, scope = dataRevision
        let web = try await webToken(), streaming = try await streamingToken()
        guard isVerified, state.authRevision == revision, dataRevision == scope else { throw SoloistPlaybackError.pairingRequired }
        guard web == credentials.web, streaming == credentials.streaming else {
            revokeDataProof(); await releaseServices()
            throw SoloistPlaybackError.pairingRequired
        }
        if let services { return services }
        let task: Task<any SoloistDataServices, any Error>
        let flightID: UUID
        if let flight = servicesFlight, let id = serviceFlightID { task = flight; flightID = id }
        else {
            let factory = serviceFactory
            task = Task { try await factory(credentials.streaming) }
            flightID = UUID(); servicesFlight = task; serviceFlightID = flightID
        }
        let service: any SoloistDataServices
        do { service = try await task.value }
        catch {
            if serviceFlightID == flightID { servicesFlight = nil; serviceFlightID = nil }
            throw error
        }
        guard isVerified, adopted, state.authRevision == revision, dataRevision == scope else {
            await service.shutdown(); throw SoloistPlaybackError.unavailable
        }
        services = service
        if serviceFlightID == flightID { servicesFlight = nil; serviceFlightID = nil }
        try Task.checkCancellation()
        return service
    }

    private func releaseServices() async {
        servicesFlight?.cancel()
        let flight = servicesFlight; servicesFlight = nil; serviceFlightID = nil
        let service = services; services = nil
        await service?.shutdown()
        if let flight, let result = try? await flight.value { await result.shutdown() }
    }

    public func requestRadio(seed: SpotifyURI) async throws -> RadioMix {
        let revision = state.authRevision, scope = dataRevision
        do {
            let result = try await dataService().requestRadio(seed: seed)
            guard isVerified, state.authRevision == revision, dataRevision == scope else { throw RadioFailure.unavailable }
            return result
        }
        catch { if error is PlayerError { await releaseServices() }; throw error as? RadioFailure ?? .unavailable }
    }
    public func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics {
        let revision = state.authRevision, scope = dataRevision
        do {
            let result = try await dataService().requestLyrics(for: track)
            guard isVerified, state.authRevision == revision, dataRevision == scope else { throw LyricFailure.unavailable }
            return result
        }
        catch { if error is PlayerError { await releaseServices() }; throw error as? LyricFailure ?? .unavailable }
    }
    public func requestArtistTopTracks(for track: SpotifyURI, artistIndex: Int) async throws -> ArtistTopTracks {
        let revision = state.authRevision, scope = dataRevision
        do {
            let result = try await dataService().requestArtistTopTracks(for: track, artistIndex: artistIndex)
            guard isVerified, state.authRevision == revision, dataRevision == scope else { throw ArtistTopTracksFailure.unavailable }
            return result
        }
        catch { if error is PlayerError { await releaseServices() }; throw error as? ArtistTopTracksFailure ?? .unavailable }
    }

    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        stopped = true; connected = false
        receiver?.cancel(); poller?.cancel(); watcher?.cancel(); verifier?.cancel(); servicesFlight?.cancel(); servicesWarmup?.cancel()
        let receiver = self.receiver, poller = self.poller, watcher = self.watcher, verifier = self.verifier, warmup = servicesWarmup
        let transport = self.transport, child = self.child, api = self.api
        let services = self.services, flight = servicesFlight, continuation = self.continuation
        let publication = pairingPublication, publishing = publicationTask
        pairingPublication = nil; publicationTask = nil; publishing?.cancel()
        self.services = nil; servicesFlight = nil
        let task = Task {
            await transport?.close()
            await receiver?.value; await poller?.value; await watcher?.value; await verifier?.value; await warmup?.value
            await publication?.stop()
            if let publishing, let pending = try? await publishing.value { await pending.stop() }
            await child.stop()
            await services?.shutdown()
            if let flight, let service = try? await flight.value { await service.shutdown() }
            await api.close()
            continuation.finish()
        }
        shutdownTask = task
        await task.value
    }

    public static func clearStoredSession() throws { try SoloistProcess.clearSession() }
}
