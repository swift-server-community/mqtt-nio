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
    @Test("Connect Packet")
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

    @Test("Publish Packet")
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

    @Test("Subscribe Packet")
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

    @Test(
        "TopicFilter",
        arguments: [
            "home/+/temperature",
            "home/garden/#",
            "office/+/humidity",
            "#",
            "office/room1#",
            "sport/+",
            "sport+",
            "+/+",
            "+",
            "/+",
        ]
    )
    func topicFilter(topicFilter: String) {
        #expect(throws: Never.self) { try TopicFilter(topicFilter) }
    }

    @Test("Invalid TopicFilter", arguments: ["home/#/temperature", "sport/tennis/#/ranking", "#/office"])
    func invalidTopicFilter(topicFilter: String) {
        #expect(throws: MQTTError.invalidTopicFilter(topicFilter)) { try TopicFilter(topicFilter) }
    }

    @Test("Dictionary+topicName")
    func dictionaryTopicName() throws {
        let subscriptionMap = [
            try TopicFilter("home/+/temperature"): "Subscription1",
            try TopicFilter("home/garden/#"): "Subscription2",
            try TopicFilter("office/+/humidity"): "Subscription3",
            try TopicFilter("#"): "Subscription4",
            try TopicFilter("office/room1#"): "Subscription5",
            try TopicFilter("sport/+"): "Subscription7",
            try TopicFilter("sport+"): "Subscription8",
            try TopicFilter("+/+"): "Subscription9",
            try TopicFilter("+"): "Subscription10",
            try TopicFilter("/+"): "Subscription11",
        ]
        #expect(subscriptionMap[topicName: "home/livingroom/temperature"].count == 2)
        #expect(subscriptionMap[topicName: "home/garden/humidity"].count == 2)
        #expect(subscriptionMap[topicName: "office/room1/humidity"].count == 2)
        #expect(subscriptionMap[topicName: "home/garden"].count == 3)
        #expect(subscriptionMap[topicName: "home/garden/temperature/soil"].count == 2)
        #expect(subscriptionMap[topicName: "office/room1"].count == 2)
        #expect(subscriptionMap[topicName: "sport/tennis/player1/ranking"].count == 1)
        #expect(subscriptionMap[topicName: "sport/tennis"].count == 3)
        #expect(subscriptionMap[topicName: "sport"].count == 2)
        #expect(subscriptionMap[topicName: "sport/"].count == 3)
        #expect(subscriptionMap[topicName: "/finance"].count == 3)
    }
}

extension MQTTError: Equatable {
    public static func == (lhs: MQTTError, rhs: MQTTError) -> Bool {
        switch (lhs, rhs) {
        case (.failedToConnect, .failedToConnect),
            (.connectionClosed, .connectionClosed),
            (.serverClosedConnection, .serverClosedConnection),
            (.unexpectedMessage, .unexpectedMessage),
            (.decodeError, .decodeError),
            (.websocketUpgradeFailed, .websocketUpgradeFailed),
            (.timeout, .timeout),
            (.retrySend, .retrySend),
            (.wrongTLSConfig, .wrongTLSConfig),
            (.badResponse, .badResponse),
            (.unrecognisedPacketType, .unrecognisedPacketType),
            (.authWorkflowRequired, .authWorkflowRequired),
            (.serverDisconnection, .serverDisconnection),
            (.cancelledTask, .cancelledTask):
            true
        case (.connectionError(let lhsValue), .connectionError(let rhsValue)):
            lhsValue == rhsValue
        case (.reasonError(let lhsValue), .reasonError(let rhsValue)):
            lhsValue == rhsValue
        case (.versionMismatch(let expectedLHS, let actualLHS), .versionMismatch(let expectedRHS, let actualRHS)):
            expectedLHS == expectedRHS && actualLHS == actualRHS
        case (.invalidTopicFilter(let lhsValue), .invalidTopicFilter(let rhsValue)):
            lhsValue == rhsValue
        default:
            false
        }
    }
}
