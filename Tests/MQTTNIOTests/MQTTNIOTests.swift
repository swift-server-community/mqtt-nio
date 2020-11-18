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
            configuration: .init(useWebSockets: true, webSocketURLPath: "/mqtt"),
            publishCallback: cb
        )
    }
    func createSSLClient(cb: @escaping (Result<MQTTPublishInfo, Swift.Error>) -> () = { _ in }) -> MQTTClient {
        let tlsConfiguration: TLSConfiguration? = nil //TLSConfiguration.forClient(certificateChain: certificate.map {.certificate($0)}, privateKey: .privateKey(privateKey))
        return MQTTClient(
            host: "broker.emqx.io",
            eventLoopGroupProvider: .createNew,
            configuration: .init(useSSL: true, tlsConfiguration: tlsConfiguration),
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
        _ = try client.createBootstrap(pingreqTimeout: .seconds(10)).wait()
        Thread.sleep(forTimeInterval: 10)
        try client.syncShutdownGracefully()
    }

    func testWebsocketConnect() throws {
        let client = createWebSocketClient()
        try connect(to: client, identifier: "connect")
        try client.pingreq().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testSSLConnect() throws {
        let client = createSSLClient()
        try connect(to: client, identifier: "connect")
        try client.pingreq().wait()
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

        let client = self.createClient()
        try connect(to: client, identifier: "publisher")
        try client.publish(info: publish).wait()
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

        let client = self.createClient()
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
        
        let client = self.createClient()
        try connect(to: client, identifier: "soto_publisher")
        try client.publish(info: publish).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPingreq() throws {
        let client = self.createClient()
        try connect(to: client, identifier: "soto_publisher")
        try client.pingreq().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTSubscribe() throws {
        let client = self.createClient()
        try connect(to: client, identifier: "soto_client")
        try client.subscribe(infos: [.init(qos: .atLeastOnce, topicFilter: "iphone")]).wait()
        Thread.sleep(forTimeInterval: 15)
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
        let client = self.createWebSocketClient()
        try connect(to: client, identifier: "soto_publisher")
        let client2 = self.createWebSocketClient() { result in
            switch result {
            case .success(let publish):
                var buffer = publish.payload
                let string = buffer.readString(length: buffer.readableBytes)
                XCTAssertEqual(string, "This is the Test payload")
                publishReceived.append(publish)
            case .failure(let error):
                XCTFail("\(error)")
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
        try client2.disconnect().wait()
        try client.syncShutdownGracefully()
        try client2.syncShutdownGracefully()
    }
}
