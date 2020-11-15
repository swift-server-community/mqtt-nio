import XCTest
import NIO
@testable import MQTTNIO

final class MQTTNIOTests: XCTestCase {
    
    func connect(to client: MQTTClient) throws {
        let connect = MQTTConnectInfo(
            cleanSession: true,
            keepAliveSeconds: 5,
            clientIdentifier: "server",
            userName: "",
            password: ""
        )
        try client.connect(info: connect).wait()
    }
    
    func testMQTTPublishQoS1() throws {
        let publish = MQTTPublishInfo(
            qos: .atLeastOnce,
            retain: true,
            dup: false,
            topicName: "MyTopic",
            payload: ByteBufferAllocator().buffer(string: "Test payload")
        )
        
        let client = try MQTTClient(host: "test.mosquitto.org", port: 1883)
        try connect(to: client)
        try client.publish(info: publish).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishQoS2() throws {
        let publish = MQTTPublishInfo(
            qos: .exactlyOnce,
            retain: true,
            dup: false,
            topicName: "MyTopic",
            payload: ByteBufferAllocator().buffer(string: "Test payload")
        )
        
        let client = try MQTTClient(host: "test.mosquitto.org", port: 1883)
        try connect(to: client)
        try client.publish(info: publish).wait()
        try client.syncShutdownGracefully()
    }
}
