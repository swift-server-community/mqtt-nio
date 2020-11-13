import XCTest
import NIO
@testable import MQTTNIO

final class MQTTNIOTests: XCTestCase {
    func testExample() throws {
        let server = try EchoServer()
        let client = try MQTTClient()
        //print(result)
        //try client.post("This is the second test")
        try server.syncShutdownGracefully()
    }

    func testMQTT() throws {
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
        let client = try MQTTClient()
        try client.connect(info: connect).wait()
        try client.publish(info: publish).wait()
    }

    func testPublish() throws {
        let publish = MQTTPublishInfo(
            qos: .atMostOnce,
            retain: false,
            dup: false,
            topicName: "MyTopic",
            payload: ByteBufferAllocator().buffer(string: "Test payload")
        )
        let client = try MQTTClient()
        try client.publish(info: publish).wait()

    }
}
