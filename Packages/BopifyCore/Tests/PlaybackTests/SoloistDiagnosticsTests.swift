import Foundation
import Testing
@testable import BopifyPlayback

@Suite("Soloist safe diagnostics")
struct SoloistDiagnosticsTests {
    @Test func fixedVendorMessagesBecomeTypedEventsWithoutTheirPayloads() {
        let diagnostics = SoloistDiagnostics()
        diagnostics.ingest(Data("""
        vendor: mdns created successfully
        vendor: Started ZeroConf service on port 43210 path /zc
        vendor: zeroconf: received getInfo sensitive-request
        vendor: zeroconf: received addUser sensitive-account
        vendor: waiting for login — connect to "private name" from your Spotify app
        unrelated private credential

        """.utf8))
        #expect(diagnostics.events == [.mdnsReady, .pairingServerReady(43210), .getInfoRequested, .loginRequested, .waitingForLogin])
        #expect(diagnostics.pairingPort == 43210)
        #expect(diagnostics.failure == nil)
    }

    @Test(arguments: ["Failed to initialize mdns", "Unable to initialize ZeroConf service"])
    func discoveryInitializationFailuresAreActionable(message: String) {
        let diagnostics = SoloistDiagnostics()
        diagnostics.ingest(Data("\(message): private vendor detail\n".utf8))
        #expect(diagnostics.failure == .discoveryUnavailable)
    }

    @Test(arguments: ["login failed while API key is configured", "login failed: make sure --api-key is valid"])
    func keyRejectionTakesPrecedenceOverDiscoveryFailure(message: String) {
        let diagnostics = SoloistDiagnostics()
        diagnostics.ingest(Data("Failed to initialize mdns\n\(message): synthetic-secret\n".utf8))
        #expect(diagnostics.failure == .invalidKey)
        #expect(diagnostics.events == [.mdnsFailed, .keyRejected])
    }

    @Test func splitLinesAndFinalUnterminatedLineAreParsed() {
        let diagnostics = SoloistDiagnostics()
        for byte in "Started ZeroConf service on port 12345 path /zc\r\nmdns created successfully".utf8 {
            diagnostics.ingest(Data([byte]))
        }
        diagnostics.finish()
        #expect(diagnostics.events == [.pairingServerReady(12345), .mdnsReady])
    }

    @Test func coloredVendorStartupStillReportsTheValidatedPort() {
        let diagnostics = SoloistDiagnostics()
        diagnostics.ingest(Data("\u{1B}[32mvendor: Started ZeroConf service on port 55617 path /zc\u{1B}[0m\n".utf8))
        #expect(diagnostics.pairingPort == 55617)
    }

    @Test(arguments: ["0", "65536", "-1", "+12", "１２", "9999999999999999999999", "12secret"])
    func malformedOrOutOfRangePortsNeverBecomeEndpoints(port: String) {
        let diagnostics = SoloistDiagnostics()
        diagnostics.ingest(Data("Started ZeroConf service on port \(port) path /zc\n".utf8))
        #expect(diagnostics.pairingPort == nil)
        #expect(diagnostics.events.isEmpty)
    }

    @Test(arguments: ["/other", "/zc/private", "/zc?secret=payload"])
    func unexpectedPairingPathsNeverBecomeEndpoints(path: String) {
        let diagnostics = SoloistDiagnostics()
        diagnostics.ingest(Data("Started ZeroConf service on port 12345 path \(path)\n".utf8))
        #expect(diagnostics.pairingPort == nil)
    }

    @Test func oversizedLinesAreDiscardedUntilTheNextNewline() {
        let diagnostics = SoloistDiagnostics()
        diagnostics.ingest(Data(repeating: 65, count: 8193))
        diagnostics.ingest(Data("login failed while API key is configured\nmdns created successfully\n".utf8))
        #expect(diagnostics.events == [.mdnsReady])
        #expect(diagnostics.failure == nil)
    }

    @Test func repeatedMessagesAndChangingPortsDoNotGrowHistory() {
        let diagnostics = SoloistDiagnostics()
        for port in 1...1000 {
            diagnostics.ingest(Data("mdns created successfully\nStarted ZeroConf service on port \(port) path /zc\n".utf8))
        }
        #expect(diagnostics.events.count == 2)
        #expect(diagnostics.pairingPort == 1000)
    }
}
