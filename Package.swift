// swift-tools-version: 6.0
import PackageDescription

/// ClickMan for Apple platforms: a native client of docs/PROTOCOL.md. Events wait
/// in a GRDB store (protocol/queue.sql) and leave in gzipped batches.
let package = Package(
    name: "ClickMan",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "ClickMan", targets: ["ClickMan"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "ClickMan",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "swift/Sources/ClickMan"
        ),
        .executableTarget(
            name: "ClickManE2EWorker",
            dependencies: ["ClickMan"],
            path: "swift/Sources/ClickManE2EWorker"
        ),
        .testTarget(
            name: "ClickManTests",
            dependencies: ["ClickMan", .product(name: "GRDB", package: "GRDB.swift")],
            path: "swift/Tests/ClickManTests"
        ),
    ]
)
