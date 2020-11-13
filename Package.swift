// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "mqtt-nio",
    products: [
        .library(name: "MQTTNIO", targets: ["MQTTNIO"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.21.0")
    ],
    targets: [
        .target(name: "MQTTNIO", dependencies: [
            .byName(name: "CCoreMQTT"),
            .product(name: "NIO", package: "swift-nio"),
        ]),
        .target(name: "CCoreMQTT", dependencies: []),
        .testTarget(name: "MQTTNIOTests", dependencies: ["MQTTNIO"]),
    ]
)
