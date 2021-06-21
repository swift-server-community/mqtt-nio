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

final class MQTTNIOv5Tests: XCTestCase {
    static let hostname = ProcessInfo.processInfo.environment["MOSQUITTO_SERVER"] ?? "localhost"
    
    func testConnect() throws {
        let client = self.createClient(identifier: "testConnectV5")
        _ = try client.connect().wait()
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testConnectWithWill() throws {
        let client = self.createClient(identifier: "testConnectWithWill")
        _ = try client.connect(
            will: (topicName: "MyWillTopic", payload: ByteBufferAllocator().buffer(string: "Test payload"), retain: false)
        ).wait()
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testConnectWithUInt8Property() throws {
        try testConnectWithProperty(.requestResponseInformation, value: .byte(1))
    }

    func testConnectWithUInt16Property() throws {
        try testConnectWithProperty(.topicAliasMaximum, value: .twoByteInteger(1024))
    }

    func testConnectWithUInt32Property() throws {
        try testConnectWithProperty(.sessionExpiryInterval, value: .fourByteInteger(15))
    }

    func testConnectWithStringPairProperty() throws {
        try testConnectWithProperty(.userProperty, value: .stringPair("test", "value"))
    }

    func testConnectWithBinaryDataProperty() throws {
        try testConnectWithProperty(.authenticationData, value: .binaryData(ByteBufferAllocator().buffer(string: "TestBuffer")))
    }

    func testPublishQoS1() throws {
        let client = self.createClient(identifier: "testPublishQoS1V5")
        _ = try client.connect().wait()
        try client.publish(to: "testMQTTPublishQoS", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .atLeastOnce).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testPublishQoS1WithProperty() throws {
        let client = self.createClient(identifier: "testPublishQoS1V5")
        _ = try client.connect().wait()
        var publishProperties = MQTTProperties()
        try publishProperties.addProperty(id: .contentType, value: "text/plain")
        try client.publish(
            to: "testMQTTPublishQoS",
            payload: ByteBufferAllocator().buffer(string: "Test payload"),
            qos: .atLeastOnce,
            properties: publishProperties
        ).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testPublishQoS2() throws {
        let client = self.createClient(identifier: "testPublishQoS1V5")
        _ = try client.connect().wait()
        try client.publish(to: "testMQTTPublishQoS", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .exactlyOnce).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTSubscribe() throws {
        let client = self.createClient(identifier: "testMQTTSubscribeV5")
        _ = try client.connect().wait()
        try client.subscribe(to: [.init(topicFilter: "iphone", qos: .atLeastOnce)]).wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testUnsubscribe() throws {
        let lock = Lock()
        var publishReceived: [MQTTPublishInfo] = []
        let payloadString = #"test payload"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        let client = self.createClient(identifier: "testUnsubscribe_publisherV5")
        _ = try client.connect().wait()
        let client2 = self.createClient(identifier: "testUnsubscribe_subscriberV5")
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
        try client2.subscribe(to: [.init(topicFilter: "testUnsubscribe", qos: .atLeastOnce)]).wait()
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


    // MARK: Helper variables and functions

    func createClient(identifier: String) -> MQTTClient {
        MQTTClient(
            host: Self.hostname,
            port: 1883,
            identifier: identifier,
            eventLoopGroupProvider: .createNew,
            logger: self.logger,
            configuration: .init(version: .v5_0)
        )
    }

    func testConnectWithProperty(_ id: MQTTProperties.PropertyId, value: MQTTProperties.PropertyValue) throws {
        let client = self.createClient(identifier: "testConnectV5")
        _ = try client.connect(properties: .init([id: value])).wait()
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    let logger: Logger = {
        var logger = Logger(label: "MQTTTests")
        logger.logLevel = .trace
        return logger
    }()
}
