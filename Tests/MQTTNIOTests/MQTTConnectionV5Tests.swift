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

@Suite("MQTTConnection v5 Tests")
struct MQTTConnectionV5Tests {
    static let hostname = ProcessInfo.processInfo.environment["MOSQUITTO_SERVER"] ?? "localhost"

    @Test("Connect")
    func connect() async throws {
        try await MQTTConnection.withConnection(
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
        try await MQTTConnection.withConnection(
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
        try await MQTTConnection.withConnection(
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
        try await MQTTConnection.withConnection(
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
        try await MQTTConnection.withConnection(
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

    @Test("Subscribe with Flags")
    func subscribeFlags() async throws {
        let payloadString = #"{"test":1000000}"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(versionConfiguration: .v5_0()),
            identifier: "subscribeFlagsV5",
            logger: self.logger
        ) { connection in
            try await withThrowingTaskGroup { group in
                group.addTask {
                    try await Task.sleep(for: .seconds(1))
                    try await connection.v5.subscribe(
                        to: [
                            .init(topicFilter: "testMQTTSubscribeFlags1", qos: .atLeastOnce, noLocal: true),
                            .init(topicFilter: "testMQTTSubscribeFlags2", qos: .atLeastOnce, retainAsPublished: false, retainHandling: .sendAlways),
                            .init(topicFilter: "testMQTTSubscribeFlags3", qos: .atLeastOnce, retainHandling: .doNotSend),
                        ]
                    ) { subscription in
                        try await confirmation("subscribeFlags") { receivedMessage in
                            for try await message in subscription {
                                var buffer = message.payload
                                let string = buffer.readString(length: buffer.readableBytes)
                                #expect(string == payloadString)
                                #expect(message.properties.contains { if case .subscriptionIdentifier = $0 { true } else { false } })
                                receivedMessage()
                                return
                            }
                        }
                    }
                }

                group.addTask {
                    // only one of these publish messages should make it through as the subscription for "testMQTTSubscribeFlags1"
                    // does not allow locally published messages and the subscription for "testMQTTSubscribeFlags3" does not
                    // allow for retain messages to be sent
                    try await connection.publish(to: "testMQTTSubscribeFlags3", payload: payload, qos: .atLeastOnce, retain: true)
                    try await connection.publish(to: "testMQTTSubscribeFlags2", payload: payload, qos: .atLeastOnce, retain: true)
                    try await Task.sleep(for: .seconds(2))
                    try await connection.publish(to: "testMQTTSubscribeFlags1", payload: payload, qos: .atLeastOnce, retain: false)
                }

                try await group.waitForAll()
            }
        }
    }

    @Test("Content Type Property")
    func contentType() async throws {
        let payloadString = #"{"test":1000000}"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(versionConfiguration: .v5_0()),
            identifier: "contentTypeV5",
            logger: self.logger
        ) { connection in
            try await withThrowingTaskGroup { group in
                group.addTask {
                    try await connection.v5.subscribe(to: [.init(topicFilter: "testMQTTContentType", qos: .atLeastOnce)]) { subscription in
                        try await confirmation("contentType") { receivedMessage in
                            for try await message in subscription {
                                var buffer = message.payload
                                let string = buffer.readString(length: buffer.readableBytes)
                                #expect(string == payloadString)
                                #expect(message.properties.contains { if case .subscriptionIdentifier = $0 { true } else { false } })
                                #expect(message.properties.contains { $0 == .contentType("application/json") })
                                receivedMessage()
                                return
                            }
                        }
                    }
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(1))
                    _ = try await connection.v5.publish(
                        to: "testMQTTContentType",
                        payload: payload,
                        qos: .atLeastOnce,
                        properties: .init([.contentType("application/json")])
                    )
                }

                try await group.waitForAll()
            }
        }
    }

    @Test("User Property")
    func userProperty() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(versionConfiguration: .v5_0()),
            identifier: "userPropertyV5",
            logger: self.logger
        ) { connection in
            try await withThrowingTaskGroup { group in
                group.addTask {
                    try await connection.v5.subscribe(to: [.init(topicFilter: "testMQTTUserProperty", qos: .atLeastOnce)]) { subscription in
                        try await confirmation("userProperty") { receivedMessage in
                            for try await message in subscription {
                                #expect(message.properties.contains { if case .subscriptionIdentifier = $0 { true } else { false } })
                                #expect(message.properties.contains { $0 == .userProperty("key", "value") })
                                receivedMessage()
                                return
                            }
                        }
                    }
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(1))
                    _ = try await connection.v5.publish(
                        to: "testMQTTUserProperty",
                        payload: ByteBuffer(string: "test"),
                        qos: .atLeastOnce,
                        properties: .init([.userProperty("key", "value")])
                    )
                }

                try await group.waitForAll()
            }
        }
    }

    @Test("Bad Authentication Method")
    func badAuthenticationMethod() async throws {
        await #expect(throws: MQTTError.reasonError(.badAuthenticationMethod)) {
            try await MQTTConnection.withConnection(
                address: .hostname(Self.hostname),
                configuration: .init(versionConfiguration: .v5_0(connectProperties: [.authenticationMethod("test")])),
                identifier: "badAuthenticationMethodV5",
                logger: self.logger
            ) { _ in }
        }
    }

    @Test("Invalid Topic Name")
    func invalidTopicName() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(versionConfiguration: .v5_0()),
            identifier: "invalidTopicNameV5",
            logger: self.logger
        ) { connection in
            _ = await #expect(throws: MQTTPacketError.invalidTopicName) {
                try await connection.v5.publish(
                    to: "testInvalidTopicName#",
                    payload: ByteBufferAllocator().buffer(string: "Test payload"),
                    qos: .atLeastOnce
                )
            }
        }
    }

    /// Test Publish that will cause a server disconnection message
    @Test("Bad Publish")
    func badPublish() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(versionConfiguration: .v5_0()),
            identifier: "badPublishV5",
            logger: self.logger
        ) { connection in
            let error = await #expect(throws: MQTTError.self) {
                try await connection.v5.publish(
                    to: "testBadPublish",
                    payload: ByteBufferAllocator().buffer(string: "Test payload"),
                    qos: .atLeastOnce,
                    properties: [.requestResponseInformation(1)]
                )
            }
            switch error {
            case .serverDisconnection(let ack):
                // some versions of mosquitto return protocol error and others malformed packet
                #expect(ack.reason == .protocolError || ack.reason == .malformedPacket)
            default:
                Issue.record("\(error)")
            }
        }
    }

    @Test("Out of Range Topic Alias")
    func outOfRangeTopicAlias() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(versionConfiguration: .v5_0()),
            identifier: "outOfRangeTopicAliasV5",
            logger: self.logger
        ) { connection in
            _ = await #expect(throws: MQTTPacketError.topicAliasOutOfRange) {
                try await connection.v5.publish(
                    to: "testOutOfRangeTopicAlias",
                    payload: ByteBufferAllocator().buffer(string: "Test payload"),
                    qos: .atLeastOnce,
                    properties: [.topicAlias(connection.connectionParameters.maxTopicAlias + 1)]
                )
            }
        }
    }

    @Test("Publish with Subscription ID")
    func publishWithSubscriptionID() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(versionConfiguration: .v5_0()),
            identifier: "publishWithSubscriptionIDV5",
            logger: self.logger
        ) { connection in
            _ = await #expect(throws: MQTTPacketError.publishIncludesSubscription) {
                try await connection.v5.publish(
                    to: "testOutOfRangeTopicAlias",
                    payload: ByteBufferAllocator().buffer(string: "Test payload"),
                    qos: .atLeastOnce,
                    properties: [.subscriptionIdentifier(0)]
                )
            }
        }
    }

    @Test("Re-authentication Workflow")
    func auth() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(versionConfiguration: .v5_0()),
            identifier: "reAuthV5",
            logger: self.logger
        ) { connection in
            struct EmptyAuthenticator: MQTTAuthenticator {
                func authenticate(_ authPackage: MQTTAuthV5) async throws -> MQTTAuthV5 {
                    .init(reason: .continueAuthentication, properties: [])
                }
            }
            let error = await #expect(throws: MQTTError.self) {
                try await connection.v5.auth(properties: [], authWorkflow: EmptyAuthenticator())
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

    @Test("Subscribe to All Topics", .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil))
    func subscribeAll() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname("test.mosquitto.org"),
            configuration: .init(versionConfiguration: .v5_0()),
            identifier: "subscribeAllV5",
            logger: self.logger
        ) { connection in
            try await connection.v5.subscribe(to: [.init(topicFilter: "#", qos: .exactlyOnce)]) { _ in
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    @Test("Subscribe to Multi-level Wildcard")
    func multiLevelWildcard() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(versionConfiguration: .v5_0()),
            identifier: "multiLevelWildcardV5",
            logger: self.logger
        ) { connection in
            try await withThrowingTaskGroup { group in
                group.addTask {
                    try await confirmation("multiLevelWildcard", expectedCount: 2) { receivedMessage in
                        try await connection.v5.subscribe(to: [.init(topicFilter: "multiLevelV5/home/kitchen/#", qos: .atLeastOnce)]) {
                            subscription in
                            var count = 0
                            for try await message in subscription {
                                var buffer = message.payload
                                let string = buffer.readString(length: buffer.readableBytes)
                                #expect(string == "test")
                                #expect(message.properties.contains { if case .subscriptionIdentifier = $0 { true } else { false } })
                                receivedMessage()
                                count += 1
                                if count == 2 { return }
                            }
                        }
                    }
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(1))
                    _ = try await connection.v5.publish(
                        to: "multiLevelV5/home/kitchen/temperature",
                        payload: ByteBuffer(string: "test"),
                        qos: .atLeastOnce
                    )
                    _ = try await connection.v5.publish(
                        to: "multiLevelV5/home/livingroom/temperature",
                        payload: ByteBuffer(string: "error"),
                        qos: .atLeastOnce
                    )
                    _ = try await connection.v5.publish(
                        to: "multiLevelV5/home/kitchen/humidity",
                        payload: ByteBuffer(string: "test"),
                        qos: .atLeastOnce
                    )
                }

                try await group.waitForAll()
            }
        }
    }

    @Test("Subscribe to Single Level Wildcard")
    func singleLevelWildcard() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(versionConfiguration: .v5_0()),
            identifier: "singleLevelWildcardV5",
            logger: self.logger
        ) { connection in
            try await withThrowingTaskGroup { group in
                group.addTask {
                    try await confirmation("singleLevelWildcard", expectedCount: 2) { receivedMessage in
                        try await connection.v5.subscribe(to: [.init(topicFilter: "singleLevelV5/home/+/temperature", qos: .atLeastOnce)]) {
                            subscription in
                            var count = 0
                            for try await message in subscription {
                                var buffer = message.payload
                                let string = buffer.readString(length: buffer.readableBytes)
                                #expect(string == "test")
                                #expect(message.properties.contains { if case .subscriptionIdentifier = $0 { true } else { false } })
                                receivedMessage()
                                count += 1
                                if count == 2 { return }
                            }
                        }
                    }
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(1))
                    _ = try await connection.v5.publish(
                        to: "singleLevelV5/home/livingroom/temperature",
                        payload: ByteBuffer(string: "test"),
                        qos: .atLeastOnce
                    )
                    _ = try await connection.v5.publish(
                        to: "singleLevelV5/home/garden/humidity",
                        payload: ByteBuffer(string: "error"),
                        qos: .atLeastOnce
                    )
                    _ = try await connection.v5.publish(
                        to: "singleLevelV5/home/kitchen/temperature",
                        payload: ByteBuffer(string: "test"),
                        qos: .atLeastOnce
                    )
                }

                try await group.waitForAll()
            }
        }
    }

    /// Test that if a message matches multiple topic filters of a single subscription,
    /// the subscription receives as many copies of the message as there are matching topic filters.
    @Test("Overlapping Subscriptions")
    func overlappingSubscriptions() async throws {
        try await MQTTConnection.withConnection(
            address: .hostname(Self.hostname),
            configuration: .init(versionConfiguration: .v5_0()),
            identifier: "overlappingSubscriptionsV5",
            logger: self.logger
        ) { connection in
            try await withThrowingTaskGroup { group in
                group.addTask {
                    try await confirmation("overlappingSubscriptions", expectedCount: 2) { receivedMessage in
                        try await connection.v5.subscribe(to: [
                            .init(topicFilter: "overlappingV5/home/+/temperature", qos: .atLeastOnce),
                            .init(topicFilter: "overlappingV5/home/kitchen/#", qos: .atLeastOnce),
                        ]) { subscription in
                            var count = 0
                            for try await message in subscription {
                                var buffer = message.payload
                                let string = buffer.readString(length: buffer.readableBytes)
                                #expect(string == "test")
                                #expect(message.properties.contains { if case .subscriptionIdentifier = $0 { true } else { false } })
                                receivedMessage()
                                count += 1
                                if count == 2 { return }
                            }
                        }
                    }
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(1))
                    _ = try await connection.v5.publish(
                        to: "overlappingV5/home/kitchen/temperature",
                        payload: ByteBuffer(string: "test"),
                        qos: .atLeastOnce
                    )
                }

                try await group.waitForAll()
            }
        }
    }

    let logger: Logger = {
        var logger = Logger(label: "MQTTNIOTests")
        logger.logLevel = .trace
        return logger
    }()
}
