//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

import NIOCore

/// Array of inflight packets. Used to resend packets when reconnecting to server
struct MQTTInflight: Sendable {
    init() {
        self.packets = .init(initialCapacity: 4)
    }

    /// add packet
    mutating func add(packet: any MQTTPacket) {
        self.packets.append(packet)
    }

    /// remove packet
    mutating func remove(id: UInt16) {
        guard let first = self.packets.firstIndex(where: { $0.packetId == id }) else { return }
        self.packets.remove(at: first)
    }

    /// remove all packets
    mutating func clear() {
        self.packets = []
    }

    var packets: CircularBuffer<any MQTTPacket>
}
