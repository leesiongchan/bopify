#!/usr/bin/env swift
import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit

// The isolated native fixture writes the nonce-bound request, then waits for video.ready.json
// before beginning its transition. This helper never captures a display or requests permission.
struct RecordingFailure: Error, CustomStringConvertible, Sendable {
    let description: String
    init(_ description: String) { self.description = description }
}

struct RecordingRequest: Decodable {
    let token: String
    let processID: Int32
    let windowNumber: UInt32
    let destination: String
}

struct WindowRegistrationPending: Error, CustomStringConvertible {
    let description: String
}

final class RecordingEvents: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var completion: Result<Void, RecordingFailure>?

    var state: (started: Bool, completion: Result<Void, RecordingFailure>?) {
        lock.withLock { (started, completion) }
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { started = true }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { if completion == nil { completion = .success(()) } }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        fail("Recording output failed", error: error)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        fail("Window stream stopped", error: error)
    }

    private func fail(_ operation: String, error: any Error) {
        let code = (error as NSError).code
        lock.withLock { if completion == nil { completion = .failure(RecordingFailure("\(operation) (code \(code))")) } }
    }
}

func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func requireCanonical(_ url: URL) throws {
    guard url.standardizedFileURL == url, url.resolvingSymlinksInPath() == url else {
        throw RecordingFailure("Artifact path is not canonical or contains a symlink")
    }
}

func makeDirectory(_ url: URL) throws {
    try requireCanonical(url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
    try requireCanonical(url)
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
        throw RecordingFailure("Artifact directory is not an owned, protected directory")
    }
}

func readRequest(_ url: URL) throws -> RecordingRequest {
    try requireCanonical(url)
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw RecordingFailure("Cannot open video request") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_uid == getuid(), info.st_size <= 16_384 else {
        throw RecordingFailure("Invalid video request file")
    }
    let data = try handle.read(upToCount: 16_385) ?? Data()
    guard data.count <= 16_384 else { throw RecordingFailure("Video request is too large") }
    return try JSONDecoder().decode(RecordingRequest.self, from: data)
}

func writeResponse(_ value: [String: Any], to url: URL) throws {
    try requireCanonical(url)
    var info = stat()
    guard lstat(url.path, &info) != 0, errno == ENOENT else {
        throw RecordingFailure("Refusing to replace an existing bridge response")
    }
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).json")
    try JSONSerialization.data(withJSONObject: value).write(to: temporary, options: .withoutOverwriting)
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard link(temporary.path, url.path) == 0 else {
        throw RecordingFailure("Cannot publish an exclusive bridge response")
    }
}

func validateWindow(_ request: RecordingRequest) throws {
    guard request.processID > 0, request.windowNumber > 0 else {
        throw RecordingFailure("Fixture process ID and window number must be positive")
    }
    // The SDK defines PROC_PIDPATHINFO_MAXSIZE as 4*MAXPATHLEN; Swift cannot import that macro.
    var executableBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = executableBuffer.withUnsafeMutableBytes {
        proc_pidpath(request.processID, $0.baseAddress, UInt32($0.count))
    }
    guard length > 0 else {
        throw RecordingFailure("Cannot verify fixture executable for PID \(request.processID) (errno \(errno))")
    }
    let executable = String(decoding: executableBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let name = URL(fileURLWithPath: executable).lastPathComponent
    guard name == "xctest" else {
        throw RecordingFailure("Fixture PID \(request.processID) executable is \(name), expected xctest")
    }
    let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, request.windowNumber) as? [[String: Any]]
    guard let window = windows?.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == request.windowNumber }) else {
        throw WindowRegistrationPending(description: "Fixture window \(request.windowNumber) is not registered for PID \(request.processID)")
    }
    guard let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else {
        throw WindowRegistrationPending(description: "Fixture window \(request.windowNumber) has no registered owner PID yet")
    }
    guard owner == request.processID else {
        throw RecordingFailure("Fixture window \(request.windowNumber) owner PID \(owner) does not match requested PID \(request.processID)")
    }
}

@MainActor
func registeredFixtureWindow(_ request: RecordingRequest) async throws -> SCWindow {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    var waiting = "Fixture window is not available in ScreenCaptureKit"
    while true {
        try Task.checkCancellation()
        do {
            try validateWindow(request)
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            if let window = content.windows.first(where: { $0.windowID == request.windowNumber }) {
                guard window.owningApplication?.processID == request.processID else {
                    throw RecordingFailure("ScreenCaptureKit window \(request.windowNumber) owner PID does not match \(request.processID)")
                }
                if window.isOnScreen { return window }
                waiting = "Fixture window \(request.windowNumber) is not on screen yet"
            }
        } catch let pending as WindowRegistrationPending {
            waiting = pending.description
        }
        guard ContinuousClock.now < deadline else { throw RecordingFailure(waiting + " after 3 seconds") }
        try await Task.sleep(for: .milliseconds(25))
    }
}

@MainActor
func record(_ request: RecordingRequest, token: String, artifacts: URL, ready: URL) async throws -> URL {
    let destination = artifacts.appendingPathComponent("\(token)/handoff.mp4")
    guard request.token == token, request.destination == destination.path else {
        throw RecordingFailure("Request nonce or destination does not match this fixture run")
    }
    try makeDirectory(destination.deletingLastPathComponent())
    try requireCanonical(destination)
    var info = stat()
    guard lstat(destination.path, &info) != 0, errno == ENOENT else {
        throw RecordingFailure("Refusing to replace an existing recording")
    }
    let window = try await registeredFixtureWindow(request)
    let configuration = SCStreamConfiguration()
    configuration.width = 1280
    configuration.height = 960
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    configuration.capturesAudio = false
    configuration.captureMicrophone = false
    configuration.showsCursor = false
    configuration.includeChildWindows = false
    configuration.ignoreShadowsSingleWindow = true
    configuration.scalesToFit = true
    configuration.preservesAspectRatio = true
    let events = RecordingEvents()
    let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: events)
    let outputConfiguration = SCRecordingOutputConfiguration()
    outputConfiguration.outputURL = destination
    outputConfiguration.videoCodecType = .h264
    outputConfiguration.outputFileType = .mp4
    let output = SCRecordingOutput(configuration: outputConfiguration, delegate: events)
    try stream.addRecordingOutput(output)
    do {
        try validateWindow(request)
        try requireCanonical(destination)
        try await stream.startCapture()
        let startupDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !events.state.started {
            if let result = events.state.completion { try result.get(); throw RecordingFailure("Recording ended before it started") }
            guard ContinuousClock.now < startupDeadline else { throw RecordingFailure("Recording did not start") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try writeResponse(["token": token, "success": true], to: ready)
        print("Recording isolated fixture window")
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            try validateWindow(request)
            if let result = events.state.completion { try result.get(); throw RecordingFailure("Recording ended before the fixture interval") }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await stream.stopCapture()
        let finishDeadline = ContinuousClock.now.advanced(by: .seconds(8))
        while events.state.completion == nil {
            guard ContinuousClock.now < finishDeadline else { throw RecordingFailure("Recording did not finish writing") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try events.state.completion?.get()
        try requireCanonical(destination)
        guard lstat(destination.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size > 0 else { throw RecordingFailure("Recording file is missing or empty") }
        return destination
    } catch {
        try? await stream.stopCapture()
        throw error
    }
}

@MainActor
func run() async -> Int32 {
    guard CommandLine.arguments.count == 2, UUID(uuidString: CommandLine.arguments[1]) != nil else {
        writeError("Usage: swift scripts/record-native-onboarding.swift <run UUID>")
        return 2
    }
    let token = CommandLine.arguments[1]
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let artifacts = root.appendingPathComponent("build/test-artifacts/onboarding-composited").standardizedFileURL
    let bridge = artifacts.appendingPathComponent("capture-bridge/\(token)")
    let response = bridge.appendingPathComponent("video.response.json")
    do {
        try makeDirectory(bridge)
        guard CGPreflightScreenCaptureAccess() else {
            throw RecordingFailure("Screen capture access is unavailable; no permission request was made")
        }
        let requestURL = bridge.appendingPathComponent("video.request.json")
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while !FileManager.default.fileExists(atPath: requestURL.path) {
            guard ContinuousClock.now < deadline else { throw RecordingFailure("Timed out waiting for the fixture video request") }
            try await Task.sleep(for: .milliseconds(25))
        }
        let request = try readRequest(requestURL)
        let destination = try await record(request, token: token, artifacts: artifacts,
                                           ready: bridge.appendingPathComponent("video.ready.json"))
        try writeResponse(["token": token, "success": true, "destination": destination.path], to: response)
        print("Recorded isolated fixture: \(destination.path)")
        return 0
    } catch {
        writeError("Fixture recording failed: \(error)")
        if FileManager.default.fileExists(atPath: bridge.path) {
            try? writeResponse(["token": token, "success": false, "error": String(describing: error)], to: response)
        }
        return 1
    }
}

// ScreenCaptureKit installs a status indicator. Keep AppKit's actual main thread alive
// instead of dispatchMain(), which can service the main queue on a worker thread.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
Task { @MainActor in
    let status = await run()
    exit(status)
}
application.run()
