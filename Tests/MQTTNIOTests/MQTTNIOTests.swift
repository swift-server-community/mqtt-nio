import XCTest
import NIO
import NIOSSL
@testable import MQTTNIO

final class MQTTNIOTests: XCTestCase {

    func connect(to client: MQTTClient, identifier: String) throws {
        let connect = MQTTConnectInfo(
            cleanSession: true,
            keepAliveSeconds: 15,
            clientIdentifier: identifier,
            userName: "",
            password: ""
        )
        try client.connect(info: connect).wait()
    }

    func testBootstrap() throws {
        let client = try MQTTClient(host: "test.mosquitto.org", port: 8080, eventLoopGroupProvider: .createNew)
        let bootstrap = try client.createBootstrap().wait()
        try client.syncShutdownGracefully()
    }

    func testConnect() throws {
        let client = try MQTTClient(host: "test.mosquitto.org", port: 8080, eventLoopGroupProvider: .createNew)
        try connect(to: client, identifier: "connect")
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testSSLConnect() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try MQTTClient(host: "mqtt.eclipse.org", eventLoopGroupProvider: .shared(eventLoopGroup))
        try connect(to: client, identifier: "connect")
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishQoS0() throws {
        let publish = MQTTPublishInfo(
            qos: .atMostOnce,
            retain: true,
            dup: false,
            topicName: "MyTopic",
            payload: ByteBufferAllocator().buffer(string: "Test payload")
        )

        let client = try MQTTClient(host: "mqtt.eclipse.org", port: 1883, eventLoopGroupProvider: .createNew)
        try connect(to: client, identifier: "publisher")
        try client.publish(info: publish).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishQoS1() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let publish = MQTTPublishInfo(
            qos: .atLeastOnce,
            retain: true,
            dup: false,
            topicName: "MyTopic",
            payload: ByteBufferAllocator().buffer(string: "Test payload")
        )

        let client = try MQTTClient(host: "mqtt.eclipse.org", port: 1883, eventLoopGroupProvider: .shared(eventLoopGroup))
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
        
        let client = try MQTTClient(host: "mqtt.eclipse.org", port: 1883, eventLoopGroupProvider: .createNew)
        try connect(to: client, identifier: "soto_publisher")
        try client.publish(info: publish).wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPingreq() throws {
        let client = try MQTTClient(host: "mqtt.eclipse.org", port: 1883, eventLoopGroupProvider: .createNew)
        try connect(to: client, identifier: "soto_publisher")
        try client.pingreq().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTSubscribe() throws {
        let client = try MQTTClient(host: "mqtt.eclipse.org", port: 1883, eventLoopGroupProvider: .createNew)
        try connect(to: client, identifier: "soto_client")
        try client.subscribe(infos: [.init(qos: .atLeastOnce, topicFilter: "iphone")]).wait()
        Thread.sleep(forTimeInterval: 30)
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishToClient() throws {
        var publishReceived: [MQTTPublishInfo] = []
        let publish = MQTTPublishInfo(
            qos: .atLeastOnce,
            retain: false,
            dup: false,
            topicName: "testing-noretain",
            payload: ByteBufferAllocator().buffer(string: "This is the Test payload")
        )
        let client = try MQTTClient(host: "mqtt.eclipse.org", port: 1883, eventLoopGroupProvider: .createNew)
        try connect(to: client, identifier: "soto_publisher")
        let client2 = try MQTTClient(host: "mqtt.eclipse.org", port: 1883, eventLoopGroupProvider: .createNew) { result in
            switch result {
            case .success(let publish):
                print(publish)
                publishReceived.append(publish)
            case .failure(let error):
                print(error)
            }
        }
        try connect(to: client2, identifier: "soto_client")
        try client2.subscribe(infos: [.init(qos: .atLeastOnce, topicFilter: "testing-noretain")]).wait()
        try client.publish(info: publish).wait()
        Thread.sleep(forTimeInterval: 2)
        try client.publish(info: publish).wait()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(publishReceived.count, 2)
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
        try client2.disconnect().wait()
        try client2.syncShutdownGracefully()
    }
}
