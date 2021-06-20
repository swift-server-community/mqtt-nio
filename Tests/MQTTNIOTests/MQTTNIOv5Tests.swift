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

    let logger: Logger = {
        var logger = Logger(label: "MQTTTests")
        logger.logLevel = .trace
        return logger
    }()
}
