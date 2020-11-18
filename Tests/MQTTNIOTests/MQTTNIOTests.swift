import XCTest
import NIO
import NIOSSL
@testable import MQTTNIO

final class MQTTNIOTests: XCTestCase {

    func createClient(cb: @escaping (Result<MQTTPublishInfo, Swift.Error>) -> () = { _ in }) -> MQTTClient {
        MQTTClient(host: "mqtt.eclipse.org", port: 1883, eventLoopGroupProvider: .createNew, publishCallback: cb)
    }
    func createWebSocketClient(cb: @escaping (Result<MQTTPublishInfo, Swift.Error>) -> () = { _ in }) -> MQTTClient {
        MQTTClient(
            host: "broker.hivemq.com",
            port: 8000,
            eventLoopGroupProvider: .createNew,
            configuration: .init(disablePingreq: true, useWebSockets: true, webSocketURLPath: "/mqtt"),
            publishCallback: cb
        )
    }
    func createSSLClient(cb: @escaping (Result<MQTTPublishInfo, Swift.Error>) -> () = { _ in }) -> MQTTClient {
        return MQTTClient(
            host: "mqtt.eclipse.org",
            eventLoopGroupProvider: .createNew,
            configuration: .init(useSSL: true),
            publishCallback: cb
        )
    }

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
        let client = self.createClient()
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully())}
        _ = try client.createBootstrap(pingreqTimeout: .seconds(10)).wait()
        Thread.sleep(forTimeInterval: 15)
    }

    func testWebsocketConnect() throws {
        let client = createWebSocketClient()
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully())}
        try connect(to: client, identifier: "connect")
        Thread.sleep(forTimeInterval: 30)
        try client.disconnect().wait()
    }

    func testSSLConnect() throws {
        let client = createSSLClient()
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully())}
        try connect(to: client, identifier: "connect")
        try client.disconnect().wait()
    }

    func testMQTTPublishQoS0() throws {
        let publish = MQTTPublishInfo(
            qos: .atMostOnce,
            retain: true,
            dup: false,
            topicName: "MyTopic",
            payload: ByteBufferAllocator().buffer(string: "Test payload")
        )

        let client = self.createClient()
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully())}
        try connect(to: client, identifier: "publisher")
        try client.publish(info: publish).wait()
        try client.disconnect().wait()
    }

    func testMQTTPublishQoS1() throws {
        let publish = MQTTPublishInfo(
            qos: .atLeastOnce,
            retain: true,
            dup: false,
            topicName: "MyTopic",
            payload: ByteBufferAllocator().buffer(string: "Test payload")
        )

        let client = self.createClient()
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully())}
        try connect(to: client, identifier: "publisher")
        try client.publish(info: publish).wait()
        try client.disconnect().wait()
    }

    func testMQTTPublishQoS2() throws {
        let publish = MQTTPublishInfo(
            qos: .exactlyOnce,
            retain: true,
            dup: false,
            topicName: "MyTopic",
            payload: ByteBufferAllocator().buffer(string: "Test payload")
        )
        
        let client = self.createClient()
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully())}
        try connect(to: client, identifier: "soto_publisher")
        try client.publish(info: publish).wait()
    }

    func testMQTTPingreq() throws {
        let client = self.createClient()
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully())}
        try connect(to: client, identifier: "soto_publisher")
        try client.pingreq().wait()
        try client.disconnect().wait()
    }

    func testMQTTSubscribe() throws {
        let client = self.createClient()
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully())}
        try connect(to: client, identifier: "soto_client")
        try client.subscribe(infos: [.init(qos: .atLeastOnce, topicFilter: "iphone")]).wait()
        Thread.sleep(forTimeInterval: 15)
        try client.disconnect().wait()
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
        let client = self.createWebSocketClient()
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully())}
        try connect(to: client, identifier: "soto_publisher")
        let client2 = self.createWebSocketClient() { result in
            switch result {
            case .success(let publish):
                print(publish)
                publishReceived.append(publish)
            case .failure(let error):
                print(error)
            }
        }
        defer { XCTAssertNoThrow(try client2.syncShutdownGracefully())}
        try connect(to: client2, identifier: "soto_client")
        try client2.subscribe(infos: [.init(qos: .atLeastOnce, topicFilter: "testing-noretain")]).wait()
        try client.publish(info: publish).wait()
        Thread.sleep(forTimeInterval: 2)
        try client.publish(info: publish).wait()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(publishReceived.count, 2)
        try client.disconnect().wait()
        try client2.disconnect().wait()
    }
}
