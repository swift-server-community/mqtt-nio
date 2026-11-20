//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

import Testing

@testable import MQTTNIO

struct KeepAliveCrashTests {
    @Test(arguments: [UInt16(0), 1, 2, 3, 4, 5, 30, 60, UInt16.max])
    func serverKeepAliveDoesNotUnderflow(seconds: UInt16) async throws {
        try await withTestMQTTServer(
            configuration: .init(versionConfiguration: .v5_0()),
            connackProperties: [.serverKeepAlive(seconds)]
        ) { connection in
            try await connection.ping()
        } server: { channel in
            #expect(try await channel.waitForOutboundPacket().type == .PINGREQ)
            try await channel.writeInboundPacket(MQTTPingrespPacket(), version: .v5_0)
        }
    }
}
