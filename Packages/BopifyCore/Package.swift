// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BopifyCore",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BopifyDomain", targets: ["BopifyDomain"]),
        .library(name: "BopifyLibrary", targets: ["BopifyLibrary"]),
        .library(name: "BopifyAuth", targets: ["BopifyAuth"]),
        .library(name: "BopifyPlayback", targets: ["BopifyPlayback"]),
    ],
    targets: [
        .target(name: "BopifyDomain", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "BopifyAuth", dependencies: ["BopifyDomain"], swiftSettings: [.swiftLanguageMode(.v6)]),
        // Built by scripts/build-rust.sh, which must run before this package
        // will even configure: artifacts/ is gitignored build output.
        .binaryTarget(name: "BopifyCoreFFI", path: "../../artifacts/BopifyCoreFFI.xcframework"),
        // A binaryTarget carries neither a module map nor linker settings, so
        // this target supplies both. The libraries are what
        // `cargo rustc -- --print=native-static-libs` reports for the crate.
        .target(
            name: "CBopifyCore",
            dependencies: ["BopifyCoreFFI"],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
                .linkedLibrary("objc"),
                .linkedLibrary("iconv"),
            ]
        ),
        .target(name: "BopifyPlayback", dependencies: ["BopifyDomain", "CBopifyCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "BopifyLibrary", dependencies: ["BopifyDomain"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "LibraryTests", dependencies: ["BopifyLibrary"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "DomainTests", dependencies: ["BopifyDomain"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "AuthTests", dependencies: ["BopifyAuth"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "PlaybackTests", dependencies: ["BopifyPlayback", "CBopifyCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
