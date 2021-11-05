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
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect(
            will: (topicName: "MyWillTopic", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .atLeastOnce, retain: false)
        ).wait()
        try client.ping().wait()
        try client.disconnect().wait()
    }

    func testConnectWithUsernameAndPassword() throws {
        let client = MQTTClient(
            host: Self.hostname,
            port: 1884,
            identifier: "testConnectWithUsernameAndPassword",
            eventLoopGroupProvider: .createNew,
            logger: self.logger,
            configuration: .init(userName: "mqttnio", password: "mqttnio-password")
        )
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        try client.ping().wait()
        try client.disconnect().wait()
    }

    func testConnectWithWrongUsernameAndPassword() throws {
        let client = MQTTClient(
            host: Self.hostname,
            port: 1884,
            identifier: "testConnectWithWrongUsernameAndPassword",
            eventLoopGroupProvider: .createNew,
            logger: self.logger,
            configuration: .init(userName: "mqttnio", password: "wrong-password")
        )
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        XCTAssertThrowsError(try client.connect().wait()) { error in
            switch error {
            case MQTTError.connectionError(let reason):
                XCTAssertEqual(reason, .notAuthorized)
            default:
                XCTFail("\(error)")
            }
        }
        try client.connection?.closeFuture.wait()
    }

    func testWebsocketConnect() throws {
        let client = self.createWebSocketClient(identifier: "testWebsocketConnect")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        try client.ping().wait()
        try client.disconnect().wait()
    }

    func testSSLConnect() throws {
        let client = try createSSLClient(identifier: "testSSLConnect")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        try client.ping().wait()
        try client.disconnect().wait()
    }

    func testWebsocketAndSSLConnect() throws {
        let client = try createWebSocketAndSSLClient(identifier: "testWebsocketAndSSLConnect")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        try client.ping().wait()
        try client.disconnect().wait()
    }

    #if canImport(Network)
    func testSSLConnectFromP12() throws {
        let client = try MQTTClient(
            host: Self.hostname,
            port: 8883,
            identifier: "testSSLConnectFromP12",
            eventLoopGroupProvider: .createNew,
            logger: self.logger,
            configuration: .init(
                useSSL: true,
                tlsConfiguration: .ts(.init(
                    trustRoots: .der(MQTTNIOTests.rootPath + "/mosquitto/certs/ca.der"),
                    clientIdentity: .p12(filename: MQTTNIOTests.rootPath + "/mosquitto/certs/client.p12", password: "MQTTNIOClientCertPassword")
                )),
                sniServerName: "soto.codes"
            )
        )
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        try client.ping().wait()
        try client.disconnect().wait()
    }
    #endif

    func testMQTTPublishQoS0() throws {
        let client = self.createClient(identifier: "testMQTTPublishQoS0")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        try client.publish(to: "testMQTTPublishQoS", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .atMostOnce).wait()
        try client.disconnect().wait()
    }

    func testMQTTPublishQoS1() throws {
        let client = self.createClient(identifier: "testMQTTPublishQoS1")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        try client.publish(to: "testMQTTPublishQoS", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .atLeastOnce).wait()
        try client.disconnect().wait()
    }

    func testMQTTPublishQoS2() throws {
        let client = self.createWebSocketClient(identifier: "testMQTTPublishQoS2")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        try client.publish(to: "testMQTTPublishQoS", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .exactlyOnce).wait()
        try client.disconnect().wait()
    }

    func testMQTTPingreq() throws {
        let client = self.createClient(identifier: "testMQTTPingreq")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        try client.ping().wait()
        try client.disconnect().wait()
    }

    func testMultipleTasks() throws {
        let client = self.createClient(identifier: "testMultipleTasks")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        let publishFutures = (0..<16).map { client.publish(to: "test/multiple", payload: ByteBuffer(integer: $0), qos: .exactlyOnce) }
        _ = client.ping()
        try EventLoopFuture.andAllComplete(publishFutures, on: client.eventLoopGroup.next()).wait()
        XCTAssertEqual(client.connection?.taskHandler.tasks.count, 0)
        try client.disconnect().wait()
    }

    func testMQTTSubscribe() throws {
        let client = self.createClient(identifier: "testMQTTSubscribe")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        let sub = try client.subscribe(
            to: [
                .init(topicFilter: "iphone", qos: .atLeastOnce),
                .init(topicFilter: "iphone2", qos: .exactlyOnce),
            ]
        ).wait()
        XCTAssertEqual(sub.returnCodes[0], .grantedQoS1)
        XCTAssertEqual(sub.returnCodes[1], .grantedQoS2)
        try client.disconnect().wait()
    }

    func testMQTTServerDisconnect() throws {
        let expectation = XCTestExpectation(description: "testMQTTServerDisconnect")
        expectation.expectedFulfillmentCount = 1

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
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        try client.connection?.sendMessageNoWait(MQTTForceDisconnectMessage()).wait()
        client.addCloseListener(named: "Test") { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)

        XCTAssertFalse(client.isActive())
    }

    func testMQTTPublishRetain() throws {
        let expectation = XCTestExpectation(description: "testMQTTPublishRetain")
        expectation.expectedFulfillmentCount = 1

        let payloadString = #"{"from":1000000,"to":1234567,"type":1,"content":"I am a beginner in swift and I am studying hard!!测试\n\n test, message","timestamp":1607243024,"nonce":"pAx2EsUuXrVuiIU3GGOGHNbUjzRRdT5b","sign":"ff902e31a6a5f5343d70a3a93ac9f946adf1caccab539c6f3a6"}"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        let client = self.createWebSocketClient(identifier: "testMQTTPublishToClient_publisher")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        client.addPublishListener(named: "test") { result in
            switch result {
            case .success(let publish):
                var buffer = publish.payload
                let string = buffer.readString(length: buffer.readableBytes)
                XCTAssertEqual(string, payloadString)
                expectation.fulfill()
            case .failure(let error):
                XCTFail("\(error)")
            }
        }
        try client.publish(to: "testMQTTPublishRetain", payload: payload, qos: .atLeastOnce, retain: true).wait()
        _ = try client.subscribe(to: [.init(topicFilter: "testMQTTPublishRetain", qos: .atLeastOnce)]).wait()

        wait(for: [expectation], timeout: 5.0)

        try client.disconnect().wait()
    }

    func testMQTTPublishToClient() throws {
        let expectation = XCTestExpectation(description: "testMQTTPublishToClient")
        expectation.expectedFulfillmentCount = 2

        let payloadString = #"{"from":1000000,"to":1234567,"type":1,"content":"I am a beginner in swift and I am studying hard!!测试\n\n test, message","timestamp":1607243024,"nonce":"pAx2EsUuXrVuiIU3GGOGHNbUjzRRdT5b","sign":"ff902e31a6a5f5343d70a3a93ac9f946adf1caccab539c6f3a6"}"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        let client = self.createWebSocketClient(identifier: "testMQTTPublishToClient_publisher")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        let client2 = self.createWebSocketClient(identifier: "testMQTTPublishToClient_subscriber")
        defer { XCTAssertNoThrow(try client2.syncShutdownGracefully()) }

        client2.addPublishListener(named: "test") { result in
            switch result {
            case .success(let publish):
                var buffer = publish.payload
                let string = buffer.readString(length: buffer.readableBytes)
                XCTAssertEqual(string, payloadString)
                expectation.fulfill()

            case .failure(let error):
                XCTFail("\(error)")
            }
        }
        _ = try client2.connect().wait()
        _ = try client2.subscribe(to: [.init(topicFilter: "testAtLeastOnce", qos: .atLeastOnce)]).wait()
        _ = try client2.subscribe(to: [.init(topicFilter: "testExactlyOnce", qos: .exactlyOnce)]).wait()
        try client.publish(to: "testAtLeastOnce", payload: payload, qos: .atLeastOnce).wait()
        try client.publish(to: "testExactlyOnce", payload: payload, qos: .exactlyOnce).wait()

        wait(for: [expectation], timeout: 5.0)

        try client.disconnect().wait()
        try client2.disconnect().wait()
    }

    func testUnsubscribe() throws {
        let expectation = XCTestExpectation(description: "testMQTTPublishToClient")
        expectation.expectedFulfillmentCount = 1
        expectation.assertForOverFulfill = true

        let payloadString = #"test payload"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        let client = self.createClient(identifier: "testUnsubscribe_publisher")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        let client2 = self.createClient(identifier: "testUnsubscribe_subscriber")
        defer { XCTAssertNoThrow(try client2.syncShutdownGracefully()) }

        client2.addPublishListener(named: "test") { result in
            switch result {
            case .success(let publish):
                var buffer = publish.payload
                let string = buffer.readString(length: buffer.readableBytes)
                XCTAssertEqual(string, payloadString)
                expectation.fulfill()

            case .failure(let error):
                XCTFail("\(error)")
            }
        }
        _ = try client2.connect().wait()
        _ = try client2.subscribe(to: [.init(topicFilter: "testUnsubscribe", qos: .atLeastOnce)]).wait()
        try client.publish(to: "testUnsubscribe", payload: payload, qos: .atLeastOnce).wait()
        try client2.unsubscribe(from: ["testUnsubscribe"]).wait()
        try client.publish(to: "testUnsubscribe", payload: payload, qos: .atLeastOnce).wait()

        wait(for: [expectation], timeout: 5.0)

        try client.disconnect().wait()
        try client2.disconnect().wait()
    }

    func testMQTTPublishToClientLargePayload() throws {
        let expectation = XCTestExpectation(description: "testMQTTPublishToClientLargePayload")
        expectation.expectedFulfillmentCount = 1

        let payloadSize = 65537
        let payloadData = Data(count: payloadSize)
        let payload = ByteBufferAllocator().buffer(data: payloadData)

        let client = self.createClient(identifier: "testMQTTPublishToClientLargePayload_publisher")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        let client2 = self.createClient(identifier: "testMQTTPublishToClientLargePayload_subscriber")
        defer { XCTAssertNoThrow(try client2.syncShutdownGracefully()) }

        client2.addPublishListener(named: "test") { result in
            switch result {
            case .success(let publish):
                var buffer = publish.payload
                let data = buffer.readData(length: buffer.readableBytes)
                XCTAssertEqual(data, payloadData)
                expectation.fulfill()

            case .failure(let error):
                XCTFail("\(error)")
            }
        }
        _ = try client2.connect().wait()
        _ = try client2.subscribe(to: [.init(topicFilter: "testLargeAtLeastOnce", qos: .atLeastOnce)]).wait()
        try client.publish(to: "testLargeAtLeastOnce", payload: payload, qos: .atLeastOnce).wait()

        wait(for: [expectation], timeout: 5.0)

        try client.disconnect().wait()
        try client2.disconnect().wait()
    }

    func testCloseListener() throws {
        let expectation = XCTestExpectation(description: "testCloseListener")
        expectation.expectedFulfillmentCount = 1

        let client = self.createWebSocketClient(identifier: "testCloseListener")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        let client2 = self.createWebSocketClient(identifier: "testCloseListener")
        defer { XCTAssertNoThrow(try client2.syncShutdownGracefully()) }

        client.addCloseListener(named: "Reconnect") { result in
            switch result {
            case .failure(let error):
                XCTFail("\(error)")
            case .success:
                expectation.fulfill()
            }
        }

        _ = try client.connect().wait()
        // by connecting with same identifier the first client uses the first client is forced to disconnect
        _ = try client2.connect().wait()

        wait(for: [expectation], timeout: 5.0)

        try client2.disconnect().wait()
    }

    func testDoubleConnect() throws {
        let client = self.createClient(identifier: "DoubleConnect")
        _ = try client.connect(cleanSession: true).wait()
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        let sessionPresent = try client.connect(cleanSession: false).wait()
        let sessionPresent2 = try client.connect(cleanSession: false).wait()
        XCTAssertFalse(sessionPresent)
        XCTAssertTrue(sessionPresent2)
        try client.disconnect().wait()
    }

    func testSessionPresent() throws {
        let client = self.createClient(identifier: "testSessionPresent")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }

        _ = try client.connect(cleanSession: true).wait()
        var connack = try client.connect(cleanSession: false).wait()
        XCTAssertEqual(connack, false)
        try client.disconnect().wait()
        connack = try client.connect(cleanSession: false).wait()
        XCTAssertEqual(connack, true)
    }

    func testPersistentSession() throws {
        let expectation = XCTestExpectation(description: "testPersistentSession")
        expectation.expectedFulfillmentCount = 2
        expectation.assertForOverFulfill = true

        let payloadString = #"{"from":1000000,"to":1234567,"type":1,"content":"I am a beginner in swift and I am studying hard!!测试\n\n test, message","timestamp":1607243024,"nonce":"pAx2EsUuXrVuiIU3GGOGHNbUjzRRdT5b","sign":"ff902e31a6a5f5343d70a3a93ac9f946adf1caccab539c6f3a6"}"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        let client = self.createClient(identifier: "testPersistentSession_publisher")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        let client2 = self.createClient(identifier: "testPersistentSession_subscriber")
        defer { XCTAssertNoThrow(try client2.syncShutdownGracefully()) }

        client2.addPublishListener(named: "test") { result in
            switch result {
            case .success(let publish):
                var buffer = publish.payload
                let string = buffer.readString(length: buffer.readableBytes)
                XCTAssertEqual(string, payloadString)
                expectation.fulfill()

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
        try client.publish(to: "testPersistentAtLeastOnce", payload: payload, qos: .atLeastOnce).wait()
        // should not receive previous publish on connect as this is a cleanSession
        _ = try client2.connect(cleanSession: true).wait()

        wait(for: [expectation], timeout: 5.0)

        try client.disconnect().wait()
        try client2.disconnect().wait()
    }

    func testInflight() throws {
        let expectation = XCTestExpectation(description: "testPersistentSession")
        expectation.expectedFulfillmentCount = 1

        let client = self.createClient(identifier: "testInflight")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        let client2 = self.createClient(identifier: "testPersistentSession_subscriber")
        defer { XCTAssertNoThrow(try client2.syncShutdownGracefully()) }
        _ = try client2.connect(cleanSession: true).wait()
        client2.addPublishListener(named: "test") { result in
            switch result {
            case .success:
                expectation.fulfill()

            case .failure(let error):
                XCTFail("\(error)")
            }
        }

        _ = try client.connect(cleanSession: true).wait()
        _ = try client.connect(cleanSession: false).wait()
        _ = client.publish(to: "test/Inflight", payload: ByteBuffer(string: "Flying"), qos: .exactlyOnce)
        try client.disconnect().wait()

        _ = try client2.subscribe(to: [.init(topicFilter: "test/Inflight", qos: .atLeastOnce)]).wait()
        _ = try client.connect(cleanSession: false).wait()

        wait(for: [expectation], timeout: 5.0)

        try client.disconnect().wait()
        try client2.disconnect().wait()
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
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }

        _ = try client.connect().wait()
        _ = try client.subscribe(to: [.init(topicFilter: "#", qos: .exactlyOnce)]).wait()
        Thread.sleep(forTimeInterval: 5)
        try client.disconnect().wait()
    }

    func testRawIPConnect() throws {
        #if os(macOS)
        if ProcessInfo.processInfo.environment["CI"] != nil {
            return
        }
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }
        let client = MQTTClient(
            host: "127.0.0.1",
            identifier: "test/raw-ip",
            eventLoopGroupProvider: .shared(elg),
            logger: self.logger
        )
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        _ = try client.ping().wait()
        try client.disconnect().wait()
        #endif
    }

    // MARK: Helper variables and functions

    func createClient(identifier: String, configuration: MQTTClient.Configuration = .init()) -> MQTTClient {
        MQTTClient(
            host: Self.hostname,
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

    func createSSLClient(identifier: String) throws -> MQTTClient {
        return try MQTTClient(
            host: Self.hostname,
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

    static var _tlsConfiguration: Result<MQTTClient.TLSConfigurationType, Error> = {
        do {
            #if os(Linux)

            let rootCertificate = try NIOSSLCertificate.fromPEMFile(MQTTNIOTests.rootPath + "/mosquitto/certs/ca.pem")
            let certificate = try NIOSSLCertificate.fromPEMFile(MQTTNIOTests.rootPath + "/mosquitto/certs/client.pem")
            let privateKey = try NIOSSLPrivateKey(file: MQTTNIOTests.rootPath + "/mosquitto/certs/client.key", format: .pem)
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.trustRoots = .certificates(rootCertificate)
            tlsConfiguration.certificateChain = certificate.map { .certificate($0) }
            tlsConfiguration.privateKey = .privateKey(privateKey)

            return .success(.niossl(tlsConfiguration))

            #else

            let caData = try Data(contentsOf: URL(fileURLWithPath: MQTTNIOTests.rootPath + "/mosquitto/certs/ca.der"))
            let trustRootCertificates = SecCertificateCreateWithData(nil, caData as CFData).map { [$0] }
            let p12Data = try Data(contentsOf: URL(fileURLWithPath: MQTTNIOTests.rootPath + "/mosquitto/certs/client.p12"))
            let options: [String: String] = [kSecImportExportPassphrase as String: "MQTTNIOClientCertPassword"]
            var rawItems: CFArray?
            let rt = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &rawItems)
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
            #if canImport(NIOSSL)
            case .niossl(let config):
                var tlsConfig = TLSConfiguration.makeClientConfiguration()
                tlsConfig.trustRoots = withTrustRoots == true ? (config.trustRoots ?? .default) : .default
                tlsConfig.certificateChain = withClientKey ? config.certificateChain : []
                tlsConfig.privateKey = withClientKey ? config.privateKey : nil
                return .niossl(tlsConfig)
            #endif
            #if canImport(Network)
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
}
