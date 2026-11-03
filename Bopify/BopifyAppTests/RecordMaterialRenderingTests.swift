import AppKit
import SwiftUI
import Testing
import Metal
import Observation
import BopifyPlayback

@MainActor @Suite("Record material native rendering", .serialized)
struct RecordMaterialRenderingTests {
    @Test func materialFunctionsAreAvailable() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: RecordMaterialTestBundle.self))
        #expect(library.functionNames.contains("recordGlass"))
        #expect(library.functionNames.contains("recordNacre"))
    }
}

private final class RecordMaterialTestBundle: NSObject {}
