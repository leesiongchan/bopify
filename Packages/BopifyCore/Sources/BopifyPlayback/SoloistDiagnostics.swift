import Darwin
import Foundation
import BopifyDomain

enum SoloistDiagnosticEvent: Equatable, Sendable {
    case mdnsReady, mdnsFailed, pairingServerReady(UInt16), pairingServerFailed
    case getInfoRequested, loginRequested, keyRejected, waitingForLogin

    var code: String {
        switch self {
        case .mdnsReady: "mdnsReady"
        case .mdnsFailed: "mdnsFailed"
        case .pairingServerReady: "pairingServerReady"
        case .pairingServerFailed: "pairingServerFailed"
        case .getInfoRequested: "getInfoRequested"
        case .loginRequested: "loginRequested"
        case .keyRejected: "keyRejected"
        case .waitingForLogin: "waitingForLogin"
        }
    }
}

/// Vendor output is untrusted and can contain credentials. Only fixed categories
/// and a validated loopback port survive parsing; raw lines are never logged.
final class SoloistDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var state = State()
    var events: [SoloistDiagnosticEvent] { lock.withLock { state.events } }
    var pairingPort: UInt16? { lock.withLock { state.pairingPort } }
    var getInfoRequestCount: UInt64 { lock.withLock { state.getInfoRequestCount } }
    var failure: SoloistPlaybackError? {
        lock.withLock {
            if state.events.contains(.keyRejected) { return .invalidKey }
            if state.events.contains(.mdnsFailed) || state.events.contains(.pairingServerFailed) { return .discoveryUnavailable }
            return nil
        }
    }

    func ingest(_ data: Data) {
        let events = lock.withLock { state.ingest(data) }
        events.forEach(Self.log)
    }

    func finish() {
        let events = lock.withLock { state.finish() }
        events.forEach(Self.log)
    }

    private static func log(_ record: Record) {
        let event = record.event
        if let count = record.requestCount {
            BopifyLog.playback.info("Soloist diagnostic code=getInfoRequested count=\(count, privacy: .public)")
            return
        }
        if case let .pairingServerReady(port) = event {
            BopifyLog.playback.info("Soloist diagnostic code=pairingServerReady port=\(port, privacy: .public)")
        } else {
            BopifyLog.playback.info("Soloist diagnostic code=\(event.code, privacy: .public)")
        }
    }

    private struct Record {
        let event: SoloistDiagnosticEvent
        var requestCount: UInt64? = nil
    }

    private struct State {
        private var bytes: [UInt8] = []
        private var droppingLine = false
        var events: [SoloistDiagnosticEvent] = []
        var pairingPort: UInt16?
        var getInfoRequestCount: UInt64 = 0

        mutating func ingest(_ data: Data) -> [Record] {
            var added: [Record] = []
            for byte in data {
                if byte == 10 {
                    if let event = consumeLine() { added.append(event) }
                } else if !droppingLine {
                    if bytes.count < 8192 { bytes.append(byte) }
                    else { bytes.removeAll(keepingCapacity: true); droppingLine = true }
                }
            }
            return added
        }

        mutating func finish() -> [Record] {
            consumeLine().map { [$0] } ?? []
        }

        private mutating func consumeLine() -> Record? {
            defer { bytes.removeAll(keepingCapacity: true); droppingLine = false }
            guard !droppingLine, let line = String(bytes: bytes, encoding: .utf8), let event = Self.parse(line) else { return nil }
            if case let .pairingServerReady(port) = event { pairingPort = port }
            if event == .getInfoRequested, getInfoRequestCount < .max { getInfoRequestCount += 1 }
            // History stays bounded; sample repeated requests so our own probe cannot
            // hide subsequent controller traffic. No request payload is retained.
            let requestRecord: Record? = if event == .getInfoRequested,
                getInfoRequestCount <= 16 || (getInfoRequestCount <= 1024 && getInfoRequestCount.nonzeroBitCount == 1) {
                Record(event: event, requestCount: getInfoRequestCount)
            } else { nil }
            if let index = events.firstIndex(where: { $0.code == event.code }) {
                events[index] = event
                return requestRecord
            }
            events.append(event)
            return requestRecord ?? Record(event: event)
        }

        private static func parse(_ line: String) -> SoloistDiagnosticEvent? {
            if line.contains("login failed while API key is configured") || line.contains("login failed: make sure --api-key is valid") { return .keyRejected }
            if line.contains("Failed to initialize mdns") { return .mdnsFailed }
            if line.contains("Unable to initialize ZeroConf service") { return .pairingServerFailed }
            if line.contains("mdns created successfully") { return .mdnsReady }
            if line.contains("zeroconf: received getInfo") { return .getInfoRequested }
            if line.contains("zeroconf: received addUser") { return .loginRequested }
            if line.contains("waiting for login") { return .waitingForLogin }
            let prefix = "Started ZeroConf service on port "
            guard let range = line.range(of: prefix) else { return nil }
            let suffix = line[range.upperBound...]
            let digits = suffix.prefix { $0.isASCII && $0 >= "0" && $0 <= "9" }
            guard !digits.isEmpty, digits.count <= 5, let port = UInt16(digits), port > 0 else { return nil }
            let path = suffix.dropFirst(digits.count)
            let expected = " path /zc"
            guard path.hasPrefix(expected) else { return nil }
            let trailing = path.dropFirst(expected.count)
            // The signed CLI colors the entire line, including an immediate reset after /zc.
            guard trailing.isEmpty || trailing.first?.isWhitespace == true || trailing == "\u{1B}[0m" else { return nil }
            return .pairingServerReady(port)
        }
    }
}

/// A nonblocking, bounded reader owns both pipe handles and its task. Closing or
/// cancelling it never waits for a vendor descendant to release an inherited FD.
final class SoloistDiagnosticOutput: @unchecked Sendable {
    let pipe = Pipe()
    let diagnostics = SoloistDiagnostics()
    private let reader: Task<Void, Never>

    init() throws {
        let input = pipe.fileHandleForReading
        let flags = fcntl(input.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(input.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            try? input.close(); try? pipe.fileHandleForWriting.close()
            throw SoloistStartupError.launchFailed
        }
        let diagnostics = diagnostics
        reader = Task.detached {
            defer { diagnostics.finish(); try? input.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while !Task.isCancelled {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(input.fileDescriptor, $0.baseAddress, $0.count) }
                if count > 0 { diagnostics.ingest(Data(bytes.prefix(count))) }
                else if count == 0 { return }
                else if errno == EINTR { continue }
                else if errno == EAGAIN || errno == EWOULDBLOCK {
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                } else { return }
            }
        }
    }

    func closeWriter() { try? pipe.fileHandleForWriting.close() }

    func stop() async {
        closeWriter()
        reader.cancel()
        await reader.value
    }
}
