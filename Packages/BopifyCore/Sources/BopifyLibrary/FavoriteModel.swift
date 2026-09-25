import Foundation
import Observation
import os
import BopifyDomain

@MainActor @Observable
public final class FavoriteModel {
    public private(set) var uri: SpotifyURI?
    public private(set) var saved: Bool?
    public private(set) var isPending = false
    public private(set) var error: LibraryError?
    @ObservationIgnored private let service: any LibraryService
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pending: Task<Void, Never>?

    public init(service: any LibraryService) { self.service = service }

    public func clear() {
        generation += 1
        pending?.cancel()
        pending = nil
        uri = nil
        saved = nil
        error = nil
        isPending = false
        BopifyLog.library.debug("favorite state cleared")
    }

    public func select(_ selected: SpotifyURI?) async {
        if selected == uri && isPending { return }
        clear()
        guard let selected else { return }
        uri = selected
        guard selected.kind == .track else { error = .unavailable; return }
        let requestGeneration = generation
        isPending = true
        let task = Task {
            defer { finish(requestGeneration) }
            do {
                let value = try await service.savedState(for: selected)
                guard isCurrent(requestGeneration, selected) else { return }
                saved = value
            } catch {
                guard isCurrent(requestGeneration, selected) else { return }
                self.error = error as? LibraryError ?? .unavailable
            }
        }
        pending = task
        await task.value
    }

    public func toggle() async {
        guard let uri, let confirmed = saved, !isPending else { return }
        let requestGeneration = generation
        saved = !confirmed
        isPending = true
        error = nil
        BopifyLog.library.debug("favorite mutation started")
        let task = Task {
            defer { finish(requestGeneration) }
            do {
                if confirmed { try await service.remove(uri) }
                else { try await service.save(uri) }
            } catch {
                guard isCurrent(requestGeneration, uri) else { return }
                let failure = error as? LibraryError ?? .unavailable
                if failure != .unavailable && failure != .invalidResponse {
                    saved = confirmed
                    self.error = failure
                    return
                }
                // A lost response cannot tell us whether Spotify applied the mutation.
            }
            guard isCurrent(requestGeneration, uri) else { return }
            do {
                let value = try await service.savedState(for: uri)
                guard isCurrent(requestGeneration, uri) else { return }
                saved = value
                error = nil
            } catch {
                guard isCurrent(requestGeneration, uri) else { return }
                saved = nil
                self.error = error as? LibraryError ?? .unavailable
            }
        }
        pending = task
        await task.value
    }

    private func isCurrent(_ requestGeneration: Int, _ requestURI: SpotifyURI) -> Bool {
        generation == requestGeneration && uri == requestURI && !Task.isCancelled
    }
    private func finish(_ requestGeneration: Int) {
        guard generation == requestGeneration else { return }
        isPending = false
        pending = nil
        BopifyLog.library.debug("favorite operation finished")
    }
}
