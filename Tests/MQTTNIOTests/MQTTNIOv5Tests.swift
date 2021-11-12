//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2021 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

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
        try self.testConnectWithProperty(.requestResponseInformation(1))
    }

    func testConnectWithUInt16Property() throws {
        try self.testConnectWithProperty(.topicAliasMaximum(1024))
    }

    func testConnectWithUInt32Property() throws {
        try self.testConnectWithProperty(.sessionExpiryInterval(15))
    }

    func testConnectWithStringPairProperty() throws {
        try self.testConnectWithProperty(.userProperty("test", "value"))
    }

    func testConnectWithBinaryDataProperty() throws {
        try self.testConnectWithProperty(.authenticationData(ByteBufferAllocator().buffer(string: "TestBuffer")))
    }

    func testConnectWithNoIdentifier() throws {
        let client = self.createClient(identifier: "")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.v5.connect().wait()
        XCTAssertTrue(client.identifier.count > 0)
        try client.disconnect().wait()
    }

    func testPublishQoS1() throws {
        let client = self.createClient(identifier: "testPublishQoS1V5")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        try client.publish(to: "testMQTTPublishQoS", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .atLeastOnce).wait()
        try client.disconnect().wait()
    }

    func testPublishQoS1WithProperty() throws {
        let client = self.createClient(identifier: "testPublishQoS1V5")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        _ = try client.v5.publish(
            to: "testMQTTPublishQoS",
            payload: ByteBufferAllocator().buffer(string: "Test payload"),
            qos: .atLeastOnce,
            properties: [.contentType("text/plain")]
        ).wait()
        try client.disconnect().wait()
    }

    func testPublishQoS2() throws {
        let client = self.createClient(identifier: "testPublishQoS1V5")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        try client.publish(to: "testMQTTPublishQoS", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .exactlyOnce).wait()
        try client.disconnect().wait()
    }

    func testMQTTSubscribe() throws {
        let client = self.createClient(identifier: "testMQTTSubscribeV5")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        let sub = try client.v5.subscribe(
            to: [
                .init(topicFilter: "iphone", qos: .atLeastOnce),
                .init(topicFilter: "iphone2", qos: .exactlyOnce),
            ]
        ).wait()
        XCTAssertEqual(sub.reasons[0], .grantedQoS1)
        XCTAssertEqual(sub.reasons[1], .grantedQoS2)
        try client.disconnect().wait()
    }

    func testMQTTSubscribeFlags() throws {
        let expectation = XCTestExpectation(description: "testMQTTSubscribeFlags")
        expectation.expectedFulfillmentCount = 1

        let payloadString = #"{"test":1000000}"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        let client = self.createClient(identifier: "testMQTTPublishToClient_publisher")
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

        wait(for: [expectation], timeout: 5)

        try client.disconnect().wait()
    }

    func testMQTTContentType() throws {
        let expectation = XCTestExpectation(description: "testMQTTContentType")
        expectation.expectedFulfillmentCount = 1

        let payloadString = #"{"test":1000000}"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        let client = self.createClient(identifier: "testMQTTContentType")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        client.addPublishListener(named: "test") { result in
            switch result {
            case .success(let publish):
                var buffer = publish.payload
                let string = buffer.readString(length: buffer.readableBytes)
                XCTAssertEqual(string, payloadString)
                XCTAssertNotNil(publish.properties.first { $0 == .contentType("application/json") })
                expectation.fulfill()

            case .failure(let error):
                XCTFail("\(error)")
            }
        }
        let sub = try client.v5.subscribe(
            to: [.init(topicFilter: "testMQTTContentType", qos: .atLeastOnce)]
        ).wait()
        XCTAssert(sub.reasons.count == 1)

        _ = try client.v5.publish(
            to: "testMQTTContentType",
            payload: payload,
            qos: .atLeastOnce,
            retain: false,
            properties: [.contentType("application/json")]
        ).wait()

        wait(for: [expectation], timeout: 5.0)

        try client.disconnect().wait()
    }

    func testUserProperty() throws {
        let expectation = XCTestExpectation(description: "testUserProperty")
        expectation.expectedFulfillmentCount = 1

        let client = self.createClient(identifier: "testUserProperty")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        client.addPublishListener(named: "test") { result in
            switch result {
            case .success(let publish):
                XCTAssertNotNil(publish.properties.first { $0 == .userProperty("key", "value") })
                expectation.fulfill()

            case .failure(let error):
                XCTFail("\(error)")
            }
        }
        let sub = try client.v5.subscribe(
            to: [.init(topicFilter: "testMQTTContentType", qos: .atLeastOnce)]
        ).wait()
        XCTAssert(sub.reasons.count == 1)

        _ = try client.v5.publish(
            to: "testMQTTContentType",
            payload: ByteBuffer(string: "test"),
            qos: .atLeastOnce,
            properties: [.userProperty("key", "value")]
        ).wait()

        wait(for: [expectation], timeout: 5.0)

        try client.disconnect().wait()
    }

    func testUnsubscribe() throws {
        let expectation = XCTestExpectation(description: "testMQTTContentType")
        expectation.expectedFulfillmentCount = 1
        expectation.assertForOverFulfill = true

        let payloadString = #"test payload"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        let client = self.createClient(identifier: "testUnsubscribe_publisherV5")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        let client2 = self.createClient(identifier: "testUnsubscribe_subscriberV5")
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
        let unsub = try client2.v5.unsubscribe(from: ["testUnsubscribe", "notsubscribed"]).wait()
        XCTAssertEqual(unsub.reasons[0], .success)
        XCTAssertEqual(unsub.reasons[1], .noSubscriptionExisted)
        try client.publish(to: "testUnsubscribe", payload: payload, qos: .atLeastOnce).wait()

        wait(for: [expectation], timeout: 5.0)

        try client.disconnect().wait()
        try client2.disconnect().wait()
    }

    func testSessionPresent() throws {
        let client = self.createClient(identifier: "testSessionPresent")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        var connack = try client.v5.connect(cleanStart: true, properties: [.sessionExpiryInterval(3600)]).wait()
        XCTAssertEqual(connack.sessionPresent, false)
        try client.v5.disconnect(properties: [.sessionExpiryInterval(3600)]).wait()
        connack = try client.v5.connect(cleanStart: false).wait()
        XCTAssertEqual(connack.sessionPresent, true)
        try client.disconnect().wait()
    }

    func testPersistentSession() throws {
        let expectation = XCTestExpectation(description: "testPersistentSession")
        expectation.expectedFulfillmentCount = 2
        expectation.assertForOverFulfill = true

        let payloadString = #"{"from":1000000,"to":1234567,"type":1,"content":"I am a beginner in swift and I am studying hard!!测试\n\n test, message","timestamp":1607243024,"nonce":"pAx2EsUuXrVuiIU3GGOGHNbUjzRRdT5b","sign":"ff902e31a6a5f5343d70a3a93ac9f946adf1caccab539c6f3a6"}"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        let client = self.createClient(identifier: "testPersistentSession_publisherV5")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.v5.connect().wait()
        let client2 = self.createClient(identifier: "testPersistentSession_subscriberV5")
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
        _ = try client2.v5.connect(cleanStart: true).wait()
        _ = try client2.v5.connect(cleanStart: false, properties: [.sessionExpiryInterval(3600)]).wait()
        _ = try client2.subscribe(to: [.init(topicFilter: "testPersistentAtLeastOnceV5", qos: .atLeastOnce)]).wait()
        try client.publish(to: "testPersistentAtLeastOnceV5", payload: payload, qos: .atLeastOnce).wait()
        Thread.sleep(forTimeInterval: 1)
        try client2.disconnect().wait()
        _ = try client2.connect(cleanSession: false).wait()
        // client2 should receive this publish as we have reconnected with clean session set to false
        try client.publish(to: "testPersistentAtLeastOnceV5", payload: payload, qos: .atLeastOnce).wait()
        Thread.sleep(forTimeInterval: 1)
        try client2.disconnect().wait()
        // should not receive previous publish on connect as this is a cleanSession
        _ = try client2.connect(cleanSession: true).wait()
        // client2 should not receive this publish as we have reconnected with clean session set to true
        try client.publish(to: "testPersistentAtLeastOnceV5", payload: payload, qos: .atLeastOnce).wait()

        wait(for: [expectation], timeout: 5.0)

        try client.disconnect().wait()
        try client2.disconnect().wait()
    }

    func testBadAuthenticationMethod() throws {
        let client = self.createClient(identifier: "testSessionExpiryInterval")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        XCTAssertThrowsError(_ = try client.v5.connect(properties: [.authenticationMethod("test")]).wait()) { error in
            switch error {
            case MQTTError.reasonError(let reason):
                XCTAssertEqual(reason, .badAuthenticationMethod)
            default:
                XCTFail("\(error)")
            }
        }
    }

    func testInvalidTopicName() throws {
        let client = self.createClient(identifier: "testInvalidTopicName")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        do {
            try client.publish(to: "testInvalidTopicName#", payload: ByteBufferAllocator().buffer(string: "Test payload"), qos: .atLeastOnce).wait()
            XCTFail("Should have errored")
        } catch let error as MQTTPacketError where error == .invalidTopicName {}
        try client.disconnect().wait()
    }

    /// Test Publish that will cause a server disconnection message
    func testBadPublish() throws {
        let client = self.createClient(identifier: "testBadPublish")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        do {
            _ = try client.v5.publish(
                to: "testBadPublish",
                payload: ByteBufferAllocator().buffer(string: "Test payload"),
                qos: .atLeastOnce,
                properties: [.requestResponseInformation(1)]
            ).wait()
            XCTFail("Should have errored")
        } catch MQTTError.serverDisconnection(let ack) {
            // some versions of mosquitto return protocol error and others malformed packet
            XCTAssert(ack.reason == .protocolError || ack.reason == .malformedPacket)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testOutOfRangeTopicAlias() throws {
        let client = self.createClient(identifier: "testOutOfRangeTopicAlias")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        do {
            _ = try client.v5.publish(
                to: "testOutOfRangeTopicAlias",
                payload: ByteBufferAllocator().buffer(string: "Test payload"),
                qos: .atLeastOnce,
                properties: [.topicAlias(client.connectionParameters.maxTopicAlias + 1)]
            ).wait()
            XCTFail("Should have errored")
        } catch let error as MQTTPacketError where error == .topicAliasOutOfRange {}
        try client.disconnect().wait()
    }

    func testPublishWithSubscription() throws {
        let client = self.createClient(identifier: "testOutOfRangeTopicAlias")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        do {
            _ = try client.v5.publish(
                to: "testOutOfRangeTopicAlias",
                payload: ByteBufferAllocator().buffer(string: "Test payload"),
                qos: .atLeastOnce,
                properties: [.subscriptionIdentifier(0)]
            ).wait()
            XCTFail("Should have errored")
        } catch let error as MQTTPacketError where error == .publishIncludesSubscription {}
        try client.disconnect().wait()
    }

    func testAuth() throws {
        let client = self.createClient(identifier: "testReauth")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }

        _ = try client.v5.connect().wait()
        let authFuture = client.v5.auth(properties: []) { _, eventLoop in
            return eventLoop.makeSucceededFuture(.init(reason: .continueAuthentication, properties: []))
        }
        XCTAssertThrowsError(try authFuture.wait()) { error in
            switch error {
            // different version of mosquitto error in different ways
            case MQTTError.serverClosedConnection:
                break
            case MQTTError.serverDisconnection(let ack):
                XCTAssertEqual(ack.reason, .protocolError)
            default:
                XCTFail("\(error)")
            }
        }
    }

    func testSubscribeAll() throws {
        if ProcessInfo.processInfo.environment["CI"] != nil {
            return
        }
        let client = MQTTClient(
            host: "test.mosquitto.org",
            port: 1883,
            identifier: "testSubscribeAllV5",
            eventLoopGroupProvider: .createNew,
            logger: self.logger,
            configuration: .init(version: .v5_0)
        )
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.v5.connect().wait()
        _ = try client.v5.subscribe(to: [.init(topicFilter: "#", qos: .exactlyOnce)]).wait()
        Thread.sleep(forTimeInterval: 5)
        try client.v5.disconnect().wait()
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

    func testConnectWithProperty(_ property: MQTTProperties.Property) throws {
        let client = self.createClient(identifier: "testConnectV5")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.v5.connect(properties: .init([property])).wait()
        try client.ping().wait()
        try client.disconnect().wait()
    }

    let logger: Logger = {
        var logger = Logger(label: "MQTTTests")
        logger.logLevel = .trace
        return logger
    }()
}
