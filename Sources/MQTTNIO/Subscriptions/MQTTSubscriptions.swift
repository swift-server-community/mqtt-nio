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
import Synchronization

struct MQTTSubscriptions {
    var subscriptionIDMap: [UInt32: SubscriptionRef]
    var subscriptionMap: [TopicFilter: MQTTTopicStateMachine<SubscriptionRef>]
    let logger: Logger

    static let globalSubscriptionID = Atomic<UInt32>(0)

    init(logger: Logger) {
        self.subscriptionIDMap = [:]
        self.logger = logger
        self.subscriptionMap = [:]
    }

    /// We received a message
    mutating func notify(_ message: MQTTPublishInfo) {
        let subscriptionIdentifiers = message.properties.compactMap { property in
            // Multiple Subscription Identifiers will be included if the publication is the result of a match to more than one subscription
            if case .subscriptionIdentifier(let id) = property { id } else { nil }
        }
        if subscriptionIdentifiers.isEmpty {
            // No subscription identifiers, so we assume v3.1.1 style matching
            self.logger.trace("Received PUBLISH packet", metadata: ["subscription": "\(message.topicName)"])

            let topicStateMachines = self.subscriptionMap[topicName: message.topicName]
            guard !topicStateMachines.isEmpty else {
                self.logger.trace("Received message for missing subscription", metadata: ["subscription": "\(message.topicName)"])
                return
            }
            for var topicStateMachine in topicStateMachines {
                switch topicStateMachine.receivedMessage() {
                case .forwardMessage(let subscriptions):
                    for subscription in subscriptions {
                        subscription.sendMessage(message)
                    }
                case .doNothing:
                    self.logger.trace("Received message for inactive subscription", metadata: ["subscription": "\(message.topicName)"])
                }
            }
        } else {
            // v5.0 style matching using Subscription Identifiers
            for id in subscriptionIdentifiers {
                self.logger.trace("Received PUBLISH packet", metadata: ["subscriptionID": "\(id)"])
                guard let subscription = self.subscriptionIDMap[id] else {
                    self.logger.trace("Received message for missing subscription", metadata: ["subscriptionID": "\(id)"])
                    continue
                }
                subscription.sendMessage(message)
            }
        }
    }

    /// Connection is closing, let's inform all the subscriptions
    mutating func close(error: any Error) {
        for subscription in subscriptionIDMap.values {
            subscription.sendError(error)
        }
        self.subscriptionIDMap = [:]
        self.subscriptionMap = [:]
    }

    static func getSubscriptionID() -> UInt32 {
        // The Subscription Identifier can have the value of 1 to 268,435,455.
        let id = Self.globalSubscriptionID.wrappingAdd(1, ordering: .relaxed).newValue & 0xfffffff
        // It is a Protocol Error if the Subscription Identifier has a value of 0.
        return id == 0 ? Self.globalSubscriptionID.wrappingAdd(1, ordering: .relaxed).newValue & 0xfffffff : id
    }

    enum SubscribeAction {
        case doNothing(UInt32)
        case subscribe(SubscriptionRef)
    }

    /// Add subscription to topic.
    mutating func addSubscription(
        continuation: MQTTSubscription.Continuation,
        subscriptions: [MQTTSubscribeInfoV5],
        version: MQTTConnectionConfiguration.Version
    ) throws -> SubscribeAction {
        let id = Self.getSubscriptionID()
        let subscription = SubscriptionRef(
            id: id,
            version: version,
            continuation: continuation,
            topicFilters: try subscriptions.map { try TopicFilter($0.topicFilter) }
        )
        defer { subscriptionIDMap[id] = subscription }
        switch version {
        case .v3_1_1:
            var action = SubscribeAction.doNothing(id)
            for topicFilter in subscription.topicFilters {
                switch subscriptionMap[topicFilter, default: .init()].add(subscription: subscription) {
                case .subscribe:
                    action = .subscribe(subscription)
                case .doNothing:
                    break
                }
            }
            return action
        case .v5_0:
            switch self.subscriptionIDMap[id] {
            case .none:
                return .subscribe(subscription)
            case .some:
                return .doNothing(id)
            }
        }
    }

    enum UnsubscribeAction {
        case doNothing
        case unsubscribe([String])
    }

    /// Add unsubscribe
    ///
    /// Remove subscription from all the message topics.
    /// If a message topic ends up with no subscriptions, then add it to the list of topics to unsubscribe from.
    mutating func unsubscribe(id: UInt32) -> UnsubscribeAction {
        guard let subscription = subscriptionIDMap[id] else { return .doNothing }
        defer { self.subscriptionIDMap[id] = nil }
        switch subscription.version {
        case .v3_1_1:
            var action: UnsubscribeAction = .doNothing
            for topicFilter in subscription.topicFilters {
                switch self.subscriptionMap[topicFilter]?.close(subscription: subscription) {
                case .unsubscribe:
                    switch action {
                    case .doNothing:
                        action = .unsubscribe([topicFilter.string])
                    case .unsubscribe(var topics):
                        topics.append(topicFilter.string)
                        action = .unsubscribe(topics)
                    }
                case .doNothing, .none:
                    break
                }
            }
            return action
        case .v5_0:
            return .unsubscribe(subscription.topicFilters.map { $0.string })
        }
    }

    /// Remove subscription
    mutating func removeSubscription(id: UInt32) {
        guard let subscription = subscriptionIDMap[id] else { return }
        switch subscription.version {
        case .v3_1_1:
            for topicFilter in subscription.topicFilters {
                switch self.subscriptionMap[topicFilter]?.close(subscription: subscription) {
                case .doNothing, .none:
                    break
                case .unsubscribe:
                    self.subscriptionMap[topicFilter] = nil
                }
            }
        case .v5_0:
            break
        }
        subscriptionIDMap[id] = nil
    }
}

/// Individual subscription associated with one subscribe
final class SubscriptionRef: Identifiable {
    let id: UInt32
    let version: MQTTConnectionConfiguration.Version
    let topicFilters: [TopicFilter]
    let continuation: MQTTSubscription.Continuation

    init(
        id: UInt32,
        version: MQTTConnectionConfiguration.Version,
        continuation: MQTTSubscription.Continuation,
        topicFilters: [TopicFilter]
    ) {
        self.id = id
        self.version = version
        self.topicFilters = topicFilters
        self.continuation = continuation
    }

    func sendMessage(_ message: MQTTPublishInfo) {
        self.continuation.yield(message)
    }

    func sendError(_ error: any Error) {
        self.continuation.finish(throwing: error)
    }

    func finish() {
        self.continuation.finish()
    }
}
