import AppKit
import BopifyAuth
import BopifyDomain
import Foundation

final class ProbeRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

func probeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 30
    config.urlCache = nil
    config.httpCookieStorage = nil
    return URLSession(configuration: config, delegate: ProbeRedirectPolicy(), delegateQueue: nil)
}

enum ProbeAuthorization {
    static func authorize(clientID: String, scopes: Set<String>, callbackPort: UInt16?,
                          callbackPath: String) async throws -> TokenSet {
        try Task.checkCancellation()
        let session = probeSession()
        defer { session.invalidateAndCancel() }
        let state = UUID().uuidString
        let listener = LoopbackCallbackListener(expectedState: state, expectedPath: callbackPath)
        do {
            let token = try await withProbeTimeout(seconds: 300) {
                try await withTaskCancellationHandler {
                    let port = try await listener.start(port: callbackPort)
                    let redirect = LoopbackCallbackListener.redirectURI(port: port, path: callbackPath)
                    let pkce = PKCEPair.random()
                    let request = AuthorizationRequest(clientID: clientID, redirectURI: redirect,
                        scopes: scopes.sorted(), pkce: pkce, state: state)
                    let opened = await MainActor.run { NSWorkspace.shared.open(request.url) }
                    guard opened else { throw ProbeError(reason: .processFailed) }
                    let code = try await listener.waitForCallback()
                    let tokens = try await TokenClient(clientID: clientID, session: session)
                        .exchange(code: code, redirectURI: redirect, pkce: pkce)
                    guard scopes.isSubset(of: tokens.grantedScopes) else { throw ProbeError(reason: .consentDenied) }
                    return tokens
                } onCancel: { Task { await listener.stop() } }
            }
            await listener.stop()
            return token
        } catch {
            await listener.stop()
            if error is CancellationError { throw CancellationError() }
            if let error = error as? ProbeError { throw error }
            throw ProbeError(reason: .consentDenied)
        }
    }
}
