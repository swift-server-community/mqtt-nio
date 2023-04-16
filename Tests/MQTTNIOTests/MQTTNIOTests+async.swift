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

#if compiler(>=5.5) && canImport(_Concurrency)

import Atomics
import Logging
import NIO
import NIOFoundationCompat
import NIOHTTP1
import XCTest
#if canImport(NIOSSL)
import NIOSSL
#endif
@testable import MQTTNIO

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
final class AsyncMQTTNIOTests: XCTestCase {
    static let hostname = ProcessInfo.processInfo.environment["MOSQUITTO_SERVER"] ?? "localhost"
    static let logger: Logger = {
        var logger = Logger(label: "MQTTTests")
        logger.logLevel = .trace
        return logger
    }()

    func createClient(identifier: String, version: MQTTClient.Version = .v3_1_1, timeout: TimeAmount? = .seconds(10)) -> MQTTClient {
        MQTTClient(
            host: Self.hostname,
            port: 1883,
            identifier: identifier,
            eventLoopGroupProvider: .createNew,
            logger: Self.logger,
            configuration: .init(version: version, timeout: timeout)
        )
    }

    func testConnect() async throws {
        let client = self.createClient(identifier: "testConnect+async")
        try await client.connect()
        try await client.disconnect()
        try await client.shutdown()
    }

    func testPublishSubscribe() async throws {
        let client = self.createClient(identifier: "testPublish+async")
        let client2 = self.createClient(identifier: "testPublish+async2")
        let payloadString = "Hello"
        try await client.connect()
        try await client2.connect()
        _ = try await client2.subscribe(to: [.init(topicFilter: "TestSubject", qos: .atLeastOnce)])
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let listener = client2.createPublishListener()
                for try await event in listener {
                    switch event {
                    case .success(let publish):
                        var buffer = publish.payload
                        let string = buffer.readString(length: buffer.readableBytes)
                        XCTAssertEqual(string, payloadString)
                        return
                    case .failure(let error):
                        XCTFail("\(error)")
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                XCTFail("Timeout")
            }
            try await client.publish(to: "TestSubject", payload: ByteBufferAllocator().buffer(string: payloadString), qos: .atLeastOnce)
            try await group.next()
            group.cancelAll()
        }

        try await client.disconnect()
        try await client2.disconnect()
        try await client.shutdown()
        try await client2.shutdown()
    }

    func testPing() async throws {
        let client = MQTTClient(
            host: Self.hostname,
            port: 1883,
            identifier: "TestPing",
            eventLoopGroupProvider: .createNew,
            logger: Self.logger,
            configuration: .init(disablePing: true)
        )

        try await client.connect()
        try await client.ping()
        try await client.disconnect()
        try await client.shutdown()
    }

    func testAsyncSequencePublishListener() async throws {
        let client = self.createClient(identifier: "testAsyncSequencePublishListener+async", version: .v5_0)
        let client2 = self.createClient(identifier: "testAsyncSequencePublishListener+async2", version: .v5_0)

        try await client.connect()
        try await client2.connect()
        _ = try await client2.v5.subscribe(to: [.init(topicFilter: "TestSubject", qos: .atLeastOnce)])
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let publishListener = client2.createPublishListener()
                for await result in publishListener {
                    switch result {
                    case .success(let publish):
                        var buffer = publish.payload
                        let string = buffer.readString(length: buffer.readableBytes)
                        print("Received: \(string ?? "nothing")")
                        return

                    case .failure(let error):
                        XCTFail("\(error)")
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                XCTFail("Timeout")
            }
            try await client.publish(to: "TestSubject", payload: ByteBufferAllocator().buffer(string: "Hello"), qos: .atLeastOnce)
            try await client.publish(to: "TestSubject", payload: ByteBufferAllocator().buffer(string: "Goodbye"), qos: .atLeastOnce)

            try await group.next()
            group.cancelAll()
        }
        try await client.disconnect()
        try await client2.disconnect()
        try await client.shutdown()
        try await client2.shutdown()
    }

    func testAsyncSequencePublishSubscriptionIdListener() async throws {
        let client = self.createClient(identifier: "testAsyncSequencePublishSubscriptionIdListener+async", version: .v5_0)
        let client2 = self.createClient(identifier: "testAsyncSequencePublishSubscriptionIdListener+async2", version: .v5_0)
        let payloadString = "Hello"

        try await client.connect()
        try await client2.connect()
        _ = try await client2.v5.subscribe(to: [.init(topicFilter: "TestSubject", qos: .atLeastOnce)], properties: [.subscriptionIdentifier(1)])
        _ = try await client2.v5.subscribe(to: [.init(topicFilter: "TestSubject2", qos: .atLeastOnce)], properties: [.subscriptionIdentifier(2)])
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let publishListener = client2.v5.createPublishListener(subscriptionId: 1)
                for await event in publishListener {
                    XCTAssertEqual(String(buffer: event.payload), payloadString)
                    return
                }
            }
            group.addTask {
                let publishListener = client2.v5.createPublishListener(subscriptionId: 2)
                for await event in publishListener {
                    XCTAssertEqual(String(buffer: event.payload), payloadString)
                    return
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                XCTFail("Timeout")
            }
            try await client.publish(to: "TestSubject", payload: ByteBufferAllocator().buffer(string: payloadString), qos: .atLeastOnce)
            try await client.publish(to: "TestSubject2", payload: ByteBufferAllocator().buffer(string: payloadString), qos: .atLeastOnce)

            try await group.next()
            try await group.next()
            group.cancelAll()
        }

        try await client.disconnect()
        try await client2.disconnect()
        try client.syncShutdownGracefully()
        try client2.syncShutdownGracefully()
    }

    func testMQTTPublishRetain() async throws {
        let payloadString = #"{"from":1000000,"to":1234567,"type":1,"content":"I am a beginner in swift and I am studying hard!!测试\n\n test, message","timestamp":1607243024,"nonce":"pAx2EsUuXrVuiIU3GGOGHNbUjzRRdT5b","sign":"ff902e31a6a5f5343d70a3a93ac9f946adf1caccab539c6f3a6"}"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        let client = self.createClient(identifier: "testMQTTPublishRetain_publisher")
        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        let client2 = self.createClient(identifier: "testMQTTPublishRetain_subscriber")
        defer { XCTAssertNoThrow(try client2.syncShutdownGracefully()) }
        try await client.connect()
        try await client.publish(to: "testAsyncMQTTPublishRetain", payload: payload, qos: .atLeastOnce, retain: true)
        try await client2.connect()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let listener = client2.createPublishListener()
                for try await event in listener {
                    switch event {
                    case .success(let publish):
                        var buffer = publish.payload
                        let string = buffer.readString(length: buffer.readableBytes)
                        XCTAssertEqual(string, payloadString)
                        return
                    case .failure(let error):
                        XCTFail("\(error)")
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                XCTFail("Timeout")
            }
            _ = try await client2.subscribe(to: [.init(topicFilter: "testAsyncMQTTPublishRetain", qos: .atLeastOnce)])
            try await group.next()
            group.cancelAll()
        }

        try await client.disconnect()
        try await client2.disconnect()
    }
}

#endif // compiler(>=5.5)
