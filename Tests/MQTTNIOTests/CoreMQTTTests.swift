//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2021 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import Testing

@testable import MQTTNIO

@Suite("Core MQTT Tests")
struct CoreMQTTTests {
    @Test("Connect")
    func connect() throws {
        let publish = MQTTPublishInfo(
            qos: .atMostOnce,
            retain: false,
            dup: false,
            topicName: "MyTopic",
            payload: ByteBufferAllocator().buffer(string: "Test payload"),
            properties: .init()
        )
        var byteBuffer = ByteBufferAllocator().buffer(capacity: 1024)
        let connectPacket = MQTTConnectPacket(
            cleanSession: true,
            keepAliveSeconds: 15,
            clientIdentifier: "MyClient",
            userName: nil,
            password: nil,
            properties: .init(),
            will: publish
        )
        try connectPacket.write(version: .v3_1_1, to: &byteBuffer)
        #expect(byteBuffer.readableBytes == 45)
    }

    @Test("Publish")
    func publish() throws {
        let publish = MQTTPublishInfo(
            qos: .atMostOnce,
            retain: false,
            dup: false,
            topicName: "MyTopic",
            payload: ByteBufferAllocator().buffer(string: "Test payload"),
            properties: .init()
        )
        var byteBuffer = ByteBufferAllocator().buffer(capacity: 1024)
        let publishPacket = MQTTPublishPacket(publish: publish, packetId: 456)
        try publishPacket.write(version: .v3_1_1, to: &byteBuffer)
        let packet = try MQTTIncomingPacket.read(from: &byteBuffer)
        let publish2 = try MQTTPublishPacket.read(version: .v3_1_1, from: packet)
        #expect(publish.topicName == publish2.publish.topicName)
        #expect(publish.payload == publish2.publish.payload)
    }

    @Test("Subscribe")
    func subscribe() throws {
        let subscriptions: [MQTTSubscribeInfoV5] = [
            .init(topicFilter: "topic/cars", qos: .atLeastOnce),
            .init(topicFilter: "topic/buses", qos: .atLeastOnce),
        ]
        var byteBuffer = ByteBufferAllocator().buffer(capacity: 1024)
        let subscribePacket = MQTTSubscribePacket(subscriptions: subscriptions, properties: nil, packetId: 456)
        try subscribePacket.write(version: .v3_1_1, to: &byteBuffer)
        let packet = try MQTTIncomingPacket.read(from: &byteBuffer)
        #expect(packet.remainingData.readableBytes == 29)
    }
}
