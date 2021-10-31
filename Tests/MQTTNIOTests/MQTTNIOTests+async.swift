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
            try client.syncShutdownGracefully()
        }
    }

    func testPublishSubscribe() {
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
                case .failure(let error):
                    XCTFail("\(error)")
                }
            }
            try await client.publish(to: "TestSubject", payload: ByteBufferAllocator().buffer(string: payloadString), qos: .atLeastOnce)
            try await client.disconnect()
            Thread.sleep(forTimeInterval: 2)
            try await client2.disconnect()
            try client.syncShutdownGracefully()
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
            try client.syncShutdownGracefully()
        }
    }

    func testAsyncSequencePublishListener() {
        let client = createClient(identifier: "testAsyncSequencePublishListener+async", version: .v5_0)
        let client2 = createClient(identifier: "testAsyncSequencePublishListener+async2", version: .v5_0)
        let payloadString = "Hello"
        XCTRunAsyncAndBlock {
            try await client.connect()
            try await client2.connect()
            _ = try await client2.v5.subscribe(to: [.init(topicFilter: "TestSubject", qos: .atLeastOnce)])
            let task = Task { () -> Int in
                var count = 0
                let publishListener = client2.createPublishListener()
                for await result in publishListener {
                    switch result {
                    case .success(let publish):
                        var buffer = publish.payload
                        let string = buffer.readString(length: buffer.readableBytes)
                        XCTAssertEqual(string, payloadString)
                        count += 1
                        print("Count: \(count)")
                    case .failure(let error):
                        XCTFail("\(error)")
                    }
                }
                print("Done: \(count+1)")
                return count + 1
            }
            try await client.publish(to: "TestSubject", payload: ByteBufferAllocator().buffer(string: payloadString), qos: .atLeastOnce)
            try await client.publish(to: "TestSubject", payload: ByteBufferAllocator().buffer(string: payloadString), qos: .atLeastOnce)
            try await client.disconnect()
            Thread.sleep(forTimeInterval: 1)
            try await client2.disconnect()
            
            try client.syncShutdownGracefully()
            try client2.syncShutdownGracefully()

            let result = await task.result
            XCTAssertEqual(result, .success(3))
        }
    }
}

#endif // compiler(>=5.5)
