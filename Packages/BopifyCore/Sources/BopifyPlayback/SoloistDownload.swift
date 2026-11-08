import Foundation

public enum SoloistInstallProgress: Sendable {
    case downloading(received: Int64, total: Int64?)
    case verifying, installed, updateReady
}

/// A bounded disk download from Spotify. No credentials, cookies, or redirects are sent.
final class SoloistDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let url = URL(string: "https://soloist-builds.spotifycdn.com/soloist_release_osx_arm64.tar.gz")!
    private static let limit: Int64 = 80 * 1024 * 1024
    private let lock = NSLock()
    private let destination: URL
    private let progress: @Sendable (SoloistInstallProgress) -> Void
    private var continuation: CheckedContinuation<Void, any Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var failure: SoloistInstallationError?
    private var canceled = false
    private var saved = false
    private var reported = Date.distantPast

    init(destination: URL, progress: @escaping @Sendable (SoloistInstallProgress) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(to destination: URL, progress: @escaping @Sendable (SoloistInstallProgress) -> Void) async throws {
        let download = SoloistDownload(destination: destination, progress: progress)
        try await download.start()
    }

    private func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let task: URLSessionDownloadTask? = lock.withLock {
                    guard !canceled else { continuation.resume(throwing: CancellationError()); return nil }
                    self.continuation = continuation
                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = 30
                    config.timeoutIntervalForResource = 180
                    config.httpCookieStorage = nil
                    config.urlCredentialStorage = nil
                    config.urlCache = nil
                    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                    self.session = session
                    let task = session.downloadTask(with: Self.url)
                    self.task = task
                    return task
                }
                task?.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        let task = lock.withLock { canceled = true; return self.task }
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.withLock { failure = .downloadFailed }
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.limit || totalBytesExpectedToWrite > Self.limit {
            lock.withLock { failure = .downloadTooLarge }
            downloadTask.cancel()
            return
        }
        let report = lock.withLock { () -> Bool in
            guard Date().timeIntervalSince(reported) >= 0.15 else { return false }
            reported = .now
            return true
        }
        if report { progress(.downloading(received: totalBytesWritten,
            total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  response.url == Self.url else { throw SoloistInstallationError.downloadFailed }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size > 0, size <= Self.limit else { throw SoloistInstallationError.downloadTooLarge }
            guard !lock.withLock({ canceled }) else { throw SoloistInstallationError.cancelled }
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            lock.withLock { saved = true }
        } catch { lock.withLock { failure = error as? SoloistInstallationError ?? .downloadFailed } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let completion = lock.withLock { () -> (CheckedContinuation<Void, any Error>?, (any Error)?) in
            let continuation = self.continuation
            self.continuation = nil
            let result: (any Error)? = canceled ? CancellationError() : failure ?? (error == nil && saved ? nil : .downloadFailed)
            return (continuation, result)
        }
        session.finishTasksAndInvalidate()
        if let error = completion.1 { completion.0?.resume(throwing: error) }
        else { completion.0?.resume() }
    }
}
