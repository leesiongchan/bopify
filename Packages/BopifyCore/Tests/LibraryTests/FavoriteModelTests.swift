import Foundation
import Testing
import BopifyDomain
import BopifyLibrary

private actor ControlledLibrary: LibraryService {
    struct Request: Equatable { let method: String; let uri: SpotifyURI }
    private var reads: [SpotifyURI: CheckedContinuation<Bool, Error>] = [:]
    private var mutation: CheckedContinuation<Void, Error>?
    private var queued: [Request] = []
    private var waiter: CheckedContinuation<Request, Never>?
    private(set) var mutationCount = 0
    func nextRequest() async -> Request {
        if !queued.isEmpty { return queued.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }
    private func record(_ request: Request) {
        if let waiter { self.waiter = nil; waiter.resume(returning: request) }
        else { queued.append(request) }
    }
    func savedState(for uri: SpotifyURI) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            reads[uri] = continuation
            record(Request(method: "GET", uri: uri))
        }
    }
    func save(_ uri: SpotifyURI) async throws { try await mutate(uri, method: "PUT") }
    func remove(_ uri: SpotifyURI) async throws { try await mutate(uri, method: "DELETE") }
    private func mutate(_ uri: SpotifyURI, method: String) async throws {
        mutationCount += 1
        try await withCheckedThrowingContinuation { continuation in
            mutation = continuation
            record(Request(method: method, uri: uri))
        }
    }
    func resolveRead(_ uri: SpotifyURI, _ result: Result<Bool, Error>) { reads.removeValue(forKey: uri)?.resume(with: result) }
    func resolveMutation(_ result: Result<Void, Error>) { mutation?.resume(with: result); mutation = nil }
}

@Suite("FavoriteModel") @MainActor
struct FavoriteModelTests {
    private let a = SpotifyURI("spotify:track:a")!
    private let b = SpotifyURI("spotify:track:b")!

    @Test func lateTrackAReadCannotReplaceTrackB() async {
        let service = ControlledLibrary()
        let model = FavoriteModel(service: service)
        let first = Task { await model.select(a) }
        _ = await service.nextRequest()
        let second = Task { await model.select(b) }
        _ = await service.nextRequest()
        await service.resolveRead(b, .success(false))
        await second.value
        await service.resolveRead(a, .success(true))
        await first.value
        #expect(model.uri == b)
        #expect(model.saved == false)
        #expect(!model.isPending)
    }
    @Test func clearRejectsLateRead() async {
        let service = ControlledLibrary()
        let model = FavoriteModel(service: service)
        let request = Task { await model.select(a) }
        _ = await service.nextRequest()
        model.clear()
        await service.resolveRead(a, .success(true))
        await request.value
        #expect(model.uri == nil && model.saved == nil && !model.isPending)
        #expect(model.membershipRevision == 0)
    }
    @Test func rejectedMutationRollsBackAndIgnoresRepeatedToggle() async {
        let service = ControlledLibrary()
        let model = FavoriteModel(service: service)
        let read = Task { await model.select(a) }
        _ = await service.nextRequest()
        await service.resolveRead(a, .success(false))
        await read.value
        let toggle = Task { await model.toggle() }
        #expect(await service.nextRequest().method == "PUT")
        #expect(model.saved == true && model.isPending)
        await model.toggle()
        #expect(await service.mutationCount == 1)
        await service.resolveMutation(.failure(LibraryError.forbidden))
        await toggle.value
        #expect(model.saved == false)
        #expect(model.error == .forbidden)
        #expect(model.membershipRevision == 0)
        #expect(!model.isPending)
    }
    @Test(arguments: [true, false]) func ambiguousMutationReconcilesOrBecomesUnknown(readSucceeds: Bool) async {
        let service = ControlledLibrary()
        let model = FavoriteModel(service: service)
        let read = Task { await model.select(a) }
        _ = await service.nextRequest()
        await service.resolveRead(a, .success(false))
        await read.value
        let toggle = Task { await model.toggle() }
        _ = await service.nextRequest()
        await service.resolveMutation(.failure(LibraryError.unavailable))
        #expect(await service.nextRequest().method == "GET")
        await service.resolveRead(a, readSucceeds ? .success(true) : .failure(LibraryError.unavailable))
        await toggle.value
        #expect(model.saved == (readSucceeds ? true : nil))
        #expect(model.error == (readSucceeds ? nil : .unavailable))
        #expect(model.membershipRevision == (readSucceeds ? 1 : 0))
        #expect(!model.isPending)
    }
    @Test func clearDuringMutationStartsNoReconciliation() async {
        let service = ControlledLibrary()
        let model = FavoriteModel(service: service)
        let read = Task { await model.select(a) }
        _ = await service.nextRequest()
        await service.resolveRead(a, .success(false))
        await read.value
        let toggle = Task { await model.toggle() }
        _ = await service.nextRequest()
        model.clear()
        await service.resolveMutation(.success(()))
        await toggle.value
        #expect(model.uri == nil && model.saved == nil && !model.isPending)
        #expect(model.membershipRevision == 0)
    }
    @Test(arguments: [true, false]) func revisionChangesOnlyAfterConfirmedMutation(changed: Bool) async {
        let service = ControlledLibrary()
        let model = FavoriteModel(service: service)
        for _ in 0..<2 {
            let read = Task { await model.select(a) }
            _ = await service.nextRequest()
            await service.resolveRead(a, .success(false))
            await read.value
            #expect(model.membershipRevision == 0)
        }
        let toggle = Task { await model.toggle() }
        _ = await service.nextRequest()
        #expect(model.membershipRevision == 0)
        await service.resolveMutation(.success(()))
        _ = await service.nextRequest()
        await service.resolveRead(a, .success(changed))
        await toggle.value
        #expect(model.membershipRevision == (changed ? 1 : 0))
        model.clear()
        #expect(model.membershipRevision == (changed ? 1 : 0))
    }

}
