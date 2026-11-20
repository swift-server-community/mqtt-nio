//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

import Logging
import NIOCore
import NIOEmbedded
import Testing

@testable import MQTTNIO

struct ConnackPropertiesTests {
    @Test func successfulPropertiesAvailableInConnectionClosure() async throws {
        let properties: MQTTProperties = [.receiveMaximum(1), .maximumPacketSize(4096), .userProperty("region", "test")]
        try await withTestMQTTServer(configuration: .init(versionConfiguration: .v5_0()), connackProperties: properties) { connection in
            #expect(await connection.connackProperties == properties)
        } server: { _ in
        }
    }

    @Test func mqtt311HasNoProperties() async throws {
        try await withTestMQTTServer { connection in
            #expect(await connection.connackProperties.count == 0)
        } server: { _ in
        }
    }

    @Test(arguments: [false, true])
    func propertiesOnlySetAfterSuccess(refused: Bool) async throws {
        let channel = NIOAsyncTestingChannel()
        let connection = try await MQTTConnection.setupChannelAndConnect(
            channel,
            configuration: .init(versionConfiguration: .v5_0()),
            session: .init(clientID: "connack-properties-test", logger: Logger(label: "connack-properties-test"))
        )
        #expect(await connection.connackProperties.count == 0)
        let properties: MQTTProperties = [.receiveMaximum(2)]
        let connect = Task { try await connection.sendConnect(clientID: "connack-properties-test", cleanSession: true) }
        _ = try await channel.waitForOutboundPacket()
        try await channel.writeInboundPacket(
            MQTTConnAckPacket(
                returnCode: refused ? MQTTReasonCode.notAuthorized.rawValue : 0,
                acknowledgeFlags: 0,
                properties: properties
            ),
            version: .v5_0
        )
        if refused {
            await #expect(throws: MQTTError.reasonError(.init(reason: .notAuthorized, properties: properties))) {
                try await connect.value
            }
            #expect(await connection.connackProperties.count == 0)
        } else {
            #expect(try await connect.value == false)
            #expect(await connection.connackProperties == properties)
        }
        _ = await connection.closeAndCleanup(sendDisconnect: false)
    }
}
