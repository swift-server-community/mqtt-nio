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
    private let _clientID: Mutex<String>

    /// Client Identifier for this session.
    ///
    /// If you provided an empty string as the Client Identifier when initializing this session,
    /// the MQTT server should have generated a unique Client Identifier for you on the first connection with this session.
    /// If that first connection was a MQTT v5 connection,
    /// this property will contain the assigned Client Identifier.
    public var clientID: String {
        self._clientID.withLock { $0 }
    }

    func setClientID(_ clientID: String) {
        self._clientID.withLock { $0 = clientID }
    }

    /// Inflight messages
    let inflightPackets: Mutex<CircularBuffer<any MQTTPacket>>

    /// Used for testing
    package var inflightPacketsCount: Int {
        self.inflightPackets.withLock { $0.count }
    }

    /// Initialize a new ``MQTTSession`` with a unique client identifier.
    ///
    /// If you provide an empty string as the Client Identifier,
    /// the MQTT server should generate a unique Client Identifier for you on the first connection with this session.
    ///
    /// If that first connection was a MQTT v5 connection,
    /// you can retrieve the assigned Client Identifier from ``MQTTSession/clientID`` after the connection is established.
    /// If you reuse the same session for other connections,
    /// the following connections will use the new Client Identifier assigned by the server.
    ///
    /// - Parameter clientID: Client identifier to use for this session. This must be unique.
    public init(clientID: String) {
        self._clientID = .init(clientID)
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
