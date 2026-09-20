// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BopifyCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BopifyDomain", targets: ["BopifyDomain"]),
        .library(name: "BopifyAuth", targets: ["BopifyAuth"]),
        .library(name: "BopifyPlayback", targets: ["BopifyPlayback"]),
    ],
    targets: [
        .target(name: "BopifyDomain", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "BopifyAuth", dependencies: ["BopifyDomain"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "BopifyPlayback", dependencies: ["BopifyDomain"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "DomainTests", dependencies: ["BopifyDomain"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "AuthTests", dependencies: ["BopifyAuth"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "PlaybackTests", dependencies: ["BopifyPlayback"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
