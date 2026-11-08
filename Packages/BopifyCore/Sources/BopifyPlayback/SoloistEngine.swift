import Foundation
import BopifyDomain
import os

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
    private let dataToken: @Sendable () async throws -> String
    private let authorizeContinuation: @Sendable () async throws -> Bool
    private let transportFactory: @Sendable (URL) -> any SoloistTransport
    private let progress: @Sendable (SoloistEngineStatus) -> Void
    private let publisherFactory: SoloistPairingPublisherFactory?
    private let pairingNow: @Sendable () -> Date
    private var pairingPublication: (any SoloistPairingPublishing)?
    private var publicationTask: Task<any SoloistPairingPublishing, any Error>?
    private var transport: (any SoloistTransport)?
    private var receiver: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var verifier: Task<Void, Never>?
    private var socketID = UUID()
    private var loadRevision: UInt64 = 0
    private var queueContinuationTask: Task<Void, Never>?
    private var queueContinuationSocket: (revision: UInt64, transport: any SoloistTransport)?
    private struct QueueContinuationIdentity: Sendable {
        let revision: UInt64
        let authRevision: UInt64
        let socketID: UUID
        let trackURI: String
        let occurrence: UInt64
    }
    private var queueContinuationIdentity: QueueContinuationIdentity?
    private var installingContinuationRevision: UInt64?
    private var state = SoloistState()
    private var connected = false
    private var stopped = false
    private var shutdownTask: Task<Void, Never>?
    private var verifiedRevision: UInt64?
    private var deviceID: String?
    private var verifiedCredentials: (web: String, streaming: String)?
    private struct DataCredentials: Equatable, Sendable {
        let library: String
        let streaming: String
    }
    private var dataCredentials: DataCredentials?
    private var dataAccountID: String?
    private var dataRevision: UInt64 = 0
    private var dataAuthorizationPaused = false
    private var services: (any SoloistDataServices)?
    private var servicesFlight: Task<any SoloistDataServices, any Error>?
    private var serviceFlightID: UUID?
    private var serviceFlightCredentials: DataCredentials?
    private var servicesWarmup: Task<Void, Never>?
    private var servicesWarmupID: UUID?
    private var nextServiceAttempt = Date.distantPast
    private var nextPlaybackAttempt = Date.distantPast
    private let verificationInterval: Duration
    private var adopted = false
    private let serviceFactory: @Sendable (String, String) async throws -> any SoloistDataServices
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
        serviceFactory: @escaping @Sendable (String, String) async throws -> any SoloistDataServices = {
            try await LibrespotServices(accessToken: $0, expectedUsername: $1)
        },
        progress: @escaping @Sendable (SoloistEngineStatus) -> Void,
        verificationInterval: Duration = .seconds(5), publisherFactory: SoloistPairingPublisherFactory? = nil,
        dataToken: (@Sendable () async throws -> String)? = nil,
        pairingNow: @escaping @Sendable () -> Date = { .now },
        authorizeContinuation: @escaping @Sendable () async throws -> Bool = { false }) {
        self.verificationInterval = verificationInterval
        self.child = child; self.api = api; self.baseline = baseline; self.name = name
        self.webToken = webToken; self.streamingToken = streamingToken
        self.dataToken = dataToken ?? webToken
        self.authorizeContinuation = authorizeContinuation
        self.transportFactory = transportFactory; self.progress = progress; self.serviceFactory = serviceFactory
        self.publisherFactory = publisherFactory
        self.pairingNow = pairingNow
        let pair = AsyncStream<PlaybackEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        events = pair.stream; continuation = pair.continuation
    }

    public static func launch(executable: URL, key: String, name: String,
        webToken: @escaping @Sendable () async throws -> String,
        streamingToken: @escaping @Sendable () async throws -> String,
        dataToken: (@Sendable () async throws -> String)? = nil,
        authorizeContinuation: @escaping @Sendable () async throws -> Bool = { false },
        progress: @escaping @Sendable (SoloistEngineStatus) -> Void) async throws -> SoloistEngine {
        let api = SoloistWebAPI()
        do {
            try Task.checkCancellation()
            let child = try await SoloistProcess.start(executable: executable, key: key, name: name, volume: 0)
            let engine = SoloistEngine(child: child, api: api, baseline: [], name: name,
                webToken: webToken, streamingToken: streamingToken, progress: progress,
                publisherFactory: { port, name in try await SoloistBonjourPublisher.publish(port: port, name: name) },
                dataToken: dataToken, authorizeContinuation: authorizeContinuation)
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
        let publicationDeadline = pairingNow().addingTimeInterval(10)
        while true {
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
                    } else if pairingNow() >= publicationDeadline { throw SoloistPlaybackError.discoveryUnavailable }
                }
            }
            setStatus(.pairing(name))
            try await Task.sleep(for: .milliseconds(250))
        }
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
        dataCredentials = nil
        dataAccountID = nil
        revokePlaybackProof()
        servicesWarmup?.cancel()
        nextServiceAttempt = .distantPast
        if isLocallyReady, adopted { setStatus(.servicesUnavailable) }
    }

    private func revokePlaybackProof() {
        verifiedRevision = nil; deviceID = nil; verifiedCredentials = nil
        nextPlaybackAttempt = .distantPast
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
            _ = try await dataService()
            guard dataScopeIsCurrent(revision: revision, scope: scope) else { return }
            nextServiceAttempt = .distantPast
            setStatus(.ready)
        } catch {
            guard !Task.isCancelled, isLocallyReady, adopted, state.authRevision == revision, dataRevision == scope else { return }
            reportDataFailure(error, operation: "prepare")
            nextServiceAttempt = max(Date().addingTimeInterval(30), await api.retryDate())
            setStatus(.servicesUnavailable)
            return
        }
        await preparePlaybackProof()
    }

    /// Device correlation authorizes Web API playback and remote observation,
    /// independently of the already-authorized read-only metadata session.
    private func preparePlaybackProof() async {
        guard isDataAuthorized, !isVerified, state.active, state.playing, Date() >= nextPlaybackAttempt,
              let credentials = dataCredentials else { return }
        let revision = state.authRevision, scope = dataRevision
        nextPlaybackAttempt = Date().addingTimeInterval(30)
        do {
            let web = try await webToken(), streaming = try await streamingToken()
            guard streaming == credentials.streaming else { throw SoloistPlaybackError.pairingRequired }
            let account = try await api.account(token: web)
            guard account == dataAccountID else { throw SoloistPlaybackError.accountMismatch }
            var proof = SoloistCorrelation(baseline: baseline, name: name)
            for attempt in 0..<2 {
                try Task.checkCancellation()
                guard dataScopeIsCurrent(revision: revision, scope: scope) else { return }
                try await query("get_state")
                let playback = try await api.playback(token: web)
                let devices = try await api.devices(token: web)
                guard dataScopeIsCurrent(revision: revision, scope: scope) else { return }
                if let id = try proof.observe(state, devices: devices, playback: playback, at: .now) {
                    guard try await readDataCredentials(revision: revision, scope: scope) == credentials else {
                        throw SoloistPlaybackError.pairingRequired
                    }
                    guard try await webToken() == web, dataScopeIsCurrent(revision: revision, scope: scope) else {
                        throw SoloistPlaybackError.pairingRequired
                    }
                    deviceID = id; verifiedRevision = revision
                    verifiedCredentials = (web, streaming)
                    return
                }
                if attempt == 0 { try await Task.sleep(for: verificationInterval) }
            }
        } catch {
            guard !Task.isCancelled, dataScopeIsCurrent(revision: revision, scope: scope) else { return }
            revokePlaybackProof()
            nextPlaybackAttempt = max(Date().addingTimeInterval(30), await api.retryDate())
            BopifyLog.playback.debug("Soloist optional Web playback proof unavailable")
        }
    }

    private var isLocallyReady: Bool { !stopped && child.isRunning && connected && state.paired }
    private var isDataAuthorized: Bool { isLocallyReady && adopted && !dataAuthorizationPaused && dataCredentials != nil }
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
        // A fresh connection must bootstrap discovery even if the initial push is missed.
        do { try await query("get_auth_state") }
        catch { await socketLost(id) }
    }

    private func ingest(_ frame: SoloistFrame, socketID id: UUID) async throws {
        guard id == socketID, !stopped else { return }
        let revision = state.authRevision
        let events = try state.ingest(frame.data, at: frame.receivedAt)
        if adopted || verifiedRevision != nil, state.authRevision != revision {
            BopifyLog.playback.info("Soloist data authorization revoked reason=authenticationChanged")
            _ = await cancelQueueContinuation()
            revokeDataProof(); adopted = false
            state.resetPublication()
            continuation.yield(.playbackIdle)
            continuation.yield(.activeDeviceChanged(isActive: false))
            continuation.yield(.availableActions(canSeek: false, canNext: false, canPrevious: false))
            continuation.yield(.availablePlaybackOptions(canShuffle: false, canRepeat: false))
            if state.paired { try? await query("set_volume", values: ["volume": 0]) }
            await releaseServices()
            setStatus(.pairing(name))
            return
        }
        if let identity = queueContinuationIdentity, !queueContinuationIsCurrent(identity, allowingInstallation: true) {
            _ = await cancelQueueContinuation()
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
        _ = await cancelQueueContinuation()
        revokeDataProof()
        continuation.yield(.playbackRate(0))
        continuation.yield(.availableActions(canSeek: false, canNext: false, canPrevious: false))
        continuation.yield(.availablePlaybackOptions(canShuffle: false, canRepeat: false))
        setStatus(.reconnecting)
        await releaseServices()
        // The child may still be audible. Recovery reconnects to it instead of declaring session loss.
    }

    func poll() async {
        guard !stopped, child.isRunning else { return }
        if !connected { await connect(); return }
        do {
            if state.paired { try await query("get_state") }
            polls += 1
            if polls % 10 == 0, state.paired { try await query("get_queue", values: ["limit": 0]) }
            if bootstrapped, !adopted, verifier == nil, state.paired {
                verifier = Task { [weak self] in await self?.reverify() }
            }
            if adopted, !dataAuthorizationPaused, servicesWarmup == nil, Date() >= nextServiceAttempt,
               !isDataAuthorized || services == nil || (!isVerified && state.active && state.playing && Date() >= nextPlaybackAttempt) {
                _ = startDataSetup()
            }
            if isVerified, bootstrapped, !state.active, polls % 30 == 0 {
                let revision = state.authRevision, scope = dataRevision
                let token = try await webToken(), streaming = try await streamingToken()
                guard isVerified, state.authRevision == revision, dataRevision == scope, !state.active else { return }
                guard token == verifiedCredentials?.web, streaming == verifiedCredentials?.streaming else {
                    revokePlaybackProof(); continuation.yield(.remotePlayback(nil)); return
                }
                let playback = try await api.playback(token: token)
                guard isVerified, state.authRevision == revision, dataRevision == scope, !state.active else { return }
                let currentWeb = try await webToken(), currentStreaming = try await streamingToken()
                guard isVerified, state.authRevision == revision, dataRevision == scope, !state.active else { return }
                guard currentWeb == token, currentStreaming == streaming else {
                    revokePlaybackProof(); continuation.yield(.remotePlayback(nil)); return
                }
                if let playback, let raw = playback.uri, let uri = SpotifyURI(raw) {
                    continuation.yield(.remotePlayback(RemotePlayback(deviceName: playback.deviceName,
                        trackURI: uri, track: playback.track, isPlaying: playback.playing,
                        positionMs: Int64(min(playback.positionMs, 31_536_000_000)), durationMs: playback.track?.durationMs ?? 0)))
                } else { continuation.yield(.remotePlayback(nil)) }
            }
        } catch {
            if !state.active { continuation.yield(.remotePlayback(nil)) }
            if error as? SoloistPlaybackError == .rateLimited, services == nil { setStatus(.servicesUnavailable) }
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
        guard isLocallyReady, adopted else {
            BopifyLog.playback.error("Soloist command rejected command=\(command, privacy: .public) reason=pairingRequired")
            throw SoloistPlaybackError.pairingRequired
        }
        if local && !state.active {
            BopifyLog.playback.error("Soloist command rejected command=\(command, privacy: .public) reason=inactive")
            throw SoloistPlaybackError.unavailable
        }
        if let action, !state.actions.contains(action) {
            let actions = state.actions.sorted().joined(separator: ",")
            BopifyLog.playback.error("Soloist command rejected command=\(command, privacy: .public) reason=unsupported actions=\(actions, privacy: .public)")
            throw SoloistPlaybackError.unsupported
        }
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
    public func pause() async throws { _ = await cancelQueueContinuation(); try await control("pause", action: "pause") }
    public func next() async throws { _ = await cancelQueueContinuation(); try await control("skip_next", action: "skip_next") }
    public func previous() async throws { _ = await cancelQueueContinuation(); try await control("skip_prev", action: "skip_prev") }
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
        let disabled = mode == .track ? "set_repeat_context" : "set_repeat_track"
        let enabled = mode == .track ? "set_repeat_track" : "set_repeat_context"
        try await control(disabled, action: "set_repeat", values: ["enabled": false])
        try await control(enabled, action: "set_repeat", values: ["enabled": mode != .off])
    }

    public func load(_ request: PlayRequest) async throws {
        let revision = await cancelQueueContinuation()
        guard revision == loadRevision else { throw CancellationError() }
        guard isLocallyReady, adopted else { throw SoloistPlaybackError.pairingRequired }
        if !request.followingTrackURIs.isEmpty {
            guard request.contextURI.kind == .track, request.startTrackURI == nil, request.startPositionMs == 0,
                  request.followingTrackURIs.count <= 50, request.followingTrackURIs.allSatisfy({ $0.kind == .track }) else {
                throw SoloistPlaybackError.unsupported
            }
            var seen: Set<SpotifyURI> = [request.contextURI]
            let following = request.followingTrackURIs.filter { seen.insert($0).inserted }
            try await startQueueContinuation(selected: request.contextURI, following: following, revision: revision)
            return
        }
        if request.startTrackURI != nil || request.startPositionMs != 0 {
            guard isVerified, let deviceID else { throw SoloistPlaybackError.pairingRequired }
            let revision = state.authRevision, scope = dataRevision
            let token = try await webToken(), streaming = try await streamingToken()
            guard isVerified, state.authRevision == revision, dataRevision == scope else { throw SoloistPlaybackError.pairingRequired }
            guard token == verifiedCredentials?.web, streaming == verifiedCredentials?.streaming else {
                revokePlaybackProof()
                throw SoloistPlaybackError.pairingRequired
            }
            try await api.play(request, deviceID: deviceID, token: token)
            guard isVerified, state.authRevision == revision, dataRevision == scope else { throw SoloistPlaybackError.pairingRequired }
            try await query("get_state")
        } else { try await control("play", values: ["uri": request.contextURI.rawValue], local: false) }
    }

    @discardableResult private func cancelQueueContinuation() async -> UInt64 {
        loadRevision &+= 1
        let revision = loadRevision
        let task = queueContinuationTask, socket = queueContinuationSocket?.transport
        queueContinuationTask = nil; queueContinuationSocket = nil; queueContinuationIdentity = nil; installingContinuationRevision = nil
        task?.cancel()
        await socket?.close()
        await task?.value
        return revision
    }

    private func queueContinuationIsCurrent(_ identity: QueueContinuationIdentity, allowingInstallation: Bool = false) -> Bool {
        let ownReplacement = allowingInstallation && installingContinuationRevision == identity.revision
        return isLocallyReady && adopted && loadRevision == identity.revision && state.authRevision == identity.authRevision
            && socketID == identity.socketID && state.active && state.itemURI == identity.trackURI
            && state.playbackStatus != "paused" && state.playbackStatus != "idle"
            && (state.trackOccurrence == identity.occurrence || ownReplacement)
    }

    private func startQueueContinuation(selected: SpotifyURI, following: [SpotifyURI], revision: UInt64) async throws {
        let authentication = state.authRevision, socketGeneration = socketID
        let originalOccurrence = state.trackOccurrence, originalEvent = state.trackEventRevision
        let requestedAt = Date()
        let socket = transportFactory(child.endpointURL)
        queueContinuationSocket = (revision, socket)
        do {
            try await SoloistAcknowledgedCommand(transport: socket).send("play", uri: selected.rawValue)
            try await query("get_state")
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while true {
                try Task.checkCancellation()
                guard isLocallyReady, adopted, loadRevision == revision, state.authRevision == authentication,
                      socketID == socketGeneration else { throw CancellationError() }
                // Snapshot and granular event can arrive in either order. Both must
                // identify this selection before its replacement context is installed.
                let selectedEvent = state.trackEventRevision != originalEvent && state.lastTrackEventURI == selected.rawValue
                if state.active, state.itemURI == selected.rawValue, state.observedAt >= requestedAt, selectedEvent { break }
                if state.trackOccurrence != originalOccurrence, state.itemURI != selected.rawValue { throw CancellationError() }
                guard ContinuousClock.now < deadline else { throw SoloistPlaybackError.unavailable }
                try await Task.sleep(for: .milliseconds(20))
            }
            let identity = QueueContinuationIdentity(revision: revision, authRevision: authentication, socketID: socketGeneration,
                trackURI: selected.rawValue, occurrence: state.trackOccurrence)
            await socket.close()
            guard queueContinuationIsCurrent(identity) else { throw CancellationError() }
            queueContinuationSocket = nil
            guard !following.isEmpty else { return }
            queueContinuationIdentity = identity
            queueContinuationTask = Task { [weak self] in await self?.installQueueContinuation(following, identity: identity) }
        } catch {
            await socket.close()
            if queueContinuationSocket?.revision == revision { queueContinuationSocket = nil }
            reportDataFailure(error, operation: "queueSelection")
            throw error
        }
    }

    private func installQueueContinuation(_ tracks: [SpotifyURI], identity: QueueContinuationIdentity) async {
        defer {
            if queueContinuationIdentity?.revision == identity.revision {
                queueContinuationTask = nil; queueContinuationIdentity = nil; installingContinuationRevision = nil
            }
        }
        do {
            try Task.checkCancellation()
            guard queueContinuationIsCurrent(identity) else { throw CancellationError() }
            let changedGrant = try await authorizeContinuation()
            try Task.checkCancellation()
            guard queueContinuationIsCurrent(identity) else { throw CancellationError() }
            if changedGrant {
                await suspendDataServices()
                try Task.checkCancellation()
                guard queueContinuationIsCurrent(identity) else { throw CancellationError() }
                dataAuthorizationPaused = false
                _ = startDataSetup()
            } else if servicesWarmup == nil, !dataAuthorizationPaused, Date() >= nextServiceAttempt {
                _ = startDataSetup()
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !isVerified {
                try Task.checkCancellation()
                guard queueContinuationIsCurrent(identity) else { throw CancellationError() }
                guard ContinuousClock.now < deadline else { throw SoloistPlaybackError.pairingRequired }
                try await Task.sleep(for: .milliseconds(20))
            }
            let token = try await webToken(), streaming = try await streamingToken()
            try Task.checkCancellation()
            guard queueContinuationIsCurrent(identity), isVerified, let deviceID else { throw CancellationError() }
            guard token == verifiedCredentials?.web, streaming == verifiedCredentials?.streaming else {
                revokePlaybackProof()
                throw SoloistPlaybackError.pairingRequired
            }
            guard let selected = SpotifyURI(identity.trackURI) else { throw SoloistPlaybackError.invalidState }
            let request = PlayRequest(contextURI: selected, startPositionMs: state.position(at: .now), followingTrackURIs: tracks)
            // Replacing the automatic context may report the selected song again.
            // Once dispatched, its own echo must not cancel the HTTP operation.
            installingContinuationRevision = identity.revision
            try await api.play(request, deviceID: deviceID, token: token)
            try Task.checkCancellation()
            guard queueContinuationIsCurrent(identity, allowingInstallation: true), isVerified else { throw CancellationError() }
            let currentToken = try await webToken(), currentStreaming = try await streamingToken()
            guard queueContinuationIsCurrent(identity, allowingInstallation: true), isVerified else { throw CancellationError() }
            guard currentToken == token, currentStreaming == streaming else {
                revokePlaybackProof()
                throw SoloistPlaybackError.pairingRequired
            }
        } catch {
            if !(error is CancellationError), queueContinuationIsCurrent(identity, allowingInstallation: true) {
                reportDataFailure(error, operation: "queueContinuation")
                continuation.yield(.commandRejected("unavailable"))
            }
        }
    }

    private func dataService() async throws -> any SoloistDataServices {
        let revision = state.authRevision, scope = dataRevision
        let credentials = try await readDataCredentials(revision: revision, scope: scope)
        if dataCredentials.map({ $0 != credentials }) == true || serviceFlightCredentials.map({ $0 != credentials }) == true {
            revokeDataProof(); await releaseServices()
            throw SoloistPlaybackError.pairingRequired
        }
        if let services, dataCredentials == credentials { return services }
        let task: Task<any SoloistDataServices, any Error>
        let flightID: UUID
        if let flight = servicesFlight, let id = serviceFlightID { task = flight; flightID = id }
        else {
            task = Task { try await self.createDataService(credentials: credentials, revision: revision, scope: scope) }
            flightID = UUID(); servicesFlight = task; serviceFlightID = flightID
            serviceFlightCredentials = credentials
        }
        let service: any SoloistDataServices
        defer {
            if serviceFlightID == flightID { servicesFlight = nil; serviceFlightID = nil; serviceFlightCredentials = nil }
        }
        service = try await task.value
        guard dataScopeIsCurrent(revision: revision, scope: scope) else { throw SoloistPlaybackError.unavailable }
        try await validateDataCredentials(credentials, revision: revision, scope: scope)
        try Task.checkCancellation()
        return service
    }

    private func dataScopeIsCurrent(revision: UInt64, scope: UInt64) -> Bool {
        isLocallyReady && adopted && !dataAuthorizationPaused && state.authRevision == revision && dataRevision == scope
    }

    private func readDataCredentials(revision: UInt64, scope: UInt64) async throws -> DataCredentials {
        guard dataScopeIsCurrent(revision: revision, scope: scope) else { throw SoloistPlaybackError.pairingRequired }
        let library: String
        do { library = try await dataToken() }
        catch { reportDataFailure(error, operation: "libraryCredential"); throw error }
        guard dataScopeIsCurrent(revision: revision, scope: scope) else { throw SoloistPlaybackError.pairingRequired }
        let streaming: String
        do { streaming = try await streamingToken() }
        catch { reportDataFailure(error, operation: "streamingCredential"); throw error }
        guard dataScopeIsCurrent(revision: revision, scope: scope) else { throw SoloistPlaybackError.pairingRequired }
        return DataCredentials(library: library, streaming: streaming)
    }

    private func createDataService(credentials: DataCredentials, revision: UInt64, scope: UInt64) async throws -> any SoloistDataServices {
        try Task.checkCancellation()
        let libraryAccount: SoloistAccountProfile
        do { libraryAccount = try await api.accountProfile(token: credentials.library) }
        catch { reportDataFailure(error, operation: "libraryAccount"); throw error }
        guard dataScopeIsCurrent(revision: revision, scope: scope) else { throw SoloistPlaybackError.pairingRequired }
        guard try await readDataCredentials(revision: revision, scope: scope) == credentials else { throw SoloistPlaybackError.pairingRequired }
        try Task.checkCancellation()
        let service: any SoloistDataServices
        // Native login checks the authenticated username before exposing metadata.
        // The playback client's token must never be sent to the Web API.
        do { service = try await serviceFactory(credentials.streaming, libraryAccount.username) }
        catch { reportDataFailure(error, operation: "metadataSession"); throw error }
        do {
            try Task.checkCancellation()
            guard try await readDataCredentials(revision: revision, scope: scope) == credentials else { throw SoloistPlaybackError.pairingRequired }
            try Task.checkCancellation()
            dataCredentials = credentials
            dataAccountID = libraryAccount.accountID
            services = service
            return service
        } catch { await service.shutdown(); throw error }
    }

    private func validateDataCredentials(_ credentials: DataCredentials, revision: UInt64, scope: UInt64) async throws {
        guard try await readDataCredentials(revision: revision, scope: scope) == credentials else {
            revokeDataProof(); await releaseServices()
            throw SoloistPlaybackError.pairingRequired
        }
    }

    private func releaseServices() async {
        servicesFlight?.cancel()
        let flight = servicesFlight; servicesFlight = nil; serviceFlightID = nil; serviceFlightCredentials = nil
        let service = services; services = nil
        await service?.shutdown()
        if let flight, let result = try? await flight.value { await result.shutdown() }
    }

    public func requestRadio(seed: SpotifyURI) async throws -> RadioMix {
        let revision = state.authRevision, scope = dataRevision
        do {
            let service = try await dataService()
            guard let credentials = dataCredentials else { throw RadioFailure.unavailable }
            let result = try await service.requestRadio(seed: seed)
            try await validateDataCredentials(credentials, revision: revision, scope: scope)
            return result
        }
        catch {
            reportDataFailure(error, operation: "radio")
            if error is PlayerError, state.authRevision == revision, dataRevision == scope { await releaseServices() }
            throw error as? RadioFailure ?? .unavailable
        }
    }
    public func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics {
        let revision = state.authRevision, scope = dataRevision
        do {
            let service = try await dataService()
            guard let credentials = dataCredentials else { throw LyricFailure.unavailable }
            let result = try await service.requestLyrics(for: track)
            try await validateDataCredentials(credentials, revision: revision, scope: scope)
            return result
        }
        catch {
            reportDataFailure(error, operation: "lyrics")
            if error is PlayerError, state.authRevision == revision, dataRevision == scope { await releaseServices() }
            throw error as? LyricFailure ?? .unavailable
        }
    }
    public func requestArtistTopTracks(for track: SpotifyURI, artistIndex: Int) async throws -> ArtistTopTracks {
        let revision = state.authRevision, scope = dataRevision
        do {
            let service = try await dataService()
            guard let credentials = dataCredentials else { throw ArtistTopTracksFailure.unavailable }
            let result = try await service.requestArtistTopTracks(for: track, artistIndex: artistIndex)
            try await validateDataCredentials(credentials, revision: revision, scope: scope)
            return result
        }
        catch {
            reportDataFailure(error, operation: "artistTopTracks")
            if error is PlayerError, state.authRevision == revision, dataRevision == scope { await releaseServices() }
            throw error as? ArtistTopTracksFailure ?? .unavailable
        }
    }

    private func reportDataFailure(_ error: any Error, operation: String) {
        let reason: String
        switch error {
        case let failure as SoloistPlaybackError: reason = "soloist.\(failure)"
        case let failure as PlayerError: reason = "player.\(failure)"
        case let failure as LibraryError:
            switch failure {
            case .authorizationRequired: reason = "library.authorizationRequired"
            case .forbidden: reason = "library.forbidden"
            case .rateLimited: reason = "library.rateLimited"
            case .quotaExceeded: reason = "library.quotaExceeded"
            default: reason = "library.unavailable"
            }
        case let failure as RadioFailure: reason = "radio.\(failure.rawValue)"
        case let failure as LyricFailure: reason = "lyrics.\(failure.rawValue)"
        case let failure as ArtistTopTracksFailure: reason = "artistTopTracks.\(failure.rawValue)"
        case is CancellationError: return
        default: reason = "unavailable"
        }
        BopifyLog.playback.error("Soloist data request failed operation=\(operation, privacy: .public) reason=\(reason, privacy: .public)")
    }

    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        stopped = true; connected = false
        loadRevision &+= 1
        let queueWork = queueContinuationTask, queueSocket = queueContinuationSocket?.transport
        queueContinuationTask = nil; queueContinuationSocket = nil; queueContinuationIdentity = nil; installingContinuationRevision = nil
        queueWork?.cancel()
        receiver?.cancel(); poller?.cancel(); watcher?.cancel(); verifier?.cancel(); servicesFlight?.cancel(); servicesWarmup?.cancel()
        let receiver = self.receiver, poller = self.poller, watcher = self.watcher, verifier = self.verifier, warmup = servicesWarmup
        let transport = self.transport, child = self.child, api = self.api
        let services = self.services, flight = servicesFlight, continuation = self.continuation
        let publication = pairingPublication, publishing = publicationTask
        pairingPublication = nil; publicationTask = nil; publishing?.cancel()
        self.services = nil; servicesFlight = nil
        let task = Task {
            await queueSocket?.close()
            await queueWork?.value
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
