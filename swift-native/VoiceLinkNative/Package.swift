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
        .package(url: "https://github.com/socketio/socket.io-client-swift", from: "16.0.0")
    ],
    targets: [
        .executableTarget(
            name: "VoiceLinkNative",
            dependencies: [
                .product(name: "SocketIO", package: "socket.io-client-swift")
            ],
            path: "Sources"
        )
    ]
)
