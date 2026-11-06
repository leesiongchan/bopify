import Foundation

struct SoloistFrame: Sendable {
    let data: Data
    let receivedAt: Date
}

protocol SoloistTransport: Sendable {
    var messages: AsyncThrowingStream<SoloistFrame, any Error> { get }
    func send(_ data: Data) async throws
    func close() async
}

final class SoloistSocket: SoloistTransport, Sendable {
    let messages: AsyncThrowingStream<SoloistFrame, any Error>
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let receiver: Task<Void, Never>

    init(endpoint: URL) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config)
        self.session = session
        let socket = session.webSocketTask(with: endpoint)
        self.socket = socket
        socket.maximumMessageSize = 1_048_576
        let pair = AsyncThrowingStream<SoloistFrame, any Error>.makeStream(bufferingPolicy: .bufferingNewest(256))
        messages = pair.stream
        socket.resume()
        receiver = Task {
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let receivedAt = Date()
                    let data: Data
                    switch message {
                    case let .data(value): data = value
                    case let .string(value): data = Data(value.utf8)
                    @unknown default: throw SoloistPlaybackError.invalidState
                    }
                    guard data.count <= 1_048_576 else { throw SoloistPlaybackError.invalidState }
                    if case .dropped = pair.continuation.yield(SoloistFrame(data: data, receivedAt: receivedAt)) { throw SoloistPlaybackError.invalidState }
                }
                pair.continuation.finish()
            } catch { pair.continuation.finish(throwing: SoloistPlaybackError.unavailable) }
        }
    }

    func send(_ data: Data) async throws {
        let socket = self.socket
        guard data.count <= 65_536 else { throw SoloistPlaybackError.unsupported }
        let message = try Self.textMessage(data)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withTaskCancellationHandler { try await socket.send(message) }
                    onCancel: { socket.cancel(with: .goingAway, reason: nil) }
            }
            group.addTask { try await Task.sleep(for: .seconds(20)); throw SoloistPlaybackError.unavailable }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    static func textMessage(_ data: Data) throws -> URLSessionWebSocketTask.Message {
        guard let text = String(data: data, encoding: .utf8) else { throw SoloistPlaybackError.invalidState }
        return .string(text)
    }

    func close() async {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        receiver.cancel()
        await receiver.value
    }
}
