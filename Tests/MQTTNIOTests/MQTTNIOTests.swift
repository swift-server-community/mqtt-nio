import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOHTTP1
import XCTest
#if canImport(NIOSSL)
import NIOSSL
#endif
@testable import MQTTNIO

final class MQTTNIOTests: XCTestCase {
    static let hostname = ProcessInfo.processInfo.environment["MOSQUITTO_SERVER"] ?? "localhost"

    func testConnectWithWill() throws {
        let client = self.createClient(identifier: "testConnectWithWill")
        _ = try client.connect(
            will: (topicName: "MyWillTopic", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .atLeastOnce, retain: false)
        ).wait()
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testConnectWithUsernameAndPassword() throws {
        let client = self.createClient(identifier: "testConnectWithWill", configuration: .init(userName: "adam", password: "password123"))
        _ = try client.connect().wait()
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testWebsocketConnect() throws {
        let client = self.createWebSocketClient(identifier: "testWebsocketConnect")
        _ = try client.connect().wait()
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    #if canImport(NIOSSL)
    func testSSLConnect() throws {
        let client = try createSSLClient(identifier: "testSSLConnect")
        _ = try client.connect().wait()
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testWebsocketAndSSLConnect() throws {
        let client = try createWebSocketAndSSLClient(identifier: "testWebsocketAndSSLConnect")
        _ = try client.connect().wait()
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }
    #endif

    func testMQTTPublishQoS0() throws {
        let client = self.createClient(identifier: "testMQTTPublishQoS0")
        _ = try client.connect().wait()
        try client.publish(to: "testMQTTPublishQoS", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .atMostOnce).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishQoS1() throws {
        let client = self.createClient(identifier: "testMQTTPublishQoS1")
        _ = try client.connect().wait()
        try client.publish(to: "testMQTTPublishQoS", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .atLeastOnce).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishQoS2() throws {
        let client = self.createWebSocketClient(identifier: "testMQTTPublishQoS2")
        _ = try client.connect().wait()
        try client.publish(to: "testMQTTPublishQoS", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .exactlyOnce).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPingreq() throws {
        let client = self.createClient(identifier: "testMQTTPingreq")
        _ = try client.connect().wait()
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTSubscribe() throws {
        let client = self.createClient(identifier: "testMQTTSubscribe")
        _ = try client.connect().wait()
        let sub = try client.subscribe(
            to: [
                .init(topicFilter: "iphone", qos: .atLeastOnce),
                .init(topicFilter: "iphone2", qos: .exactlyOnce)
            ]
        ).wait()
        XCTAssertEqual(sub.returnCodes[0], .grantedQoS1)
        XCTAssertEqual(sub.returnCodes[1], .grantedQoS2)
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTServerDisconnect() throws {
        struct MQTTForceDisconnectMessage: MQTTPacket {
            var type: MQTTPacketType { .PUBLISH }
            var description: String { "FORCEDISCONNECT" }

            func write(version: MQTTClient.Version, to byteBuffer: inout ByteBuffer) throws {
                // writing publish header with no content will cause a disconnect from the server
                byteBuffer.writeInteger(UInt8(0x30))
                byteBuffer.writeInteger(UInt8(0x0))
            }

            static func read(version: MQTTClient.Version, from packet: MQTTIncomingPacket) throws -> Self {
                throw InternalError.notImplemented
            }
        }

        let client = self.createClient(identifier: "testMQTTServerDisconnect")
        _ = try client.connect().wait()
        try client.connection?.sendMessageNoWait(MQTTForceDisconnectMessage()).wait()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(client.isActive())
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishRetain() throws {
        let lock = Lock()
        var publishReceived: [MQTTPublishInfo] = []
        let payloadString = #"{"from":1000000,"to":1234567,"type":1,"content":"I am a beginner in swift and I am studying hard!!测试\n\n test, message","timestamp":1607243024,"nonce":"pAx2EsUuXrVuiIU3GGOGHNbUjzRRdT5b","sign":"ff902e31a6a5f5343d70a3a93ac9f946adf1caccab539c6f3a6"}"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        let client = self.createWebSocketClient(identifier: "testMQTTPublishToClient_publisher")
        _ = try client.connect().wait()
        client.addPublishListener(named: "test") { result in
            switch result {
            case .success(let publish):
                var buffer = publish.payload
                let string = buffer.readString(length: buffer.readableBytes)
                XCTAssertEqual(string, payloadString)
                lock.withLock {
                    publishReceived.append(publish)
                }
            case .failure(let error):
                XCTFail("\(error)")
            }
        }
        try client.publish(to: "testMQTTPublishRetain", payload: payload, qos: .atLeastOnce, retain: true).wait()
        _ = try client.subscribe(to: [.init(topicFilter: "testMQTTPublishRetain", qos: .atLeastOnce)]).wait()
        Thread.sleep(forTimeInterval: 2)
        lock.withLock {
            XCTAssertEqual(publishReceived.count, 1)
        }
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTPublishToClient() throws {
        let lock = Lock()
        var publishReceived: [MQTTPublishInfo] = []
        let payloadString = #"{"from":1000000,"to":1234567,"type":1,"content":"I am a beginner in swift and I am studying hard!!测试\n\n test, message","timestamp":1607243024,"nonce":"pAx2EsUuXrVuiIU3GGOGHNbUjzRRdT5b","sign":"ff902e31a6a5f5343d70a3a93ac9f946adf1caccab539c6f3a6"}"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        let client = self.createWebSocketClient(identifier: "testMQTTPublishToClient_publisher")
        _ = try client.connect().wait()
        let client2 = self.createWebSocketClient(identifier: "testMQTTPublishToClient_subscriber")
        client2.addPublishListener(named: "test") { result in
            switch result {
            case .success(let publish):
                var buffer = publish.payload
                let string = buffer.readString(length: buffer.readableBytes)
                XCTAssertEqual(string, payloadString)
                lock.withLock {
                    publishReceived.append(publish)
                }
            case .failure(let error):
                XCTFail("\(error)")
            }
        }
        _ = try client2.connect().wait()
        _ = try client2.subscribe(to: [.init(topicFilter: "testAtLeastOnce", qos: .atLeastOnce)]).wait()
        _ = try client2.subscribe(to: [.init(topicFilter: "testExactlyOnce", qos: .exactlyOnce)]).wait()
        try client.publish(to: "testAtLeastOnce", payload: payload, qos: .atLeastOnce).wait()
        try client.publish(to: "testExactlyOnce", payload: payload, qos: .exactlyOnce).wait()
        Thread.sleep(forTimeInterval: 2)
        lock.withLock {
            XCTAssertEqual(publishReceived.count, 2)
        }
        try client.disconnect().wait()
        try client2.disconnect().wait()
        try client.syncShutdownGracefully()
        try client2.syncShutdownGracefully()
    }

    func testUnsubscribe() throws {
        let lock = Lock()
        var publishReceived: [MQTTPublishInfo] = []
        let payloadString = #"test payload"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        let client = self.createClient(identifier: "testUnsubscribe_publisher")
        _ = try client.connect().wait()
        let client2 = self.createClient(identifier: "testUnsubscribe_subscriber")
        client2.addPublishListener(named: "test") { result in
            switch result {
            case .success(let publish):
                var buffer = publish.payload
                let string = buffer.readString(length: buffer.readableBytes)
                XCTAssertEqual(string, payloadString)
                lock.withLock {
                    publishReceived.append(publish)
                }
            case .failure(let error):
                XCTFail("\(error)")
            }
        }
        _ = try client2.connect().wait()
        _ = try client2.subscribe(to: [.init(topicFilter: "testUnsubscribe", qos: .atLeastOnce)]).wait()
        try client.publish(to: "testUnsubscribe", payload: payload, qos: .atLeastOnce).wait()
        try client2.unsubscribe(from: ["testUnsubscribe"]).wait()
        try client.publish(to: "testUnsubscribe", payload: payload, qos: .atLeastOnce).wait()

        Thread.sleep(forTimeInterval: 2)
        lock.withLock {
            XCTAssertEqual(publishReceived.count, 1)
        }
        try client.disconnect().wait()
        try client2.disconnect().wait()
        try client.syncShutdownGracefully()
        try client2.syncShutdownGracefully()
    }

    func testMQTTPublishToClientLargePayload() throws {
        let lock = Lock()
        var publishReceived: [MQTTPublishInfo] = []
        let payloadSize = 65537
        let payloadData = Data(count: payloadSize)
        let payload = ByteBufferAllocator().buffer(data: payloadData)

        let client = self.createClient(identifier: "testMQTTPublishToClientLargePayload_publisher")
        _ = try client.connect().wait()
        let client2 = self.createClient(identifier: "testMQTTPublishToClientLargePayload_subscriber")
        client2.addPublishListener(named: "test") { result in
            switch result {
            case .success(let publish):
                var buffer = publish.payload
                let data = buffer.readData(length: buffer.readableBytes)
                XCTAssertEqual(data, payloadData)
                lock.withLock {
                    publishReceived.append(publish)
                }
            case .failure(let error):
                XCTFail("\(error)")
            }
        }
        _ = try client2.connect().wait()
        _ = try client2.subscribe(to: [.init(topicFilter: "testLargeAtLeastOnce", qos: .atLeastOnce)]).wait()
        try client.publish(to: "testLargeAtLeastOnce", payload: payload, qos: .atLeastOnce).wait()
        Thread.sleep(forTimeInterval: 2)
        lock.withLock {
            XCTAssertEqual(publishReceived.count, 1)
        }
        try client.disconnect().wait()
        try client2.disconnect().wait()
        try client.syncShutdownGracefully()
        try client2.syncShutdownGracefully()
    }

    func testCloseListener() throws {
        let disconnected = NIOAtomic<Bool>.makeAtomic(value: false)
        let client = self.createWebSocketClient(identifier: "testCloseListener")
        let client2 = self.createWebSocketClient(identifier: "testCloseListener")

        client.addCloseListener(named: "Reconnect") { result in
            switch result {
            case .failure(let error):
                XCTFail("\(error)")
            case .success:
                disconnected.store(true)
            }
        }

        _ = try client.connect().wait()
        // by connecting with same identifier the first client uses the first client is forced to disconnect
        _ = try client2.connect().wait()

        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(disconnected.load())

        try client2.disconnect().wait()
        try client.syncShutdownGracefully()
        try client2.syncShutdownGracefully()
    }

    func testDoubleConnect() throws {
        let client = self.createClient(identifier: "DoubleConnect")
        _ = try client.connect(cleanSession: true).wait()
        let sessionPresent = try client.connect(cleanSession: false).wait()
        let sessionPresent2 = try client.connect(cleanSession: false).wait()
        XCTAssertFalse(sessionPresent)
        XCTAssertTrue(sessionPresent2)
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testSessionPresent() throws {
        let client = self.createClient(identifier: "testSessionPresent")

        _ = try client.connect(cleanSession: true).wait()
        var connack = try client.connect(cleanSession: false).wait()
        XCTAssertEqual(connack, false)
        try client.disconnect().wait()
        connack = try client.connect(cleanSession: false).wait()
        XCTAssertEqual(connack, true)
    }
    
    func testPersistentSession() throws {
        let lock = Lock()
        var publishReceived: [MQTTPublishInfo] = []
        let payloadString = #"{"from":1000000,"to":1234567,"type":1,"content":"I am a beginner in swift and I am studying hard!!测试\n\n test, message","timestamp":1607243024,"nonce":"pAx2EsUuXrVuiIU3GGOGHNbUjzRRdT5b","sign":"ff902e31a6a5f5343d70a3a93ac9f946adf1caccab539c6f3a6"}"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        let client = self.createClient(identifier: "testPersistentSession_publisher")
        _ = try client.connect().wait()
        let client2 = self.createClient(identifier: "testPersistentSession_subscriber")
        client2.addPublishListener(named: "test") { result in
            switch result {
            case .success(let publish):
                var buffer = publish.payload
                let string = buffer.readString(length: buffer.readableBytes)
                XCTAssertEqual(string, payloadString)
                lock.withLock {
                    publishReceived.append(publish)
                }
            case .failure(let error):
                XCTFail("\(error)")
            }
        }
        _ = try client2.connect(cleanSession: true).wait()
        _ = try client2.connect(cleanSession: false).wait()
        _ = try client2.subscribe(to: [.init(topicFilter: "testPersistentAtLeastOnce", qos: .atLeastOnce)]).wait()
        try client.publish(to: "testPersistentAtLeastOnce", payload: payload, qos: .atLeastOnce).wait()
        Thread.sleep(forTimeInterval: 1)
        try client2.disconnect().wait()
        try client.publish(to: "testPersistentAtLeastOnce", payload: payload, qos: .atLeastOnce).wait()
        Thread.sleep(forTimeInterval: 1)
        // should receive previous publish on new connect as this is not a cleanSession
        _ = try client2.connect(cleanSession: false).wait()
        Thread.sleep(forTimeInterval: 1)
        try client2.disconnect().wait()
        Thread.sleep(forTimeInterval: 1)
        try client.publish(to: "testPersistentAtLeastOnce", payload: payload, qos: .atLeastOnce).wait()
        // should not receive previous publish on connect as this is a cleanSession
        _ = try client2.connect(cleanSession: true).wait()
        Thread.sleep(forTimeInterval: 1)
        lock.withLock {
            XCTAssertEqual(publishReceived.count, 2)
        }
        try client.disconnect().wait()
        try client2.disconnect().wait()
        try client.syncShutdownGracefully()
        try client2.syncShutdownGracefully()
    }

    func testSubscribeAll() throws {
        if ProcessInfo.processInfo.environment["CI"] != nil {
            return
        }
        let client = MQTTClient(
            host: "test.mosquitto.org",
            port: 1883,
            identifier: "testSubscribeAll",
            eventLoopGroupProvider: .createNew,
            logger: self.logger
        )
        _ = try client.connect().wait()
        _ = try client.subscribe(to: [.init(topicFilter: "#", qos: .exactlyOnce)]).wait()
        Thread.sleep(forTimeInterval: 5)
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    // MARK: Helper variables and functions

    func createClient(identifier: String, configuration: MQTTClient.Configuration = .init()) -> MQTTClient {
        MQTTClient(
            host: Self.hostname,
            port: 1883,
            identifier: identifier,
            eventLoopGroupProvider: .createNew,
            logger: self.logger,
            configuration: configuration
        )
    }

    func createWebSocketClient(identifier: String) -> MQTTClient {
        MQTTClient(
            host: Self.hostname,
            port: 8080,
            identifier: identifier,
            eventLoopGroupProvider: .createNew,
            logger: self.logger,
            configuration: .init(useWebSockets: true, webSocketURLPath: "/mqtt")
        )
    }

    #if canImport(NIOSSL)
    func createSSLClient(identifier: String) throws -> MQTTClient {
        return try MQTTClient(
            host: Self.hostname,
            port: 8883,
            identifier: identifier,
            eventLoopGroupProvider: .createNew,
            logger: self.logger,
            configuration: .init(useSSL: true, tlsConfiguration: Self.getTLSConfiguration(withClientKey: true), sniServerName: "soto.codes")
        )
    }

    func createWebSocketAndSSLClient(identifier: String) throws -> MQTTClient {
        return try MQTTClient(
            host: Self.hostname,
            port: 8081,
            identifier: identifier,
            eventLoopGroupProvider: .createNew,
            logger: self.logger,
            configuration: .init(timeout: .seconds(5), useSSL: true, useWebSockets: true, tlsConfiguration: Self.getTLSConfiguration(), sniServerName: "soto.codes", webSocketURLPath: "/mqtt")
        )
    }
    #endif

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

    #if canImport(NIOSSL)
    static var _tlsConfiguration: Result<MQTTClient.TLSConfigurationType, Error> = {
        do {
            #if os(Linux)

            let rootCertificate = try NIOSSLCertificate.fromPEMFile(MQTTNIOTests.rootPath + "/mosquitto/certs/ca.crt")
            let certificate = try NIOSSLCertificate.fromPEMFile(MQTTNIOTests.rootPath + "/mosquitto/certs/client.crt")
            let privateKey = try NIOSSLPrivateKey(file: MQTTNIOTests.rootPath + "/mosquitto/certs/client.key", format: .pem)
            let tlsConfiguration = TLSConfiguration.forClient(
                trustRoots: .certificates(rootCertificate),
                certificateChain: certificate.map { .certificate($0) },
                privateKey: .privateKey(privateKey)
            )
            return .success(.niossl(tlsConfiguration))

            #else

            let rootCertificate = try NIOSSLCertificate.fromPEMFile(MQTTNIOTests.rootPath + "/mosquitto/certs/ca.crt")
            let trustRootCertificates = try rootCertificate.compactMap { SecCertificateCreateWithData(nil, Data(try $0.toDERBytes()) as CFData) }
            let data = try Data(contentsOf: URL(fileURLWithPath: MQTTNIOTests.rootPath + "/mosquitto/certs/client.p12"))
            let options: [String: String] = [kSecImportExportPassphrase as String: "BoQOxr1HFWb5poBJ0Z9tY1xcB"]
            var rawItems: CFArray?
            let rt = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
            let items = rawItems! as! [[String: Any]]
            let firstItem = items[0]
            let identity = firstItem[kSecImportItemIdentity as String] as! SecIdentity?
            let tlsConfiguration = TSTLSConfiguration(
                trustRoots: trustRootCertificates,
                clientIdentity: identity
            )
            return .success(.ts(tlsConfiguration))

            #endif
        } catch {
            return .failure(error)
        }
    }()

    static func getTLSConfiguration(withTrustRoots: Bool = true, withClientKey: Bool = true) throws -> MQTTClient.TLSConfigurationType {
        switch self._tlsConfiguration {
        case .success(let config):
            switch config {
            case .niossl(let config):
                return .niossl(TLSConfiguration.forClient(
                    trustRoots: withTrustRoots == true ? (config.trustRoots ?? .default) : .default,
                    certificateChain: withClientKey ? config.certificateChain : [],
                    privateKey: withClientKey ? config.privateKey : nil
                ))
            #if !os(Linux)
            case .ts(let config):
                return .ts(TSTLSConfiguration(
                    trustRoots: withTrustRoots == true ? config.trustRoots : nil,
                    clientIdentity: withClientKey == true ? config.clientIdentity : nil
                ))
            #endif
            }
        case .failure(let error):
            throw error
        }
    }
    #endif // canImport(NIOSSL)
}
