import XCTest
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOSSL
@testable import MQTTNIO

final class MQTTNIOTests: XCTestCase {
    
    func createClient() -> MQTTClient {
        MQTTClient(
            host: "localhost",
            port: 1883,
            eventLoopGroupProvider: .createNew,
            logger: self.logger
        )
    }
    
    func createWebSocketClient() -> MQTTClient {
        MQTTClient(
            host: "localhost",
            port: 8080,
            eventLoopGroupProvider: .createNew,
            logger: self.logger,
            configuration: .init(useWebSockets: true, webSocketURLPath: "/mqtt")
        )
    }

    func createSSLClient() throws -> MQTTClient {
        return try MQTTClient(
            host: "localhost",
            port: 8883,
            eventLoopGroupProvider: .createNew,
            logger: self.logger,
            configuration: .init(useSSL: true, tlsConfiguration: Self.getTLSConfiguration())
        )
    }

    func createWebSocketAndSSLClient() throws -> MQTTClient {
        return try MQTTClient(
            host: "localhost",
            port: 8081,
            eventLoopGroupProvider: .createNew,
            logger: self.logger,
            configuration: .init(useSSL: true, useWebSockets: true, tlsConfiguration: Self.getTLSConfiguration(), webSocketURLPath: "/mqtt")
        )
    }

    func connect(to client: MQTTClient, identifier: String) throws {
        let connect = MQTTConnectInfo(
            cleanSession: true,
            keepAliveSeconds: 15,
            clientIdentifier: identifier
        )
        try client.connect(info: connect).wait()
    }

    func testWebsocketConnect() throws {
        let client = createWebSocketClient()
        try connect(to: client, identifier: "connect")
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testSSLConnect() throws {
        let client = try createSSLClient()
        try connect(to: client, identifier: "connect")
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testWebsocketAndSSLConnect() throws {
        let client = try createWebSocketAndSSLClient()
        try connect(to: client, identifier: "connect")
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishQoS0() throws {
        let publish = MQTTPublishInfo(
            qos: .atMostOnce,
            retain: true,
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
            topicName: "MyTopic",
            payload: ByteBufferAllocator().buffer(string: "Test payload")
        )

        let client = try self.createSSLClient()
        try connect(to: client, identifier: "publisher")
        try client.publish(info: publish).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishQoS2() throws {
        let publish = MQTTPublishInfo(
            qos: .exactlyOnce,
            retain: true,
            topicName: "MyTopic",
            payload: ByteBufferAllocator().buffer(string: "Test payload")
        )
        
        let client = try self.createWebSocketAndSSLClient()
        try connect(to: client, identifier: "soto_publisher")
        try client.publish(info: publish).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPingreq() throws {
        let client = self.createClient()
        try connect(to: client, identifier: "soto_publisher")
        try client.ping().wait()
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
        let lock = Lock()
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
        let client2 = self.createWebSocketClient()
        client2.addPublishListener(named: "test") { result in
            switch result {
            case .success(let publish):
                var buffer = publish.payload
                let string = buffer.readString(length: buffer.readableBytes)
                XCTAssertEqual(string, "This is the Test payload")
                lock.withLock {
                    publishReceived.append(publish)
                }
            case .failure(let error):
                XCTFail("\(error)")
            }
        }
        try connect(to: client2, identifier: "soto_client")
        try client2.subscribe(infos: [.init(qos: .atLeastOnce, topicFilter: "testing-noretain")]).wait()
        try client.publish(info: publish).wait()
        try client.publish(info: publish).wait()
        Thread.sleep(forTimeInterval: 2)
        lock.withLock {
            XCTAssertEqual(publishReceived.count, 2)
        }
        try client.disconnect().wait()
        try client2.disconnect().wait()
        try client.syncShutdownGracefully()
        try client2.syncShutdownGracefully()
    }

    // MARK: Helper variables and functions
    
    let logger: Logger = {
        var logger = Logger(label: "MQTTTests")
        logger.logLevel = .trace
        return logger
    }()

    static var rootPath: String = {
        return #file
            .split(separator: "/", omittingEmptySubsequences: false)
            .dropLast(3)
            .map { String(describing: $0) }
            .joined(separator: "/")
    }()

    static var _tlsConfiguration: Result<TLSConfiguration, Error> = {
        do {
            let rootCertificate = try NIOSSLCertificate.fromPEMFile(MQTTNIOTests.rootPath + "/mosquitto/certs/ca.crt")
            let certificate = try NIOSSLCertificate.fromPEMFile(MQTTNIOTests.rootPath + "/mosquitto/certs/client.crt")
            let privateKey = try NIOSSLPrivateKey(file: MQTTNIOTests.rootPath + "/mosquitto/certs/client.key", format: .pem)
            let tlsConfiguration = TLSConfiguration.forClient(
                trustRoots: .certificates(rootCertificate),
                certificateChain: certificate.map{ .certificate($0) },
                privateKey: .privateKey(privateKey)
            )
            return .success(tlsConfiguration)
        } catch {
            return .failure(error)
        }
    }()
    
    static func getTLSConfiguration() throws -> TLSConfiguration {
        switch _tlsConfiguration {
        case .success(let config):
            return config
        case .failure(let error):
            throw error
        }
    }
}
