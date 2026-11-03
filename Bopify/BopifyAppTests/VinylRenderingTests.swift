import AppKit
import SwiftUI
import Testing
import Metal
import CoreGraphics
import BopifyPlayback

@MainActor @Suite("Vinyl native rendering", .serialized)
struct VinylRenderingTests {
    @Test func contourFunctionIsAvailable() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: VinylTestBundle.self))
        #expect(library.functionNames.contains("vinylContours"))
    }

    @Test func artisticFunctionsAreAvailable() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: VinylTestBundle.self))
        for name in ["vinylBloom", "vinylRhapsody", "vinylCarnival"] {
            #expect(library.functionNames.contains(name))
        }
    }
}

private final class VinylTestBundle: NSObject {}
