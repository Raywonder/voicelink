// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoiceLinkNative",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VoiceLinkNative", targets: ["VoiceLinkNative"])
    ],
    dependencies: [
        .package(url: "https://github.com/socketio/socket.io-client-swift", from: "16.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
    ],
    targets: [
        .executableTarget(
            name: "VoiceLinkNative",
            dependencies: [
                .product(name: "SocketIO", package: "socket.io-client-swift"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
