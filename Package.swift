// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "mqtt-nio",
    products: [
        .library(name: "MQTTNIO", targets: ["MQTTNIO"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.21.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.10.0")
    ],
    targets: [
        .target(name: "MQTTNIO", dependencies: [
            .byName(name: "CCoreMQTT"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .target(name: "CCoreMQTT", dependencies: []),
        .testTarget(name: "MQTTNIOTests", dependencies: ["MQTTNIO"], resources: [.process("mosquitto.org.crt")]),
    ]
)
