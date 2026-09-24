// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClickMan",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "ClickMan", targets: ["ClickMan"]),
    ],
    targets: [
        // Built by scripts/build-xcframework.sh from crates/clickman-core.
        .binaryTarget(name: "ClickManCore", path: "swift/ClickManCore.xcframework"),
        .target(
            name: "ClickMan",
            dependencies: ["ClickManCore"],
            path: "swift/Sources/ClickMan",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "clickman-e2e-client",
            dependencies: ["ClickMan"],
            path: "swift/EndToEndClient"
        ),
        .testTarget(
            name: "ClickManTests",
            dependencies: ["ClickMan"],
            path: "swift/Tests/ClickManTests"
        ),
    ]
)
