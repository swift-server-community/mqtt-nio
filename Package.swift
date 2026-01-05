// swift-tools-version:6.1

import PackageDescription

let package = Package(
    name: "mqtt-nio",
    platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11)],
    products: [
        .library(name: "MQTTNIO", targets: ["MQTTNIO"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.4"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.90.1"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.36.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.26.0"),
    ],
    targets: [
        .target(
            name: "MQTTNIO",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(platforms: [.linux, .macOS])),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ]
        ),
        .testTarget(name: "MQTTNIOTests", dependencies: ["MQTTNIO"]),
    ],
    swiftLanguageModes: [.v5]
)
