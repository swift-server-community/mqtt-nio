#if compiler(>=5.5)

import XCTest
import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOHTTP1
#if canImport(NIOSSL)
import NIOSSL
#endif
@testable import MQTTNIO

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
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

    func createClient(identifier: String, timeout: TimeAmount? = .seconds(10)) -> MQTTClient {
        MQTTClient(
            host: Self.hostname,
            port: 1883,
            identifier: identifier,
            eventLoopGroupProvider: .createNew,
            logger: Self.logger,
            configuration: .init(timeout: timeout)
        )
    }

    func testConnect() {
        let client = createClient(identifier: "testConnect+async")
        XCTRunAsyncAndBlock {
            try await client.connect()
            try await client.disconnect()
        }
    }

    func testPublishSubscribe() {
        let client = createClient(identifier: "testPublish+async")
        let client2 = createClient(identifier: "testPublish+async2")
        let payloadString = "Hello"
        XCTRunAsyncAndBlock {
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

        XCTRunAsyncAndBlock {
            try await client.connect()
            try await client.ping()
            try await client.disconnect()
        }
    }
}

#endif // compiler(>=5.5)
