//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2025 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import Testing

@testable import MQTTNIO

@Suite("MQTTConnection Tests")
struct MQTTConnectionTests {
    func withTestMQTTServer(
        configuration: MQTTConnectionConfiguration = .init(),
        cleanSession: Bool = true,
        identifier: String = UUID().uuidString,
        logger: Logger = Logger(label: "test"),
        client clientOperation: @Sendable @escaping (MQTTConnection) async throws -> Void,
        server serverOperation: @Sendable @escaping (Channel) async throws -> Void,
    ) async throws {
        let channel = NIOAsyncTestingChannel()
        let connection = try await MQTTConnection.setupChannelAndConnect(
            channel,
            configuration: configuration,
            cleanSession: cleanSession,
            identifier: identifier,
            logger: logger
        )
        let version = configuration.version
        return try await withThrowingTaskGroup { group in
            group.addTask {
                defer { connection.close() }
                try await connection.sendConnect()
                try await clientOperation(connection)
            }
            group.addTask {
                // wait for connect
                let packet = try await channel.waitForOutboundPacket()
                #expect(packet.type == .CONNECT)
                #expect(packet.packetId == 0)

                let connack = MQTTConnAckPacket(returnCode: 0, acknowledgeFlags: 1, properties: .init())
                try await channel.writeInboundPacket(connack, version: version)

                try await serverOperation(channel)

                // wait for disconnect
                let disconnectPacket = try await channel.waitForOutboundPacket()
                #expect(disconnectPacket.type == .DISCONNECT)
                #expect(disconnectPacket.packetId == 0)
            }
            try await group.waitForAll()
        }
    }

    @Test
    func testConnectDisconnect() async throws {
        try await withTestMQTTServer { _ in
        } server: { _ in
        }
    }
}

extension NIOAsyncTestingChannel {
    func waitForOutboundPacket() async throws -> MQTTIncomingPacket {
        var buffer = try await self.waitForOutboundWrite(as: ByteBuffer.self)
        return try MQTTIncomingPacket.read(from: &buffer)
    }

    func writeInboundPacket(_ packet: some MQTTPacket, version: MQTTConnectionConfiguration.Version) async throws {
        var buffer = ByteBuffer()
        try packet.write(version: version, to: &buffer)
        try await self.writeInbound(buffer)
    }
}
