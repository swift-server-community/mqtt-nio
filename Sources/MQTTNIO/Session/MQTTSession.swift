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

public import Logging
import NIOCore
import Synchronization

/// Represents an MQTT session, holding session state such as inflight messages.
/// Used by ``MQTTConnection`` to manage session state across connections.
public final class MQTTSession: Sendable {
    private let _clientID: Mutex<String>

    /// Whether a ``MQTTConnection`` is currently connected using this session.
    let isConnected: Atomic<Bool>

    /// Inflight messages
    let inflightPackets: Mutex<MQTTInflight>

    let subscriptions: Mutex<MQTTSubscriptions>

    let subscriptionsQueue: Mutex<SessionSubscriptionTaskQueue>

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
    /// - Parameters:
    ///   - clientID: Client identifier to use for this session. This must be unique.
    ///   - logger: Logger to use for this session.
    public init(clientID: String, logger: Logger) {
        self._clientID = .init(clientID)
        self.inflightPackets = .init(.init())
        self.subscriptions = .init(.init(logger: logger))
        self.isConnected = .init(false)
        self.subscriptionsQueue = .init(.init())
    }
}

// MARK: - Client ID

extension MQTTSession {
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
}

// MARK: - Inflight Messages

extension MQTTSession {
    /// Used for testing
    package var inflightPacketsCount: Int {
        self.inflightPackets.withLock { $0.packets.count }
    }
}

// MARK: - Subscriptions

extension MQTTSession {
    /// Information about a queued subscription opened via a ``MQTTSession``.
    @usableFromInline
    struct QueuedSubscription: Sendable {
        /// The unique identifier for this subscription, used in ``MQTTSubscriptions``.
        let id: UInt32
        /// The continuation used to send messages to the subscription stream opened via a ``MQTTSession``.
        let continuation: MQTTSubscription.Continuation
        /// The subscription information for this subscription, used to create the SUBSCRIBE packet.
        let subscriptions: [MQTTSubscribeInfoV5]
        /// MQTT v5 properties to include in the SUBSCRIBE packet for this subscription.
        let properties: MQTTProperties
    }

    /// Information about a queued unsubscription for a subscription opened via a ``MQTTSession``.
    @usableFromInline
    struct QueuedUnsubscription: Sendable {
        /// The unique identifier for the subscription, used in ``MQTTSubscriptions``.
        let id: UInt32
        /// MQTT v5 properties to include in the UNSUBSCRIBE packet.
        let properties: MQTTProperties

        @usableFromInline
        init(id: UInt32, properties: MQTTProperties) {
            self.id = id
            self.properties = properties
        }
    }

    /// A task sent by the ``MQTTSession`` to the ``MQTTConnection`` to manage subscriptions opened via the session.
    @usableFromInline
    enum SessionSubscriptionTask: Sendable {
        case subscribe(QueuedSubscription)
        case unsubscribe(QueuedUnsubscription)
    }

    struct SessionSubscriptionTaskQueue {
        var queue: [SessionSubscriptionTask]
        var continuation: AsyncStream<SessionSubscriptionTask>.Continuation?

        init() {
            self.queue = []
            self.continuation = nil
        }

        mutating func add(_ task: SessionSubscriptionTask) {
            if let continuation = self.continuation {
                continuation.yield(task)
            } else {
                self.queue.append(task)
            }
        }

        mutating func makeAsyncStream() -> AsyncStream<SessionSubscriptionTask> {
            let (stream, continuation) = AsyncStream<SessionSubscriptionTask>.makeStream()
            self.continuation = continuation
            for task in self.queue {
                continuation.yield(task)
            }
            self.queue.removeAll()
            return stream
        }
    }
}
