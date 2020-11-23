import XCTest
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOSSL
@testable import MQTTNIO

final class MQTTNIOTests: XCTestCase {

    func connect(to client: MQTTClient) throws {
        try client.connect().wait()
    }

    func testConnectWithWill() throws {
        let client = createClient(identifier: "testConnectWithWill")
        try client.connect(
            will: (topicName: "MyWillTopic", payload: ByteBufferAllocator().buffer(string: "Test payload"), retain: false)
        ).wait()
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }
    
    func testWebsocketConnect() throws {
        let client = createWebSocketClient(identifier: "testWebsocketConnect")
        try client.connect().wait()
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testSSLConnect() throws {
        let client = try createSSLClient(identifier: "testSSLConnect")
        try client.connect().wait()
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testWebsocketAndSSLConnect() throws {
        let client = try createWebSocketAndSSLClient(identifier: "testWebsocketAndSSLConnect")
        try client.connect().wait()
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishQoS0() throws {
        let client = self.createClient(identifier: "testMQTTPublishQoS0")
        try client.connect().wait()
        try client.publish(to: "testMQTTPublishQoS", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .atMostOnce).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishQoS1() throws {
        let client = try self.createSSLClient(identifier: "testMQTTPublishQoS1")
        try client.connect().wait()
        try client.publish(to: "testMQTTPublishQoS", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .atLeastOnce).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishQoS2() throws {
        let client = try self.createWebSocketAndSSLClient(identifier: "testMQTTPublishQoS2")
        try client.connect().wait()
        try client.publish(to: "testMQTTPublishQoS", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .exactlyOnce).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPingreq() throws {
        let client = self.createClient(identifier: "testMQTTPingreq")
        try client.connect().wait()
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTSubscribe() throws {
        let client = self.createClient(identifier: "testMQTTSubscribe")
        try client.connect().wait()
        try client.subscribe(to: [.init(topicFilter: "iphone", qos: .atLeastOnce)]).wait()
        Thread.sleep(forTimeInterval: 15)
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishToClient() throws {
        let lock = Lock()
        var publishReceived: [MQTTPublishInfo] = []
        let payload = ByteBufferAllocator().buffer(string: "This is the Test payload")

        let client = self.createWebSocketClient(identifier: "testMQTTPublishToClient_publisher")
        try client.connect().wait()
        let client2 = self.createWebSocketClient(identifier: "testMQTTPublishToClient_subscriber")
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
        try client2.connect().wait()
        try client2.subscribe(to: [.init(topicFilter: "testMQTTPublishToClient", qos: .atLeastOnce)]).wait()
        try client.publish(to: "testMQTTPublishToClient", payload: payload, qos: .atLeastOnce).wait()
        try client.publish(to: "testMQTTPublishToClient", payload: payload, qos: .atLeastOnce).wait()
        Thread.sleep(forTimeInterval: 2)
        lock.withLock {
            XCTAssertEqual(publishReceived.count, 2)
        }
        try client.disconnect().wait()
        try client2.disconnect().wait()
        try client.syncShutdownGracefully()
        try client2.syncShutdownGracefully()
    }

    func testCloseListener() throws {
        let disconnected = NIOAtomic<Bool>.makeAtomic(value: false)
        let client = self.createWebSocketClient(identifier: "testReconnect")
        let client2 = self.createWebSocketClient(identifier: "testReconnect")

        client.addCloseListener(named: "Reconnect") { result in
            switch result {
            case .failure(let error):
                XCTFail("\(error)")
            case .success:
                disconnected.store(true)
            }
        }

        try client.connect().wait()
        // by connecting with same identifier the first client uses the first client is forced to disconnect
        try client2.connect().wait()

        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(disconnected.load())
        
        try client2.disconnect().wait()
        try client.syncShutdownGracefully()
        try client2.syncShutdownGracefully()
    }
    
    // MARK: Helper variables and functions

    func createClient(identifier: String) -> MQTTClient {
        MQTTClient(
            host: "localhost",
            port: 1883,
            identifier: identifier,
            eventLoopGroupProvider: .createNew,
            logger: self.logger
        )
    }

    func createWebSocketClient(identifier: String) -> MQTTClient {
        MQTTClient(
            host: "localhost",
            port: 8080,
            identifier: identifier,
            eventLoopGroupProvider: .createNew,
            logger: self.logger,
            configuration: .init(useWebSockets: true, webSocketURLPath: "/mqtt")
        )
    }

    func createSSLClient(identifier: String) throws -> MQTTClient {
        return try MQTTClient(
            host: "localhost",
            port: 8883,
            identifier: identifier,
            eventLoopGroupProvider: .createNew,
            logger: self.logger,
            configuration: .init(useSSL: true, tlsConfiguration: Self.getTLSConfiguration(withClientKey: false))
        )
    }

    func createWebSocketAndSSLClient(identifier: String) throws -> MQTTClient {
        return try MQTTClient(
            host: "localhost",
            port: 8081,
            identifier: identifier,
            eventLoopGroupProvider: .createNew,
            logger: self.logger,
            configuration: .init(useSSL: true, useWebSockets: true, tlsConfiguration: Self.getTLSConfiguration(), webSocketURLPath: "/mqtt")
        )
    }

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
    
    static func getTLSConfiguration(withTrustRoots: Bool = true, withClientKey: Bool = true) throws -> TLSConfiguration {
        switch _tlsConfiguration {
        case .success(let config):
            return TLSConfiguration.forClient(
                trustRoots: withTrustRoots == true ? (config.trustRoots ?? .default) : .default,
                certificateChain: withClientKey ? config.certificateChain : [],
                privateKey: withClientKey ? config.privateKey : nil
            )
        case .failure(let error):
            throw error
        }
    }
}
