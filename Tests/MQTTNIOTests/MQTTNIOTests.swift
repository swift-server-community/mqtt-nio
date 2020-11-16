import XCTest
import NIO
import NIOSSL
@testable import MQTTNIO

final class MQTTNIOTests: XCTestCase {
    
    func connect(to client: MQTTClient, identifier: String) throws {
        let connect = MQTTConnectInfo(
            cleanSession: true,
            keepAliveSeconds: 10,
            clientIdentifier: identifier,
            userName: "",
            password: ""
        )
        try client.connect(info: connect).wait()
    }
    
    func testConnect() throws {
        let client = try MQTTClient(host: "test.mosquitto.org", port: 1883)
        try connect(to: client, identifier: "connect")
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testSSLConnect() throws {
        let tlsConfiguration = TLSConfiguration.forClient()
        let client = try MQTTClient(host: "mqtt.eclipse.org", port: 8883, ssl: true, tlsConfiguration: tlsConfiguration)
        try connect(to: client, identifier: "connect")
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
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
        try connect(to: client, identifier: "publisher")
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
        try connect(to: client, identifier: "soto_publisher")
        try client.publish(info: publish).wait()
        try client.syncShutdownGracefully()
    }
    
    func testMQTTPublishToClient() throws {
        var publishReceived: [MQTTPublishInfo] = []
        let publish = MQTTPublishInfo(
            qos: .atLeastOnce,
            retain: true,
            dup: false,
            topicName: "sys",
            payload: ByteBufferAllocator().buffer(string: "Test payload")
        )
        let client = try MQTTClient(host: "mqtt.eclipse.org", port: 1883)
        try connect(to: client, identifier: "soto_publisher")
        let client2 = try MQTTClient(host: "mqtt.eclipse.org", port: 1883) { publish in
            publishReceived.append(publish)
        }
        try connect(to: client2, identifier: "soto_client")
        try client2.subscribe(infos: [.init(qos: .atLeastOnce, topicFilter: "sys")]).wait()
        try client.publish(info: publish).wait()
        Thread.sleep(forTimeInterval: 1)
        try client.publish(info: publish).wait()
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(publishReceived.count, 2)
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
        try client2.disconnect().wait()
        try client2.syncShutdownGracefully()
    }
}
