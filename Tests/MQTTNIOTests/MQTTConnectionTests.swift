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

import Logging
import NIOCore
import NIOEmbedded
import Testing

@testable import MQTTNIO

@Suite("MQTTConnection Tests")
struct MQTTConnectionTests {
    func withTestMQTTServer(
        configuration: MQTTConnectionConfiguration = .init(),
        cleanSession: Bool = true,
        identifier: String = UUID().uuidString,
        logger: Logger = Logger(label: "test"),
        client clientOperation: @Sendable @escaping (MQTTConnection) async throws -> Void,
        server serverOperation: @Sendable @escaping (NIOAsyncTestingChannel) async throws -> Void,
    ) async throws {
        let channel = NIOAsyncTestingChannel()
        let connection = try await MQTTConnection.setupChannelAndConnect(
            channel,
            configuration: configuration,
            cleanSession: cleanSession,
            identifier: identifier,
            logger: logger
        )
        let version = configuration.version
        return try await withThrowingTaskGroup { group in
            group.addTask {
                defer { connection.close() }
                try await connection.sendConnect()
                try await clientOperation(connection)
            }
            group.addTask {
                // wait for connect
                let packet = try await channel.waitForOutboundPacket()
                #expect(packet.type == .CONNECT)
                #expect(packet.packetId == 0)

                let connack = MQTTConnAckPacket(returnCode: 0, acknowledgeFlags: 1, properties: .init())
                try await channel.writeInboundPacket(connack, version: version)

                try await serverOperation(channel)

                // wait for disconnect
                let disconnectPacket = try await channel.waitForOutboundPacket()
                #expect(disconnectPacket.type == .DISCONNECT)
                #expect(disconnectPacket.packetId == 0)
            }
            try await group.waitForAll()
        }
    }

    func testSubscribe(
        subscribeInfos: [MQTTSubscribeInfo],
        cleanSession: Bool = true,
        identifier: String = UUID().uuidString,
        logger: Logger = Logger(label: "test"),
        client clientOperation: @Sendable @escaping (MQTTSubscription) async throws -> Void,
        server serverOperation: @Sendable @escaping (NIOAsyncTestingChannel) async throws -> Void,
    ) async throws {
        try await withTestMQTTServer { connection in
            try await connection.subscribe(to: subscribeInfos) { sub in
                try await clientOperation(sub)
            }
        } server: { channel in
            // receive SUBSCRIBE
            var packet = try await channel.waitForOutboundPacket()
            let subscribePacket = try MQTTSubscribePacket.read(version: .v3_1_1, from: packet)
            #expect(subscribeInfos.count == subscribePacket.subscriptions.count)
            for index in 0..<subscribePacket.subscriptions.count {
                #expect(subscribePacket.subscriptions[index].topicFilter == subscribeInfos[index].topicFilter)
                #expect(subscribePacket.subscriptions[index].qos == subscribeInfos[index].qos)
            }
            // send SUBACK
            let suback = MQTTSubAckPacket(
                type: .SUBACK,
                packetId: subscribePacket.packetId,
                reasons: subscribeInfos.map { _ in .success },
                properties: .init()
            )
            try await channel.writeInboundPacket(suback, version: .v3_1_1)

            try await serverOperation(channel)

            // receive UNSUBSCRIBE
            packet = try await channel.waitForOutboundPacket()
            let unsubscribePacket = try MQTTUnsubscribePacket.read(version: .v3_1_1, from: packet)
            #expect(unsubscribePacket.subscriptions == subscribeInfos.map { $0.topicFilter })
            // send SUBACK
            let unsuback = MQTTSubAckPacket(
                type: .UNSUBACK,
                packetId: unsubscribePacket.packetId,
                reasons: subscribeInfos.map { _ in .success },
                properties: .init()
            )
            try await channel.writeInboundPacket(unsuback, version: .v3_1_1)
        }
    }

    func testSubscribeV5(
        subscribeInfos: [MQTTSubscribeInfoV5],
        cleanSession: Bool = true,
        identifier: String = UUID().uuidString,
        logger: Logger = Logger(label: "test"),
        client clientOperation: @Sendable @escaping (MQTTSubscription) async throws -> Void,
        server serverOperation: @Sendable @escaping (NIOAsyncTestingChannel, UInt32) async throws -> Void,
    ) async throws {
        try await withTestMQTTServer(configuration: .init(versionConfiguration: .v5_0())) { connection in
            try await connection.v5.subscribe(to: subscribeInfos) { sub in
                try await clientOperation(sub)
            }
        } server: { channel in
            // receive SUBSCRIBE
            var packet = try await channel.waitForOutboundPacket()
            let subscribePacket = try MQTTSubscribePacket.read(version: .v5_0, from: packet)
            #expect(subscribeInfos.count == subscribePacket.subscriptions.count)
            for index in 0..<subscribePacket.subscriptions.count {
                #expect(subscribePacket.subscriptions[index].topicFilter == subscribeInfos[index].topicFilter)
                #expect(subscribePacket.subscriptions[index].qos == subscribeInfos[index].qos)
            }
            let properties = try #require(subscribePacket.properties)
            let subscriptionId: UInt32 = try #require(
                {
                    for property in properties {
                        if case .subscriptionIdentifier(let id) = property {
                            return id
                        }
                    }
                    return nil
                }()
            )
            // send SUBACK
            let suback = MQTTSubAckPacket(
                type: .SUBACK,
                packetId: subscribePacket.packetId,
                reasons: subscribeInfos.map { _ in .success },
                properties: .init()
            )
            try await channel.writeInboundPacket(suback, version: .v5_0)

            try await serverOperation(channel, subscriptionId)

            // receive UNSUBSCRIBE
            packet = try await channel.waitForOutboundPacket()
            let unsubscribePacket = try MQTTUnsubscribePacket.read(version: .v5_0, from: packet)
            #expect(unsubscribePacket.subscriptions == subscribeInfos.map { $0.topicFilter })
            // send SUBACK
            let unsuback = MQTTSubAckPacket(
                type: .UNSUBACK,
                packetId: unsubscribePacket.packetId,
                reasons: subscribeInfos.map { _ in .success },
                properties: .init()
            )
            try await channel.writeInboundPacket(unsuback, version: .v5_0)
        }
    }

    @Test
    func testConnectDisconnect() async throws {
        try await withTestMQTTServer { _ in
        } server: { _ in
        }
    }

    @Test
    func testPublishQoS0ClientToServer() async throws {
        try await withTestMQTTServer { connection in
            try await connection.publish(to: "testTopic", payload: ByteBuffer(string: "TestPayload"), qos: .atMostOnce, retain: false)
        } server: { channel in
            let packet = try await channel.waitForOutboundPacket()
            let publishPacket = try MQTTPublishPacket.read(version: .v3_1_1, from: packet)
            #expect(publishPacket.publish.topicName == "testTopic")
            #expect(publishPacket.publish.retain == false)
            #expect(publishPacket.publish.payload == ByteBuffer(string: "TestPayload"))
        }
    }

    @Test
    func testPublishQoS1ClientToServer() async throws {
        try await withTestMQTTServer { connection in
            try await connection.publish(to: "testTopic", payload: ByteBuffer(string: "TestPayload"), qos: .atLeastOnce, retain: false)
        } server: { channel in
            let packet = try await channel.waitForOutboundPacket()
            let publishPacket = try MQTTPublishPacket.read(version: .v3_1_1, from: packet)
            #expect(publishPacket.publish.topicName == "testTopic")
            #expect(publishPacket.publish.retain == false)
            #expect(publishPacket.publish.payload == ByteBuffer(string: "TestPayload"))
            let ack = MQTTPubAckPacket(type: .PUBACK, packetId: publishPacket.packetId)
            try await channel.writeInboundPacket(ack, version: .v3_1_1)
        }
    }

    @Test
    func testPublishQoS2ClientToServer() async throws {
        try await withTestMQTTServer { connection in
            try await connection.publish(to: "testTopic", payload: ByteBuffer(string: "TestPayload"), qos: .exactlyOnce, retain: false)
        } server: { channel in
            // receive PUBLISH
            var packet = try await channel.waitForOutboundPacket()
            let publishPacket = try MQTTPublishPacket.read(version: .v3_1_1, from: packet)
            #expect(publishPacket.publish.topicName == "testTopic")
            #expect(publishPacket.publish.retain == false)
            #expect(publishPacket.publish.payload == ByteBuffer(string: "TestPayload"))
            // send PUBREC
            let pubRec = MQTTPubAckPacket(type: .PUBREC, packetId: publishPacket.packetId)
            try await channel.writeInboundPacket(pubRec, version: .v3_1_1)
            // read PUBREL
            packet = try await channel.waitForOutboundPacket()
            let pubRelPacket = try MQTTPubAckPacket.read(version: .v3_1_1, from: packet)
            #expect(pubRelPacket.type == .PUBREL)
            #expect(pubRelPacket.packetId == publishPacket.packetId)
            // send PUBCOMP
            let pubComp = MQTTPubAckPacket(type: .PUBCOMP, packetId: publishPacket.packetId)
            try await channel.writeInboundPacket(pubComp, version: .v3_1_1)
        }
    }

    @Test
    func testSubscribeAndPublishQoS0() async throws {
        try await testSubscribe(subscribeInfos: [.init(topicFilter: "testTopic", qos: .atMostOnce)]) { sub in
            var iterator = sub.makeAsyncIterator()
            let event = try #require(try await iterator.next())
            #expect(event.payload == ByteBuffer(string: "TestPayload"))
        } server: { channel in
            // send PUBLISH
            let publish = MQTTPublishPacket(
                publish: .init(
                    qos: .atMostOnce,
                    retain: false,
                    topicName: "testTopic",
                    payload: ByteBuffer(string: "TestPayload"),
                    properties: .init()
                ),
                packetId: 32768
            )
            try await channel.writeInboundPacket(publish, version: .v3_1_1)
        }
    }

    @Test
    func testSubscribeAndPublishQoS1() async throws {
        try await testSubscribe(subscribeInfos: [.init(topicFilter: "testTopic", qos: .atLeastOnce)]) { sub in
            var iterator = sub.makeAsyncIterator()
            let event = try #require(try await iterator.next())
            #expect(event.payload == ByteBuffer(string: "TestPayload"))
        } server: { channel in
            // send PUBLISH
            let publish = MQTTPublishPacket(
                publish: .init(
                    qos: .atLeastOnce,
                    retain: false,
                    topicName: "testTopic",
                    payload: ByteBuffer(string: "TestPayload"),
                    properties: .init()
                ),
                packetId: 32768
            )
            try await channel.writeInboundPacket(publish, version: .v3_1_1)
            // read PUBACK
            let packet = try await channel.waitForOutboundPacket()
            let pubAck = try MQTTPubAckPacket.read(version: .v3_1_1, from: packet)
            #expect(pubAck.type == .PUBACK)
            #expect(pubAck.packetId == publish.packetId)
        }
    }

    @Test
    func testSubscribeAndPublishQoS2() async throws {
        try await testSubscribe(subscribeInfos: [.init(topicFilter: "testTopic", qos: .exactlyOnce)]) { sub in
            var iterator = sub.makeAsyncIterator()
            let event = try #require(try await iterator.next())
            #expect(event.payload == ByteBuffer(string: "TestPayload"))
        } server: { channel in
            // send PUBLISH
            let publish = MQTTPublishPacket(
                publish: .init(
                    qos: .exactlyOnce,
                    retain: false,
                    topicName: "testTopic",
                    payload: ByteBuffer(string: "TestPayload"),
                    properties: .init()
                ),
                packetId: 32768
            )
            try await channel.writeInboundPacket(publish, version: .v3_1_1)
            // read PUBREC
            var packet = try await channel.waitForOutboundPacket()
            let pubAck = try MQTTPubAckPacket.read(version: .v3_1_1, from: packet)
            #expect(pubAck.type == .PUBREC)
            #expect(pubAck.packetId == publish.packetId)
            // write PUBREL
            let pubRel = MQTTPubAckPacket(type: .PUBREL, packetId: pubAck.packetId)
            try await channel.writeInboundPacket(pubRel, version: .v3_1_1)
            // read PUBCOMP
            packet = try await channel.waitForOutboundPacket()
            let pubComp = try MQTTPubAckPacket.read(version: .v3_1_1, from: packet)
            #expect(pubComp.type == .PUBCOMP)
            #expect(pubComp.packetId == publish.packetId)
        }
    }

    @Test
    func testTopicFilter() async throws {
        try await testSubscribe(subscribeInfos: [.init(topicFilter: "testTopic/+", qos: .atMostOnce)]) { sub in
            var iterator = sub.makeAsyncIterator()
            let event = try #require(try await iterator.next())
            #expect(event.payload == ByteBuffer(string: "TestPayload2"))
            #expect(event.topicName == "testTopic/that")
        } server: { channel in
            // send PUBLISH (This should be ignore as the topic name isn't covered by the subcribe topic filter)
            let publish = MQTTPublishPacket(
                publish: .init(
                    qos: .atMostOnce,
                    retain: false,
                    topicName: "testTopic2/this",
                    payload: ByteBuffer(string: "TestPayload1"),
                    properties: .init()
                ),
                packetId: 32768
            )
            try await channel.writeInboundPacket(publish, version: .v3_1_1)
            // send PUBLISH
            let publish2 = MQTTPublishPacket(
                publish: .init(
                    qos: .atMostOnce,
                    retain: false,
                    topicName: "testTopic/that",
                    payload: ByteBuffer(string: "TestPayload2"),
                    properties: .init()
                ),
                packetId: 32769
            )
            try await channel.writeInboundPacket(publish2, version: .v3_1_1)
        }
    }

    @Test
    func testSubscriptionIdFilter() async throws {
        try await testSubscribeV5(
            subscribeInfos: [.init(topicFilter: "testTopic/+", qos: .atMostOnce)]
        ) { sub in
            var iterator = sub.makeAsyncIterator()
            let event = try #require(try await iterator.next())
            #expect(event.payload == ByteBuffer(string: "TestPayload2"))
            #expect(event.topicName == "testTopic/that")
        } server: { channel, subscriptionID in
            // send PUBLISH (This should be ignore as subscription id is wrong)
            let publish = MQTTPublishPacket(
                publish: .init(
                    qos: .atMostOnce,
                    retain: false,
                    topicName: "testTopic/this",
                    payload: ByteBuffer(string: "TestPayload1"),
                    properties: [.subscriptionIdentifier(subscriptionID + 1)]
                ),
                packetId: 32768
            )
            try await channel.writeInboundPacket(publish, version: .v5_0)
            // send PUBLISH
            let publish2 = MQTTPublishPacket(
                publish: .init(
                    qos: .atMostOnce,
                    retain: false,
                    topicName: "testTopic/that",
                    payload: ByteBuffer(string: "TestPayload2"),
                    properties: [.subscriptionIdentifier(subscriptionID)]
                ),
                packetId: 32769
            )
            try await channel.writeInboundPacket(publish2, version: .v5_0)
        }
    }
}

extension NIOAsyncTestingChannel {
    func waitForOutboundPacket() async throws -> MQTTIncomingPacket {
        var buffer = try await self.waitForOutboundWrite(as: ByteBuffer.self)
        return try MQTTIncomingPacket.read(from: &buffer)
    }

    func writeInboundPacket(_ packet: some MQTTPacket, version: MQTTConnectionConfiguration.Version) async throws {
        var buffer = ByteBuffer()
        try packet.write(version: version, to: &buffer)
        try await self.writeInbound(buffer)
    }
}
