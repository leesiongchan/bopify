import Foundation
import BopifyDomain
import os

protocol SoloistPairingPublishing: Sendable {
    var isPublished: Bool { get async }
    func stop() async
}

typealias SoloistPairingPublisherFactory = @Sendable (UInt16, String) async throws -> any SoloistPairingPublishing

enum SoloistPairingIdentity {
    static func validate(_ data: Data, name: String) throws -> String {
        guard data.count <= 65_536,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["status"] as? Int == 101, json["remoteName"] as? String == name,
              let id = json["deviceID"] as? String, !id.isEmpty, id.utf8.count <= 512 else {
            throw SoloistPlaybackError.discoveryUnavailable
        }
        return id
    }
}

private final class SoloistPairingHTTPDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Publishes only the verified SDK's pairing server. Authentication and audio remain inside Soloist.
@MainActor
final class SoloistBonjourPublisher: NSObject, @MainActor NetServiceDelegate, @MainActor NetServiceBrowserDelegate, SoloistPairingPublishing {
    private(set) var isPublished = false
    private let service: NetService
    private var browser: NetServiceBrowser?
    private var completion: CheckedContinuation<Void, any Error>?
    private var deadline: Task<Void, Never>?
    private var stopped = false

    private init(port: UInt16, name: String) {
        service = NetService(domain: "local.", type: "_spotify-connect._tcp.", name: name, port: Int32(port))
        super.init()
    }

    static func publish(port: UInt16, name: String) async throws -> SoloistBonjourPublisher {
        guard port > 0 else { throw SoloistPlaybackError.discoveryUnavailable }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config, delegate: SoloistPairingHTTPDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:\(port)/zc?action=getInfo")!
        let (bytes, response) = try await session.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SoloistPlaybackError.discoveryUnavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65_536 else { throw SoloistPlaybackError.discoveryUnavailable }
            data.append(byte)
        }
        _ = try SoloistPairingIdentity.validate(data, name: name)
        try Task.checkCancellation()
        let publisher = SoloistBonjourPublisher(port: port, name: name)
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    publisher.completion = continuation
                    publisher.service.delegate = publisher
                    publisher.service.setTXTRecord(NetService.data(fromTXTRecord: [
                        "VERSION": Data("1.0".utf8), "CPath": Data("/zc".utf8),
                    ]))
                    publisher.deadline = Task { [weak publisher] in
                        do { try await Task.sleep(for: .seconds(8)) } catch { return }
                        publisher?.fail(code: 0)
                    }
                    publisher.service.publish()
                }
            } onCancel: {
                Task { await publisher.stop() }
            }
            try Task.checkCancellation()
            return publisher
        } catch {
            await publisher.stop()
            throw error
        }
    }

    func netServiceDidPublish(_ sender: NetService) {
        guard !stopped else { return }
        let browser = NetServiceBrowser()
        self.browser = browser
        browser.delegate = self
        browser.searchForServices(ofType: "_spotify-connect._tcp.", inDomain: "local.")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        fail(code: errorDict[NetService.errorCode]?.intValue ?? 0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind found: NetService, moreComing: Bool) {
        guard !stopped, found.name == service.name else { return }
        isPublished = true
        deadline?.cancel(); deadline = nil
        browser.stop(); browser.delegate = nil; self.browser = nil
        BopifyLog.playback.info("Soloist pairing endpoint published and observed through native Bonjour")
        let completion = self.completion; self.completion = nil
        completion?.resume()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        fail(code: errorDict[NetService.errorCode]?.intValue ?? 0)
    }

    private func fail(code: Int) {
        guard !stopped else { return }
        BopifyLog.playback.error("Soloist native Bonjour publication failed code=\(code, privacy: .public)")
        close(error: SoloistPlaybackError.discoveryUnavailable)
    }

    func stop() async { close(error: CancellationError()) }

    private func close(error: any Error) {
        guard !stopped else { return }
        stopped = true; isPublished = false
        deadline?.cancel(); deadline = nil
        browser?.stop(); browser?.delegate = nil; browser = nil
        service.delegate = nil; service.stop()
        let completion = self.completion; self.completion = nil
        completion?.resume(throwing: error)
    }
}
