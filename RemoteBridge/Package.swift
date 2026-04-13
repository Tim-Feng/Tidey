// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RemoteBridge",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "tidey-remote-bridge", targets: ["RemoteBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.75.0"),
    ],
    targets: [
        .executableTarget(
            name: "RemoteBridge",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "RemoteBridgeTests",
            dependencies: ["RemoteBridge"]
        ),
    ]
)
