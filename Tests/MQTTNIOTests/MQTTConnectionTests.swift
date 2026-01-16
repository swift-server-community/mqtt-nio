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

import Logging
import NIOCore
import NIOEmbedded
import Testing

@testable import MQTTNIO

@Suite("MQTTConnection Tests")
struct MQTTConnectionTests {
    func withTestMQTTServer(
        logger: Logger = Logger(label: "test"),
        client clientOperation: @Sendable @escaping (MQTTConnection) async throws -> Void,
        server serverOperation: @Sendable @escaping (Channel) async throws -> Void,
    ) async throws {
        let channel = NIOAsyncTestingChannel()
        let connection = try await MQTTConnection.setupChannelAndConnect(channel, logger: logger)
        return try await withThrowingTaskGroup { group in
            group.addTask {
                defer { connection.close() }
                try await connection.sendConnect()
                do {
                    try await clientOperation(connection)
                    try await connection.sendDisconnect()
                } catch {
                    try? await connection.sendDisconnect()
                }
            }
            group.addTask {
                // wait for connect
                var connectBuffer = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
                let packet = try MQTTIncomingPacket.read(from: &connectBuffer)
                #expect(packet.type == .CONNECT)
                #expect(packet.packetId == 0)

                var buffer = ByteBuffer()
                try MQTTConnAckPacket(returnCode: 0, acknowledgeFlags: 1, properties: .init()).write(version: .v3_1_1, to: &buffer)
                try await channel.writeInbound(buffer)
                try await serverOperation(channel)

                // wait for disconnect
                var disconnectBuffer = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
                let disconnectPacket = try MQTTIncomingPacket.read(from: &disconnectBuffer)
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
