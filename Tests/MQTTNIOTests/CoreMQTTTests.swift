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
        let packet = try MQTTSerializer.getIncomingPacket(from: &byteBuffer)
        let publish2 = try MQTTSerializer.readPublish(from: packet)
        XCTAssertEqual(publish.topicName, publish2.publishInfo.topicName)
        XCTAssertEqual(publish.payload.getString(at: publish.payload.readerIndex, length: 10), publish2.publishInfo.payload.getString(at: publish2.publishInfo.payload.readerIndex, length: 10))
    }
}

public extension Sequence where Element == UInt8 {
    /// return a hexEncoded string buffer from an array of bytes
    func hexDigest() -> String {
        return self.map { String(format: "%02x", $0) }.joined(separator: "")
    }
}
