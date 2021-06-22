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
        _ = try client.v5.connect().wait()
        try client.ping().wait()
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testConnectWithWill() throws {
        let client = self.createClient(identifier: "testConnectWithWill")
        _ = try client.connect(
            will: (topicName: "MyWillTopic", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .atLeastOnce, retain: false)
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
        try publishProperties.add(.contentType, "text/plain")
        _ = try client.v5.publish(
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
        let sub = try client.v5.subscribe(
            to: [
                .init(topicFilter: "iphone", qos: .atLeastOnce),
                .init(topicFilter: "iphone2", qos: .exactlyOnce)
            ]
        ).wait()
        XCTAssertEqual(sub.reasons[0], .grantedQoS1)
        XCTAssertEqual(sub.reasons[1], .grantedQoS2)
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTSubscribeFlags() throws {
        let lock = Lock()
        var publishReceived: [MQTTPublishInfo] = []
        let payloadString = #"{"test":1000000}"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        let client = self.createClient(identifier: "testMQTTPublishToClient_publisher")
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
        // only one of these publish messages should make it through as the subscription for "testMQTTSubscribeFlags1"
        // does not allow locally published messages and the subscription for "testMQTTSubscribeFlags3" does not
        // allow for retain messages to be sent
        try client.publish(to: "testMQTTSubscribeFlags3", payload: payload, qos: .atLeastOnce, retain: true).wait()
        try client.publish(to: "testMQTTSubscribeFlags2", payload: payload, qos: .atLeastOnce, retain: true).wait()
        let sub = try client.v5.subscribe(
            to: [
                .init(topicFilter: "testMQTTSubscribeFlags1", qos: .atLeastOnce, noLocal: true),
                .init(topicFilter: "testMQTTSubscribeFlags2", qos: .atLeastOnce, retainAsPublished: false, retainHandling: .sendAlways),
                .init(topicFilter: "testMQTTSubscribeFlags3", qos: .atLeastOnce, retainHandling: .doNotSend),
            ]
        ).wait()
        XCTAssert(sub.reasons.count == 3)
        
        try client.publish(to: "testMQTTSubscribeFlags1", payload: payload, qos: .atLeastOnce, retain: false).wait()
        
        Thread.sleep(forTimeInterval: 2)
        lock.withLock {
            XCTAssertEqual(publishReceived.count, 1)
        }
        try client.disconnect().wait()
        try client.syncShutdownGracefully()
    }

    func testMQTTContentType() throws {
        let lock = Lock()
        var publishReceived: [MQTTPublishInfo] = []
        let payloadString = #"{"test":1000000}"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        let client = self.createClient(identifier: "testMQTTContentType")
        _ = try client.connect().wait()
        client.addPublishListener(named: "test") { result in
            switch result {
            case .success(let publish):
                var buffer = publish.payload
                let string = buffer.readString(length: buffer.readableBytes)
                XCTAssertEqual(string, payloadString)
                let contentType = publish.properties[.contentType]
                XCTAssertEqual(contentType, .string("application/json"))
                lock.withLock {
                    publishReceived.append(publish)
                }
            case .failure(let error):
                XCTFail("\(error)")
            }
        }
        let sub = try client.v5.subscribe(
            to: [.init(topicFilter: "testMQTTContentType", qos: .atLeastOnce),]
        ).wait()
        XCTAssert(sub.reasons.count == 1)
        
        var properties = MQTTProperties()
        try properties.add(.contentType, "application/json")
        _ = try client.v5.publish(to: "testMQTTContentType", payload: payload, qos: .atLeastOnce, retain: false, properties: properties).wait()
        
        Thread.sleep(forTimeInterval: 2)
        lock.withLock {
            XCTAssertEqual(publishReceived.count, 1)
        }
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
        _ = try client2.subscribe(to: [.init(topicFilter: "testUnsubscribe", qos: .atLeastOnce)]).wait()
        try client.publish(to: "testUnsubscribe", payload: payload, qos: .atLeastOnce).wait()
        let unsub = try client2.v5.unsubscribe(from: ["testUnsubscribe", "notsubscribed"]).wait()
        XCTAssertEqual(unsub.reasons[0], .success)
        XCTAssertEqual(unsub.reasons[1], .noSubscriptionExisted)
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
        _ = try client.v5.connect(properties: .init([id: value])).wait()
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
