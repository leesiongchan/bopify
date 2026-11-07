#!/usr/bin/env swift
import CoreGraphics
import Foundation

// Run before the selected native rendering tests. Pass the same UUID to the test runner as
// TEST_RUNNER_BOPIFY_NATIVE_CAPTURE_TOKEN. Capture is restricted to fixture requests for that run.
guard CommandLine.arguments.count == 2, UUID(uuidString: CommandLine.arguments[1]) != nil else {
    fputs("Usage: swift scripts/capture-native-onboarding.swift <run UUID>\n", stderr)
    exit(2)
}

let token = CommandLine.arguments[1]
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let artifacts = root.appendingPathComponent("build/test-artifacts/onboarding-composited").standardizedFileURL
let bridge = artifacts.appendingPathComponent("capture-bridge/\(token)")
try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
guard CGPreflightScreenCaptureAccess() else {
    fputs("This tool process does not have screen capture access. No permission request was made.\n", stderr)
    exit(1)
}

struct CaptureFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func capture(_ request: [String: Any], requestID: String) throws -> String {
    guard request["token"] as? String == token,
          request["requestID"] as? String == requestID,
          let name = request["name"] as? String,
          ["key-entry", "completion", "handoff", "player"].contains(name),
          let pid = request["processID"] as? Int, pid > 0,
          let number = request["windowNumber"] as? Int, number > 0,
          let path = request["destination"] as? String else {
        throw CaptureFailure("Invalid fixture request")
    }
    let destination = URL(fileURLWithPath: path).standardizedFileURL
    guard destination.deletingLastPathComponent().deletingLastPathComponent() == artifacts,
          UUID(uuidString: destination.deletingLastPathComponent().lastPathComponent) != nil,
          destination.lastPathComponent == "\(name).png",
          destination.resolvingSymlinksInPath() == destination else {
        throw CaptureFailure("Destination is outside the fixture artifacts directory")
    }
    let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]]
    guard let window = windows?.first,
          (window[kCGWindowNumber as String] as? NSNumber)?.intValue == number,
          (window[kCGWindowOwnerPID as String] as? NSNumber)?.intValue == pid else {
        throw CaptureFailure("Fixture window is absent or its owner does not match")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l", String(number), destination.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          FileManager.default.fileExists(atPath: destination.path) else {
        throw CaptureFailure("Window capture failed (status \(process.terminationStatus))")
    }
    return destination.path
}

var handled = Set<String>()
var successfulCaptures = 0
let deadline = Date().addingTimeInterval(180)
while handled.count < 4, Date() < deadline {
    let requests = try FileManager.default.contentsOfDirectory(at: bridge, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasSuffix(".request.json") }
    for url in requests {
        let requestID = String(url.lastPathComponent.dropLast(".request.json".count))
        guard UUID(uuidString: requestID) != nil, !handled.contains(requestID) else { continue }
        var response: [String: Any] = ["token": token, "requestID": requestID, "success": false]
        do {
            guard let request = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw CaptureFailure("Invalid request JSON")
            }
            let path = try capture(request, requestID: requestID)
            response["success"] = true
            successfulCaptures += 1
            print("Captured isolated fixture: \(path)")
        } catch {
            response["error"] = String(describing: error)
            fputs("Fixture capture failed: \(error)\n", stderr)
        }
        let destination = bridge.appendingPathComponent("\(requestID).response.json")
        try JSONSerialization.data(withJSONObject: response).write(to: destination, options: .atomic)
        handled.insert(requestID)
    }
    Thread.sleep(forTimeInterval: 0.025)
}
guard successfulCaptures == 4 else {
    fputs("Captured \(successfulCaptures) of 4 fixture stages successfully.\n", stderr)
    exit(1)
}
