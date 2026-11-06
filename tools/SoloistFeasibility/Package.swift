// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SoloistFeasibility",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "soloist-feasibility", targets: ["SoloistFeasibility"])],
    dependencies: [.package(path: "../../Packages/BopifyCore")],
    targets: [
        .executableTarget(name: "SoloistFeasibility", dependencies: [
            .product(name: "BopifyAuth", package: "BopifyCore"),
            .product(name: "BopifyDomain", package: "BopifyCore"),
        ]),
        .testTarget(name: "SoloistFeasibilityTests", dependencies: ["SoloistFeasibility"]),
    ]
)
