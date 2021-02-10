// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "mqtt-nio",
    platforms: [.macOS(.v10_14), .iOS(.v12), .tvOS(.v12), .watchOS(.v6)],
    products: [
        .library(name: "MQTTNIO", targets: ["MQTTNIO"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.21.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.10.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.6.0")
    ],
    targets: [
        .target(name: "MQTTNIO", dependencies: [
            .byName(name: "CCoreMQTT"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(platforms: [.linux, .macOS])),
            .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
        ]),
        .target(name: "CCoreMQTT", dependencies: []),
        .testTarget(name: "MQTTNIOTests", dependencies: ["MQTTNIO"]),
    ]
)
