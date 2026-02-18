// swift-tools-version:6.2

import PackageDescription

let defaultSwiftSettings: [SwiftSetting] =
    [
        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0335-existential-any.md
        .enableUpcomingFeature("ExistentialAny"),

        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md
        .enableUpcomingFeature("InternalImportsByDefault"),

        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
        .enableUpcomingFeature("MemberImportVisibility"),

        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0470-isolated-conformances.md
        .enableUpcomingFeature("InferIsolatedConformances"),

        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),

        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0481-weak-let.md
        .enableUpcomingFeature("ImmutableWeakCaptures"),
    ]

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
                .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(platforms: [.linux, .macOS, .android])),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ],
            swiftSettings: defaultSwiftSettings
        ),
        .testTarget(
            name: "MQTTNIOTests",
            dependencies: [
                .target(name: "MQTTNIO")
            ],
            swiftSettings: defaultSwiftSettings
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                .target(name: "MQTTNIO")
            ],
            swiftSettings: defaultSwiftSettings
        ),
    ]
)
