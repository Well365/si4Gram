// swift-tools-version:5.9
// Standalone SwiftPM manifest so the core can be unit-tested with `swift test` on macOS.
// Inside the Bazel build the same sources are compiled by ./BUILD.
import PackageDescription

let package = Package(
    name: "SecutgCore",
    platforms: [.macOS(.v10_13), .iOS(.v12)],
    products: [
        .library(name: "SecutgCore", targets: ["SecutgCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.11.0"),
    ],
    targets: [
        .target(
            name: "SecutgCore",
            dependencies: [.product(name: "Clibsodium", package: "swift-sodium")],
            path: "Sources/SecutgCore"
        ),
        .testTarget(
            name: "SecutgCoreTests",
            dependencies: ["SecutgCore"],
            path: "Tests/SecutgCoreTests",
            resources: [.copy("Vectors")]
        ),
    ]
)
