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

import Logging
@testable import MQTTNIO
import MQTTTypes
import NIO
import XCTest

// tests separated out because it requires symbols from MQTTTypes
final class MQTTNIOPacketTests: XCTestCase {
    static let hostname = ProcessInfo.processInfo.environment["MOSQUITTO_SERVER"] ?? "localhost"
    let logger: Logger = {
        var logger = Logger(label: "MQTTTests")
        logger.logLevel = .trace
        return logger
    }()

    func testMQTTServerClose() throws {
        struct MQTTForceDisconnectMessage: MQTTPacket {
            var type: MQTTPacketType { .PUBLISH }
            var description: String { "FORCEDISCONNECT" }

            func write(version: MQTTVersion, to byteBuffer: inout ByteBuffer) throws {
                // writing publish header with no content will cause a disconnect from the server
                byteBuffer.writeInteger(UInt8(0x30))
                byteBuffer.writeInteger(UInt8(0x0))
            }

            static func read(version: MQTTVersion, from packet: MQTTIncomingPacket) throws -> Self {
                throw InternalError.notImplemented
            }
        }

        let client = MQTTClient(
            host: Self.hostname,
            identifier: "testMQTTServerClose",
            eventLoopGroupProvider: .createNew,
            logger: self.logger
        )

        defer { XCTAssertNoThrow(try client.syncShutdownGracefully()) }
        _ = try client.connect().wait()
        XCTAssertThrowsError(_ = try client.connection?.sendMessage(MQTTForceDisconnectMessage()) { _ in true }.wait()) { error in
            switch error {
            case MQTTError.serverClosedConnection:
                break
            default:
                XCTFail("\(error)")
            }
        }

        XCTAssertFalse(client.isActive())
    }
}
