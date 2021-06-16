import XCTest
import NIO
@testable import MQTTNIO

final class CoreMQTTTests: XCTestCase {
    func testConnect() throws {
        let connect = MQTTConnectInfo(
            cleanSession: true,
            keepAliveSeconds: 15,
            clientIdentifier: "MyClient",
            userName: "",
            password: ""
        )
        let publish = MQTTPublishInfo(
            qos: .atMostOnce,
            retain: false,
            dup: false,
            topicName: "MyTopic",
            payload: ByteBufferAllocator().buffer(string: "Test payload")
        )
        var byteBuffer = ByteBufferAllocator().buffer(capacity: 1024)
        try MQTTSerializer.writeConnect(connectInfo: connect, willInfo: publish, to: &byteBuffer)
        XCTAssertEqual(byteBuffer.readableBytes, 45)
    }

    func testPublish() throws {
        let publish = MQTTPublishInfo(
            qos: .atMostOnce,
            retain: false,
            dup: false,
            topicName: "MyTopic",
            payload: ByteBufferAllocator().buffer(string: "Test payload")
        )
        var byteBuffer = ByteBufferAllocator().buffer(capacity: 1024)
        try MQTTSerializer.writePublish(publishInfo: publish, packetId: 456, to: &byteBuffer)
        let packet = try MQTTSerializer.readIncomingPacket(from: &byteBuffer)
        let publish2 = try MQTTSerializer.readPublish(from: packet)
        XCTAssertEqual(publish.topicName, publish2.publishInfo.topicName)
        XCTAssertEqual(publish.payload.getString(at: publish.payload.readerIndex, length: 12), publish2.publishInfo.payload.getString(at: publish2.publishInfo.payload.readerIndex, length: 12))
    }

    func testSubscribe() throws {
        let subscriptions: [MQTTSubscribeInfo] = [
            .init(topicFilter: "topic/cars", qos: .atLeastOnce),
            .init(topicFilter: "topic/buses", qos: .atLeastOnce),
        ]
        var byteBuffer = ByteBufferAllocator().buffer(capacity: 1024)
        try MQTTSerializer.writeSubscribe(subscribeInfos: subscriptions, packetId: 456, to: &byteBuffer)
        let packet = try MQTTSerializer.readIncomingPacket(from: &byteBuffer)
        XCTAssertEqual(packet.remainingData.readableBytes, 29)
    }
}

