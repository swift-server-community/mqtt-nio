#if compiler(>=5.5) && canImport(_Concurrency)

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

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
final class AsyncMQTTNIOTests: XCTestCase {
    static let hostname = ProcessInfo.processInfo.environment["MOSQUITTO_SERVER"] ?? "localhost"
    static let logger: Logger = {
        var logger = Logger(label: "MQTTTests")
        logger.logLevel = .trace
        return logger
    }()

    func XCTRunAsyncAndBlock(_ closure: @escaping () async throws -> Void) {
        let dg = DispatchGroup()
        dg.enter()
        Task {
            do {
                try await closure()
            } catch {
                XCTFail("\(error)")
            }
            dg.leave()
        }
        dg.wait()
    }

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

    func testConnect() {
        let client = self.createClient(identifier: "testConnect+async")
        self.XCTRunAsyncAndBlock {
            try await client.connect()
            try await client.disconnect()
            try await client.shutdown()
        }
    }

    func testPublishSubscribe() {
        let expectation = XCTestExpectation(description: "testPublishSubscribe")
        expectation.expectedFulfillmentCount = 1

        let client = self.createClient(identifier: "testPublish+async")
        let client2 = self.createClient(identifier: "testPublish+async2")
        let payloadString = "Hello"
        self.XCTRunAsyncAndBlock {
            try await client.connect()
            try await client2.connect()
            _ = try await client2.subscribe(to: [.init(topicFilter: "TestSubject", qos: .atLeastOnce)])
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
            try await client.publish(to: "TestSubject", payload: ByteBufferAllocator().buffer(string: payloadString), qos: .atLeastOnce)

            self.wait(for: [expectation], timeout: 2)

            try await client.disconnect()
            try await client2.disconnect()
            try await client.shutdown()
            try await client2.shutdown()
        }
    }

    func testPing() {
        let client = MQTTClient(
            host: Self.hostname,
            port: 1883,
            identifier: "TestPing",
            eventLoopGroupProvider: .createNew,
            logger: Self.logger,
            configuration: .init(disablePing: true)
        )

        self.XCTRunAsyncAndBlock {
            try await client.connect()
            try await client.ping()
            try await client.disconnect()
            try await client.shutdown()
        }
    }

    func testAsyncSequencePublishListener() {
        let expectation = XCTestExpectation(description: "testAsyncSequencePublishListener")
        expectation.expectedFulfillmentCount = 2
        let finishExpectation = XCTestExpectation(description: "testAsyncSequencePublishListener.finish")
        finishExpectation.expectedFulfillmentCount = 1

        let client = self.createClient(identifier: "testAsyncSequencePublishListener+async", version: .v5_0)
        let client2 = self.createClient(identifier: "testAsyncSequencePublishListener+async2", version: .v5_0)

        self.XCTRunAsyncAndBlock {
            try await client.connect()
            try await client2.connect()
            _ = try await client2.v5.subscribe(to: [.init(topicFilter: "TestSubject", qos: .atLeastOnce)])
            let task = Task {
                let publishListener = client2.createPublishListener()
                for await result in publishListener {
                    switch result {
                    case .success(let publish):
                        var buffer = publish.payload
                        let string = buffer.readString(length: buffer.readableBytes)
                        print("Received: \(string ?? "nothing")")
                        expectation.fulfill()

                    case .failure(let error):
                        XCTFail("\(error)")
                    }
                }
                finishExpectation.fulfill()
            }
            try await client.publish(to: "TestSubject", payload: ByteBufferAllocator().buffer(string: "Hello"), qos: .atLeastOnce)
            try await client.publish(to: "TestSubject", payload: ByteBufferAllocator().buffer(string: "Goodbye"), qos: .atLeastOnce)
            try await client.disconnect()

            self.wait(for: [expectation], timeout: 5.0)

            try await client2.disconnect()
            try await client.shutdown()
            try await client2.shutdown()

            self.wait(for: [finishExpectation], timeout: 5.0)

            _ = await task.result
        }
    }

    func testAsyncSequencePublishSubscriptionIdListener() {
        let expectation = XCTestExpectation(description: "publish listener")
        let expectation2 = XCTestExpectation(description: "publish listener2")
        expectation.expectedFulfillmentCount = 3
        expectation2.expectedFulfillmentCount = 2

        let client = self.createClient(identifier: "testAsyncSequencePublishSubscriptionIdListener+async", version: .v5_0)
        let client2 = self.createClient(identifier: "testAsyncSequencePublishSubscriptionIdListener+async2", version: .v5_0)
        let payloadString = "Hello"
        self.XCTRunAsyncAndBlock {
            try await client.connect()
            try await client2.connect()
            _ = try await client2.v5.subscribe(to: [.init(topicFilter: "TestSubject", qos: .atLeastOnce)], properties: [.subscriptionIdentifier(1)])
            _ = try await client2.v5.subscribe(to: [.init(topicFilter: "TestSubject2", qos: .atLeastOnce)], properties: [.subscriptionIdentifier(2)])
            let task = Task {
                let publishListener = client2.v5.createPublishListener(subscriptionId: 1)
                for await _ in publishListener {
                    expectation.fulfill()
                }
                expectation.fulfill()
            }
            let task2 = Task {
                let publishListener = client2.v5.createPublishListener(subscriptionId: 2)
                for await _ in publishListener {
                    expectation2.fulfill()
                }
                expectation2.fulfill()
            }
            try await client.publish(to: "TestSubject", payload: ByteBufferAllocator().buffer(string: payloadString), qos: .atLeastOnce)
            try await client.publish(to: "TestSubject", payload: ByteBufferAllocator().buffer(string: payloadString), qos: .atLeastOnce)
            try await client.publish(to: "TestSubject2", payload: ByteBufferAllocator().buffer(string: payloadString), qos: .atLeastOnce)
            try await client.disconnect()
            Thread.sleep(forTimeInterval: 0.5)
            try await client2.disconnect()
            Thread.sleep(forTimeInterval: 0.5)
            try client.syncShutdownGracefully()
            try client2.syncShutdownGracefully()

            _ = await task.result
            _ = await task2.result
        }
        wait(for: [expectation, expectation2], timeout: 5.0)
    }
}

#endif // compiler(>=5.5)
