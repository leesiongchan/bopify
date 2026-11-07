import Foundation
import Observation
import os
import BopifyAuth
import BopifyDomain
import BopifyPlayback

enum PlaybackProvider { case soloist, librespot }
enum SoloistSetupPhase: Equatable {
    case idle, authorizing, installing(Double?), checkingAccount, pairing(String), verifying, prepared, ready, limitedServices, reconnecting
    case failed(SoloistSetupFailure)
}
enum SoloistSetupFailure {
    case invalidKey, credentials, authorization, accountMismatch, missingAccountID, pairing, installation, startup, rateLimited
    case processInUse, storage, launch, endpoint
}

struct SoloistLaunchRequest: Sendable {
    let executable: URL
    let key: String
    let progress: @Sendable (SoloistEngineStatus) -> Void
    let available: @MainActor @Sendable (any PreparedPlaybackEngine) -> Void
}

private nonisolated final class SoloistStatusSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    nonisolated func next() -> Int { lock.withLock { count += 1; return count } }
}

/// Coordinates setup without rebuilding the player or replacing the user's Spotify grants.
@MainActor @Observable
final class SoloistPlaybackController {
    private(set) var phase: SoloistSetupPhase = .idle
    private(set) var provider: PlaybackProvider = .librespot
    var hasUsablePlayback: Bool { provider == .soloist && (phase == .ready || phase == .limitedServices) }
    private(set) var hasSavedKey: Bool
    private(set) var isPreparing = false
    private(set) var hasPendingUpdate = false
    var needsAttention: (@MainActor () -> Void)?
    var prefersSoloist: Bool { hasSavedKey || defaults.bool(forKey: "soloist.enabled") }
    private(set) var sessionUsesLibrespot = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keys: any SoloistKeyStoring
    @ObservationIgnored private let authorize: @MainActor () async throws -> Void
    @ObservationIgnored private let install: @MainActor (Bool, @escaping @Sendable (SoloistInstallProgress) -> Void) async throws -> URL
    @ObservationIgnored private let start: @MainActor (SoloistLaunchRequest) async throws -> any PreparedPlaybackEngine
    @ObservationIgnored private let clearSession: @MainActor () throws -> Void
    @ObservationIgnored private var preparation: Task<Void, any Error>?
    @ObservationIgnored private var updating: Task<Void, Never>?
    @ObservationIgnored private var setupEngine: (any PreparedPlaybackEngine)?
    @ObservationIgnored private var preparedEngine: (any PreparedPlaybackEngine)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var deliveredStatus = 0
    @ObservationIgnored private let statusSequence = SoloistStatusSequence()

    init(defaults: UserDefaults = .standard, sessionUsesLibrespot: Bool = false, keys: any SoloistKeyStoring = SoloistKeyStore(),
        authorize: @escaping @MainActor () async throws -> Void,
        webToken: @escaping @Sendable () async throws -> String = { throw PlayerError.authDenied },
        streamingToken: @escaping @Sendable () async throws -> String = { throw PlayerError.authDenied },
        install: @escaping @MainActor (Bool, @escaping @Sendable (SoloistInstallProgress) -> Void) async throws -> URL,
        start: (@MainActor (SoloistLaunchRequest) async throws -> any PreparedPlaybackEngine)? = nil,
        clearSession: @escaping @MainActor () throws -> Void = { try SoloistEngine.clearStoredSession() }) {
        self.sessionUsesLibrespot = sessionUsesLibrespot
        self.defaults = defaults; self.keys = keys; self.authorize = authorize; self.clearSession = clearSession
        hasSavedKey = defaults.bool(forKey: "soloist.hasKey")
        self.install = install
        self.start = start ?? { request in
            let name = "Bopify \(UUID().uuidString.prefix(8))"
            let engine = try await SoloistEngine.launch(executable: request.executable, key: request.key, name: name,
                webToken: webToken, streamingToken: streamingToken, progress: request.progress)
            request.available(engine)
            do { try await engine.preparePairing(); return engine }
            catch { await engine.shutdown(); throw error }
        }
    }

    func enable(key raw: String) async -> Bool {
        guard !isPreparing else { return false }
        generation += 1; let mine = generation
        isPreparing = true
        let task = Task { [self] in
            try Task.checkCancellation()
            guard generation == mine else { throw CancellationError() }
            let key: String
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let saved = try keys.load() { key = saved }
            else { key = try SoloistKeyStore.validated(raw) }
            try keys.save(key)
            hasSavedKey = true; defaults.set(true, forKey: "soloist.hasKey")
            phase = .installing(nil)
            let executable = try await install(setupEngine == nil, installProgress(generation: mine))
            try Task.checkCancellation()
            guard generation == mine else { throw CancellationError() }
            let engine = try await start(launchRequest(executable: executable, key: key, generation: mine))
            guard generation == mine, !Task.isCancelled else { await engine.shutdown(); throw CancellationError() }
            preparedEngine = engine; setupEngine = engine
            phase = .prepared
            defaults.set(true, forKey: "soloist.enabled")
            sessionUsesLibrespot = false
        }
        preparation = task
        defer { if generation == mine { isPreparing = false; preparation = nil } }
        do { try await task.value; return true }
        catch {
            if generation == mine {
                await setupEngine?.shutdown(); setupEngine = nil; preparedEngine = nil
                if error is CancellationError { phase = .idle }
                else if !Task.isCancelled { phase = .failed(Self.failure(error)) }
            }
            return false
        }
    }

    private func reporter(generation mine: Int) -> @Sendable (SoloistEngineStatus) -> Void {
        let sequence = statusSequence
        return { [weak self] status in
            let number = sequence.next()
            Task { @MainActor in
                guard let self, self.generation == mine, number > self.deliveredStatus else { return }
                self.deliveredStatus = number
                switch status {
                case .checkingAccount: self.phase = .checkingAccount
                case let .pairing(name): self.phase = .pairing(name); self.needsAttention?()
                case .verifying: self.phase = .verifying
                case .prepared: self.phase = .prepared
                case .ready: self.phase = .ready
                case .servicesUnavailable: self.phase = .limitedServices
                case .reconnecting: self.phase = .reconnecting
                case let .failed(error): self.phase = .failed(Self.failure(error))
                }
            }
        }
    }

    private func launchRequest(executable: URL, key: String, generation mine: Int) -> SoloistLaunchRequest {
        SoloistLaunchRequest(executable: executable, key: key, progress: reporter(generation: mine),
            available: { [weak self] engine in
                guard let self, self.generation == mine else { return }; self.setupEngine = engine
            })
    }

    func makeEngine(accessToken: String, configuration: PlaybackEngineConfiguration,
        fallback: @escaping @Sendable (String, PlaybackEngineConfiguration) async throws -> any ManagedPlaybackEngine) async throws -> any ManagedPlaybackEngine {
        guard prefersSoloist, !sessionUsesLibrespot else {
            provider = .librespot
            return try await fallback(accessToken, configuration)
        }
        if preparedEngine == nil { generation += 1 }
        let mine = generation
        var candidate = preparedEngine
        preparedEngine = nil
        do {
            if candidate == nil {
                guard let key = try keys.load() else { throw SoloistKeyError.unavailable }
                phase = .installing(nil)
                let executable = try await install(true, installProgress(generation: mine))
                try Task.checkCancellation()
                guard generation == mine else { throw CancellationError() }
                candidate = try await start(launchRequest(executable: executable, key: key, generation: mine))
            }
            guard let engine = candidate, generation == mine, !Task.isCancelled else { throw CancellationError() }
            setupEngine = engine
            // Recovery calls this factory only after joining the outgoing engine.
            try await engine.adopt(initialVolume: configuration.snapshot?.volume ?? configuration.initialVolume ?? 0.5)
            guard generation == mine, !Task.isCancelled else { throw CancellationError() }
            provider = .soloist
            switch phase {
            case .idle, .prepared, .installing, .checkingAccount, .pairing, .verifying: phase = .ready
            default: break
            }
            scheduleUpdates(generation: mine)
            return engine
        } catch {
            if let candidate { await candidate.shutdown() }
            else if generation == mine { await setupEngine?.shutdown() }
            if generation == mine { setupEngine = nil }
            if Task.isCancelled || generation != mine || error is CancellationError { throw CancellationError() }
            generation += 1
            phase = .failed(Self.failure(error)); provider = .librespot
            needsAttention?()
            let inactive = PlaybackEngineConfiguration(deviceID: configuration.deviceID, startup: .recovery,
                initialVolume: configuration.initialVolume)
            return try await fallback(accessToken, inactive)
        }
    }

    private func installProgress(generation mine: Int) -> @Sendable (SoloistInstallProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                switch progress {
                case let .downloading(received, total):
                    if case .installing = self.phase { self.phase = .installing(total.map { min(1, Double(received) / Double(max(1, $0))) }) }
                case .updateReady: self.hasPendingUpdate = true
                default: break
                }
            }
        }
    }

    private func scheduleUpdates(generation mine: Int) {
        updating?.cancel()
        updating = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(86_400)) } catch { return }
                guard let self, self.generation == mine, self.provider == .soloist else { return }
                do { _ = try await self.install(false, self.installProgress(generation: mine)) }
                catch { BopifyLog.playback.notice("Soloist update deferred; current audio preserved") }
            }
        }
    }

    func playHere() async {
        do { try await setupEngine?.activateForSetup() }
        catch { phase = .failed(Self.failure(error)) }
    }

    func retryDataServices() async {
        guard provider == .soloist, let engine = setupEngine else { return }
        let mine = generation
        await engine.suspendDataServices()
        do {
            try await authorize()
            guard generation == mine, provider == .soloist else { return }
            await engine.retryDataServices()
        } catch { if generation == mine, provider == .soloist { phase = .limitedServices } }
    }

    func useLibrespotForSession() async {
        generation += 1
        sessionUsesLibrespot = true; provider = .librespot
        preparation?.cancel(); updating?.cancel()
        let preparation = self.preparation; self.preparation = nil
        let owned = setupEngine ?? preparedEngine; setupEngine = nil; preparedEngine = nil
        _ = await preparation?.result
        await owned?.shutdown()
        isPreparing = false; phase = .idle
    }

    func stop() async {
        generation += 1
        preparation?.cancel(); updating?.cancel()
        let owned = setupEngine ?? preparedEngine; setupEngine = nil; preparedEngine = nil
        _ = await preparation?.result
        await owned?.shutdown()
        preparation = nil; updating = nil; isPreparing = false
    }

    func clearCredentials() throws {
        defaults.set(false, forKey: "soloist.enabled")
        try keys.clear()
        try clearSession()
        hasSavedKey = false; defaults.removeObject(forKey: "soloist.hasKey")
        provider = .librespot; phase = .idle
    }

    private static func failure(_ error: any Error) -> SoloistSetupFailure {
        if let startup = error as? SoloistStartupError {
            switch startup {
            case .processInUse:
                BopifyLog.playback.error("Soloist startup blocked reason=processInUse")
                return .processInUse
            case .storageUnavailable:
                BopifyLog.playback.error("Soloist startup blocked reason=storageUnavailable")
                return .storage
            case .launchFailed: return .launch
            case .endpointUnavailable: return .endpoint
            case .exited(10): return .installation
            case .exited: return .startup
            }
        }
        if error is SoloistInstallationError { return .installation }
        if let player = error as? PlayerError, player == .authDenied || player == .authExpired || player == .credentialCorrupt { return .authorization }
        if error as? LibraryError == .authorizationRequired { return .authorization }
        if let key = error as? SoloistKeyError { return key == .invalid ? .invalidKey : .credentials }
        switch error as? SoloistPlaybackError {
        case .accountMismatch: return .accountMismatch
        case .missingAccountID: return .missingAccountID
        case .authorizationRequired: return .authorization
        case .ambiguousDevice, .pairingRequired: return .pairing
        case .rateLimited: return .rateLimited
        default: return .startup
        }
    }
}
