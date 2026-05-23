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

    let subscriptionsQueue: AsyncStream<SessionSubscriptionTask>
    @usableFromInline
    let subscriptionsQueueContinuation: AsyncStream<SessionSubscriptionTask>.Continuation

    let logger: Logger

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
        (self.subscriptionsQueue, self.subscriptionsQueueContinuation) = AsyncStream.makeStream()
        self.logger = logger
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

    /// Wait until there are no active subscriptions opened via this session or via any ``MQTTConnection``s using this session.
    ///
    /// This function waits only for subscriptions that have been acknowledged by the server,
    /// so for example if a subscription is opened via this ``MQTTSession`` but the session is not passed to a ``MQTTConnection``,
    /// this function will not wait for that subscription.
    ///
    /// If new subscriptions are opened while waiting, this function will also wait for those subscriptions to complete.
    public func waitUntilNoActiveSubscriptions() async {
        await withCheckedContinuation { continuation in
            self.subscriptions.withLock { subscriptions in
                if subscriptions.subscriptionIDMap.isEmpty {
                    self.logger.trace("No active subscriptions to wait for")
                    continuation.resume()
                    return
                }
                self.logger.trace("Waiting for \(subscriptions.subscriptionIDMap.count) active subscriptions to complete")
                subscriptions.emptySubscriptionsContinuations.append(continuation)
            }
        }
        self.logger.trace("All active subscriptions completed")
    }
}
