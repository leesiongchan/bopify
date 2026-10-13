import Foundation
import AppKit
import ScreenCaptureKit
import BopifyAuth
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

@main struct LibraryClientIntegrationProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run() }
            catch { preconditionFailure("Library integration failed: \(error)") }
            app.terminate(nil)
        }
        app.run()
    }

    @MainActor static func run() async throws {
        if CommandLine.arguments.contains("--client-change") {
            try await checkClientChangeUI()
            return
        }
        let store = LibraryClientProbeStore()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LibraryClientTokenStub.self]
        let id = String(repeating: "0", count: 32)
        let auth = SpotifyAuthService(clientID: id,
            client: TokenClient(clientID: id, session: URLSession(configuration: config)),
            store: store, openURL: { _ in preconditionFailure("saving an ID must not open consent") })
        let environment = AppEnvironment(previewPlayer: PlayerModel(), favoriteService: UnusedLibrary(), libraryAuth: auth)
        store.failSave = true
        do {
            _ = try await auth.validAccessToken(requiredScopes: ["user-library-read"])
            preconditionFailure("the first save must fail")
        } catch {
            precondition(error as? PlayerError == .credentialSaveFailed)
        }
        precondition(LibraryClientTokenStub.requests.value == 1)
        await environment.setLibraryClientID(" \(id.uppercased())\n")
        store.failSave = false
        let token = try await auth.validAccessToken(requiredScopes: ["user-library-read"])
        precondition(token == "NEW_LIBRARY")
        precondition(LibraryClientTokenStub.requests.value == 1,
                     "saving the same client ID must preserve the rotated grant waiting for persistence")
        precondition(store.load()?.refreshToken == "ROTATED_LIBRARY")
        precondition(environment.libraryClientID == id && !environment.isEnablingLibrary)
        await environment.prepareForQuit()
        print("PASS: same-ID Save preserves rotated grant; retry saves without another refresh or browser")
    }
    @MainActor static func checkClientChangeUI() async throws {
        let store = LibraryClientProbeStore()
        store.failClear = true
        let auth = SpotifyAuthService(clientID: String(repeating: "0", count: 32), store: store,
                                      openURL: { _ in preconditionFailure("client change must not open browser") })
        let environment = AppEnvironment(previewPlayer: PlayerModel(), favoriteService: UnusedLibrary(), libraryAuth: auth)
        environment.librarySetupWindow.show(environment: environment)
        let window = NSApplication.shared.windows.first { $0.isVisible }!
        try await Task.sleep(for: .milliseconds(250))
        try await capture(window, "library-setup-before")
        await environment.setLibraryClientID(String(repeating: "1", count: 32))
        precondition(environment.libraryClientID == String(repeating: "0", count: 32), "failed deletion must preserve original client ID")
        precondition(window.isVisible, "failed client change must keep Library Access open for retry")
        try await Task.sleep(for: .milliseconds(250))
        try await capture(window, "library-setup-clear-error")
        store.failClear = false
        await environment.setLibraryClientID(String(repeating: "1", count: 32))
        precondition(environment.libraryClientID == String(repeating: "1", count: 32) && !window.isVisible)
        await environment.prepareForQuit()
        print("PASS: failed credential deletion preserves client ID, keeps setup open and permits retry")
    }

    @MainActor static func capture(_ window: NSWindow, _ name: String) async throws {
        let content = try await SCShareableContent.currentProcess
        let shared = content.windows.first { $0.windowID == window.windowNumber }!
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: shared), configuration: config)
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png")
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
        if let view = window.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let contentURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + "-content.png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: contentURL)
        }
        print("capture: \(name)")
    }

}

nonisolated final class LibraryClientProbeStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: TokenSet? = TokenSet(accessToken: "OLD_LIBRARY", refreshToken: "OLD_REFRESH",
        expiresAt: .distantPast, grantedScopes: ["user-library-read"])
    private var saveFault = false, clearFault = false
    var failSave: Bool {
        get { lock.withLock { saveFault } }
        set { lock.withLock { saveFault = newValue } }
    }
    var failClear: Bool {
        get { lock.withLock { clearFault } }
        set { lock.withLock { clearFault = newValue } }
    }
    func load() -> TokenSet? { lock.withLock { saved } }
    func save(_ tokens: TokenSet) throws {
        try lock.withLock {
            if saveFault { throw KeychainError.unavailable(-25308) }
            saved = tokens
        }
    }
    func clear() throws {
        try lock.withLock {
            if clearFault { throw KeychainError.unavailable(-25308) }
            saved = nil
        }
    }
}

nonisolated final class LibraryClientRequestCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

nonisolated final class LibraryClientTokenStub: URLProtocol, @unchecked Sendable {
    static let requests = LibraryClientRequestCount()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests.increment()
        let first = Self.requests.value == 1
        let body = first
            ? #"{"access_token":"NEW_LIBRARY","refresh_token":"ROTATED_LIBRARY","expires_in":3600,"scope":"user-library-read"}"#
            : #"{"error":"invalid_grant"}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: first ? 200 : 400,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor UnusedLibrary: LibraryService {
    func savedState(for uri: SpotifyURI) async throws -> Bool { throw LibraryError.unavailable }
    func save(_ uri: SpotifyURI) async throws { throw LibraryError.unavailable }
    func remove(_ uri: SpotifyURI) async throws { throw LibraryError.unavailable }
}
