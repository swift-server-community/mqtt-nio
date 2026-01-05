//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2022 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import Synchronization

/// Array of inflight packets. Used to resend packets when reconnecting to server
struct MQTTInflight: Sendable, ~Copyable {
    init() {
        self.packets = .init(.init(initialCapacity: 4))
    }

    /// add packet
    mutating func add(packet: MQTTPacket) {
        self.packets.withLock {
            $0.append(packet)
        }
    }

    /// remove packert
    mutating func remove(id: UInt16) {
        self.packets.withLock {
            guard let first = $0.firstIndex(where: { $0.packetId == id }) else { return }
            $0.remove(at: first)
        }
    }

    /// remove all packets
    mutating func clear() {
        self.packets.withLock {
            $0 = []
        }
    }

    let packets: Mutex<CircularBuffer<any MQTTPacket>>
}
