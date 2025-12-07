//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2025 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import Logging
import NIO
import NIOFoundationCompat
import NIOHTTP1
import Testing

@testable import MQTTNIO

#if canImport(Network)
import NIOTransportServices
#endif
#if os(macOS) || os(Linux)
import NIOSSL
#endif

@Suite("MQTTNewConnection v5 Tests")
struct MQTTNewConnectionV5Tests {
    static let hostname = ProcessInfo.processInfo.environment["MOSQUITTO_SERVER"] ?? "localhost"

    @Test("Connect")
    func connect() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(versionConfiguration: .v5_0()),
            identifier: "connectV5",
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    @Test("Connect with Will")
    func connectWithWill() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(
                versionConfiguration: .v5_0(
                    will: (
                        topicName: "MyWillTopic",
                        payload: ByteBufferAllocator().buffer(string: "Test payload"),
                        qos: .atLeastOnce,
                        retain: false,
                        properties: .init()  // TODO: Do we need to set `.sessionExpiryInterval(0xFFFF_FFFF)` by default?
                    )
                )
            ),
            identifier: "connectWithWillV5",
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    static let properties: [MQTTProperties.Property] = [
        .requestResponseInformation(1),
        .topicAliasMaximum(1024),
        .sessionExpiryInterval(15),
        .userProperty("test", "value"),
        .authenticationData(ByteBufferAllocator().buffer(string: "TestBuffer")),
    ]

    @Test("Connect with Properties", arguments: Self.properties)
    func connectWith(property: MQTTProperties.Property) async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(versionConfiguration: .v5_0(connectProperties: .init([property]))),
            identifier: "connectWithPropertyV5_\(property)",
            logger: self.logger
        ) { connection in
            try await connection.ping()
        }
    }

    @Test("Connect with No Identifier")
    func connectWithNoIdentifier() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(versionConfiguration: .v5_0()),
            identifier: "",
            logger: self.logger
        ) { connection in
            #expect(await !connection.identifier.isEmpty)
        }
    }

    @Test("Publish", arguments: MQTTQoS.allCases, [MQTTProperties.Property.contentType("text/plain"), nil])
    func publish(qos: MQTTQoS, property: MQTTProperties.Property?) async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(versionConfiguration: .v5_0()),
            identifier: "publishV5QoS\(qos.rawValue)WithProperty\(String(describing: property))",
            logger: self.logger
        ) { connection in
            let properties: MQTTProperties = if let property { .init([property]) } else { .init() }
            _ = try await connection.v5.publish(
                to: "publishV5",
                payload: ByteBufferAllocator().buffer(string: "Test payload"),
                qos: qos,
                properties: properties
            )
        }
    }

    // TODO: testSessionPresent

    @Test("Bad Authentication Method")
    func badAuthenticationMethod() async throws {
        await #expect(throws: MQTTError.reasonError(.badAuthenticationMethod)) {
            try await MQTTNewConnection.withConnection(
                address: .hostname(Self.hostname),
                configuration: .init(versionConfiguration: .v5_0(connectProperties: [.authenticationMethod("test")])),
                identifier: "badAuthenticationMethodV5",
                logger: self.logger
            ) { _ in }
        }
    }

    @Test("Auth")
    func auth() async throws {
        try await MQTTNewConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(versionConfiguration: .v5_0()),
            identifier: "reAuthV5",
            logger: self.logger
        ) { connection in
            let error = await #expect(throws: MQTTError.self) {
                try await connection.v5.auth(properties: []) { _ in .init(reason: .continueAuthentication, properties: []) }
            }
            switch error {
            // different version of mosquitto error in different ways
            case .serverClosedConnection:
                break
            case .serverDisconnection(let ack):
                #expect(ack.reason == .protocolError)
            default:
                Issue.record("\(error)")
            }
        }
    }

    let logger: Logger = {
        var logger = Logger(label: "MQTTNIOTests")
        logger.logLevel = .trace
        return logger
    }()
}
