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

import Atomics
import Logging
import NIO
import NIOFoundationCompat
import NIOHTTP1
import XCTest

@testable import MQTTNIO

#if os(macOS) || os(Linux)
import NIOSSL
#endif

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
final class AsyncMQTTNIOTests: XCTestCase {
    static let hostname = ProcessInfo.processInfo.environment["MOSQUITTO_SERVER"] ?? "localhost"
    static let logger: Logger = {
        var logger = Logger(label: "MQTTTests")
        logger.logLevel = .trace
        return logger
    }()

    func createClient(identifier: String, configuration: MQTTClient.Configuration = .init()) -> MQTTClient {
        MQTTClient(
            host: Self.hostname,
            port: 1883,
            identifier: identifier,
            eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
            logger: Self.logger,
            configuration: configuration
        )
    }

    func withMQTTClient(
        identifier: String,
        configuration: MQTTClient.Configuration = .init(),
        operation: (MQTTClient) async throws -> Void
    ) async throws {
        let client = createClient(identifier: identifier, configuration: configuration)
        do {
            try await operation(client)
        } catch {
            try? await client.shutdown()
            throw error
        }
        try await client.shutdown()
    }

    func testConnect() async throws {
        try await withMQTTClient(identifier: "testConnect+async") { client in
            try await client.connect()
            try await client.disconnect()
        }
    }

    func testPublishSubscribe() async throws {
        try await withMQTTClient(identifier: "testPublish+async") { client in
            try await withMQTTClient(identifier: "testPublish+async2") { client2 in
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

                try await client2.disconnect()
            }
            try await client.disconnect()
        }
    }

    func testPing() async throws {
        try await withMQTTClient(identifier: "TestPing", configuration: .init(disablePing: true)) { client in
            try await client.connect()
            try await client.ping()
            try await client.disconnect()
        }
    }

    func testAsyncSequencePublishListener() async throws {
        try await withMQTTClient(identifier: "testAsyncSequencePublishListener+async", configuration: .init(version: .v5_0)) { client in
            try await withMQTTClient(identifier: "testAsyncSequencePublishListener+async2", configuration: .init(version: .v5_0)) { client2 in

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
                try await client2.disconnect()
            }
            try await client.disconnect()
        }
    }

    func testAsyncSequencePublishSubscriptionIdListener() async throws {
        try await withMQTTClient(identifier: "testAsyncSequencePublishSubscriptionIdListener+async", configuration: .init(version: .v5_0)) { client in
            try await withMQTTClient(identifier: "testAsyncSequencePublishSubscriptionIdListener+async2", configuration: .init(version: .v5_0)) {
                client2 in
                let payloadString = "Hello"

                try await client.connect()
                try await client2.connect()
                _ = try await client2.v5.subscribe(
                    to: [.init(topicFilter: "TestSubject", qos: .atLeastOnce)],
                    properties: [.subscriptionIdentifier(1)]
                )
                _ = try await client2.v5.subscribe(
                    to: [.init(topicFilter: "TestSubject2", qos: .atLeastOnce)],
                    properties: [.subscriptionIdentifier(2)]
                )
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

                try await client2.disconnect()
            }
            try await client.disconnect()
        }
    }

    func testMQTTPublishRetain() async throws {
        let payloadString =
            #"{"from":1000000,"to":1234567,"type":1,"content":"I am a beginner in swift and I am studying hard!!测试\n\n test, message","timestamp":1607243024,"nonce":"pAx2EsUuXrVuiIU3GGOGHNbUjzRRdT5b","sign":"ff902e31a6a5f5343d70a3a93ac9f946adf1caccab539c6f3a6"}"#
        let payload = ByteBufferAllocator().buffer(string: payloadString)

        try await withMQTTClient(identifier: "testMQTTPublishRetain_publisher+async") { client in
            try await withMQTTClient(identifier: "testMQTTPublishRetain_subscriber+async") { client2 in
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

                try await client2.disconnect()
            }
            try await client.disconnect()
        }
    }

    func testPersistentSubscription() async throws {
        let count = ManagedAtomic(0)
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        try await withMQTTClient(identifier: "testPublish+async") { client in
            try await withMQTTClient(identifier: "testPublish+async2") { client2 in
                let payloadString = "Hello"
                try await client.connect()
                try await client2.connect(cleanSession: false)
                _ = try await client2.subscribe(to: [.init(topicFilter: "TestSubject", qos: .atLeastOnce)])
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        let listener = client2.createPublishListener()
                        cont.finish()
                        for try await event in listener {
                            switch event {
                            case .success(let publish):
                                var buffer = publish.payload
                                let string = buffer.readString(length: buffer.readableBytes)
                                XCTAssertEqual(string, payloadString)
                                let value = count.wrappingIncrementThenLoad(by: 1, ordering: .relaxed)
                                if value == 2 {
                                    return
                                }
                            case .failure(let error):
                                XCTFail("\(error)")
                            }
                        }
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        XCTFail("Timeout")
                    }
                    await stream.first { _ in true }
                    try await client.publish(to: "TestSubject", payload: ByteBufferAllocator().buffer(string: payloadString), qos: .atLeastOnce)
                    try await client2.disconnect()
                    try await client2.connect(cleanSession: false)
                    try await client.publish(to: "TestSubject", payload: ByteBufferAllocator().buffer(string: payloadString), qos: .atLeastOnce)
                    try await group.next()
                    group.cancelAll()
                }

                try await client2.disconnect()
            }
            try await client.disconnect()
        }
        XCTAssertEqual(count.load(ordering: .relaxed), 2)
    }

    func testSubscriptionListenerEndsOnCleanSessionDisconnect() async throws {
        try await withMQTTClient(identifier: "testPublish+async") { client in
            try await withMQTTClient(identifier: "testPublish+async2") { client2 in
                let payloadString = "Hello"
                try await client.connect()
                try await client2.connect(cleanSession: true)
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
                    try await client2.disconnect()
                    try await group.next()
                    group.cancelAll()
                }
            }
            try await client.disconnect()
        }
    }
}
