//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2026 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import Synchronization

public final class MQTTSession: Sendable {
    /// Client Identifier
    public let clientID: String

    /// Inflight messages
    let inflightPackets: Mutex<CircularBuffer<any MQTTPacket>>

    /// Used for testing
    package var inflightPacketsCount: Int {
        self.inflightPackets.withLock { $0.count }
    }

    /// Initialize a new ``MQTTSession`` with a unique client identifier
    ///
    /// - Parameter clientID: Client identifier to use for this session. This must be unique.
    public init(clientID: String) {
        self.clientID = clientID
        self.inflightPackets = .init(.init(initialCapacity: 4))
    }

    /// Add packet to inflight messages
    func addInflight(packet: MQTTPacket) {
        self.inflightPackets.withLock { $0.append(packet) }
    }

    /// Remove packet from inflight messages by packet identifier
    func removeInflight(id: UInt16) {
        self.inflightPackets.withLock { buffer in
            guard let first = buffer.firstIndex(where: { $0.packetId == id }) else { return }
            buffer.remove(at: first)
        }
    }

    /// Remove all packets from inflight messages
    func clearInflight() {
        self.inflightPackets.withLock { $0.removeAll() }
    }
}
