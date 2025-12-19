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
    var subscriptionIDMap: [Int: SubscriptionRef]
    var subscriptionMap: [TopicFilter: MQTTTopicStateMachine<SubscriptionRef>]
    let logger: Logger

    static let globalSubscriptionID = Atomic<Int>(0)

    init(logger: Logger) {
        self.subscriptionIDMap = [:]
        self.logger = logger
        self.subscriptionMap = [:]
    }

    /// We received a message
    mutating func notify(_ message: MQTTPublishInfo) {
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
    }

    /// Connection is closing, let's inform all the subscriptions
    mutating func close(error: any Error) {
        for subscription in subscriptionIDMap.values {
            subscription.sendError(error)
        }
        self.subscriptionIDMap = [:]
        self.subscriptionMap = [:]
    }

    static func getSubscriptionID() -> Int {
        Self.globalSubscriptionID.wrappingAdd(1, ordering: .relaxed).newValue
    }

    enum SubscribeAction {
        case doNothing(Int)
        case subscribe(SubscriptionRef)
    }

    /// Add subscription to topic.
    mutating func addSubscription(
        continuation: MQTTSubscription.Continuation,
        subscriptions: [MQTTSubscribeInfoV5]
    ) throws -> SubscribeAction {
        let id = Self.getSubscriptionID()
        let subscription = SubscriptionRef(
            id: id,
            continuation: continuation,
            topicFilters: try subscriptions.map { try TopicFilter($0.topicFilter) }
        )
        subscriptionIDMap[id] = subscription
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
    }

    enum UnsubscribeAction {
        case doNothing
        case unsubscribe([String])
    }

    /// Add unsubscribe
    ///
    /// Remove subscription from all the message topics.
    /// If a message topic ends up with no subscriptions, then add it to the list of topics to unsubscribe from.
    mutating func unsubscribe(id: Int) -> UnsubscribeAction {
        var action: UnsubscribeAction = .doNothing
        guard let subscription = subscriptionIDMap[id] else { return .doNothing }
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
        self.subscriptionIDMap[id] = nil
        return action
    }

    /// Remove subscription
    mutating func removeSubscription(id: Int) {
        guard let subscription = subscriptionIDMap[id] else { return }
        for topicFilter in subscription.topicFilters {
            switch self.subscriptionMap[topicFilter]?.close(subscription: subscription) {
            case .doNothing, .none:
                break
            case .unsubscribe:
                self.subscriptionMap[topicFilter] = nil
            }
        }
        subscriptionIDMap[id] = nil
    }
}

/// Individual subscription associated with one subscribe
final class SubscriptionRef: Identifiable {
    let id: Int
    let topicFilters: [TopicFilter]
    let continuation: MQTTSubscription.Continuation

    init(id: Int, continuation: MQTTSubscription.Continuation, topicFilters: [TopicFilter]) {
        self.id = id
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
