//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

import Logging
import Synchronization

struct MQTTSubscriptions: Sendable {
    var subscriptionIDMap: [UInt32: SubscriptionRef]
    var subscriptionMap: [TopicFilter: MQTTTopicStateMachine<SubscriptionRef>]
    let logger: Logger

    /// See ``MQTTConnection/waitUntilNoActiveSubscriptions()``
    var emptySubscriptionsContinuations: [Int: CheckedContinuation<Void, any Error>]

    static let globalSubscriptionID = Atomic<UInt32>(0)

    init(logger: Logger) {
        self.subscriptionIDMap = [:]
        self.logger = logger
        self.subscriptionMap = [:]
        self.emptySubscriptionsContinuations = [:]
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

    /// Connection is closing, let's inform all the subscriptions that are not opened by the session
    mutating func close(error: any Error) {
        // If the error is `MQTTError.noSessionPresent`,
        // then we should close also the subscriptions opened by the session
        let noSessionPresent = if case MQTTError.noSessionPresent = error { true } else { false }

        // send error to subscription
        for subscription in self.subscriptionIDMap.values where !subscription.openedBySession || noSessionPresent {
            subscription.sendError(error)
            self.removeSubscription(id: subscription.id)
        }

        self.resumeWaitForEmptySubscriptions(.failure(error))
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
    ///
    /// - Parameters:
    ///   - id: Provide a subscription ID if the subscription was opened by a ``MQTTSession``.
    ///         If `nil`, a new subscription ID will automatically be generated.
    ///   - continuation: The subscription stream continuation to send messages to.
    ///   - subscriptions: The list of topic filters and QoS levels to subscribe to.
    ///   - usesSubscriptionIdentifiers: Whether PUBLISH packets are matched to this subscription by Subscription Identifier.
    ///         If `false` they are matched by topic name.
    mutating func addSubscription(
        id: UInt32?,
        continuation: MQTTSubscription.Continuation,
        subscriptions: [MQTTSubscribeInfoV5],
        usesSubscriptionIdentifiers: Bool
    ) throws -> SubscribeAction {
        let subID = id ?? Self.getSubscriptionID()
        let subscription = SubscriptionRef(
            id: subID,
            usesSubscriptionIdentifiers: usesSubscriptionIdentifiers,
            continuation: continuation,
            topicFilters: try subscriptions.map { try TopicFilter($0.topicFilter) },
            openedBySession: id != nil
        )
        defer { subscriptionIDMap[subID] = subscription }
        if !usesSubscriptionIdentifiers {
            var action = SubscribeAction.doNothing(subID)
            for topicFilter in subscription.topicFilters {
                switch subscriptionMap[topicFilter, default: .init()].add(subscription: subscription) {
                case .subscribe:
                    action = .subscribe(subscription)
                case .doNothing:
                    break
                }
            }
            return action
        } else {
            switch self.subscriptionIDMap[subID] {
            case .none:
                return .subscribe(subscription)
            case .some:
                return .doNothing(subID)
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
        defer {
            self.subscriptionIDMap[id] = nil
            if self.subscriptionIDMap.isEmpty {
                self.resumeWaitForEmptySubscriptions(.success(()))
            }
        }
        if !subscription.usesSubscriptionIdentifiers {
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
        } else {
            return .unsubscribe(subscription.topicFilters.map { $0.string })
        }
    }

    /// Remove subscription
    mutating func removeSubscription(id: UInt32) {
        guard let subscription = subscriptionIDMap[id] else { return }
        if !subscription.usesSubscriptionIdentifiers {
            for topicFilter in subscription.topicFilters {
                switch self.subscriptionMap[topicFilter]?.close(subscription: subscription) {
                case .doNothing, .none:
                    break
                case .unsubscribe:
                    self.subscriptionMap[topicFilter] = nil
                }
            }
        }
        subscriptionIDMap[id] = nil
    }

    mutating func addWaitForEmptySubscriptions(id: Int, continuation: CheckedContinuation<Void, any Error>) {
        self.emptySubscriptionsContinuations[id] = continuation
    }

    mutating func cancelWaitForEmptySubscriptions(id: Int) {
        let continuation = self.emptySubscriptionsContinuations.removeValue(forKey: id)
        continuation?.resume(throwing: CancellationError())
    }

    mutating func resumeWaitForEmptySubscriptions(_ result: Result<Void, any Error>) {
        // send error to empty subscription continuation
        for cont in self.emptySubscriptionsContinuations.values {
            cont.resume(with: result)
        }
        self.emptySubscriptionsContinuations.removeAll()
    }
}

/// Individual subscription associated with one subscribe
final class SubscriptionRef: Identifiable, Sendable {
    let id: UInt32
    let usesSubscriptionIdentifiers: Bool
    let topicFilters: [TopicFilter]
    let continuation: MQTTSubscription.Continuation
    let openedBySession: Bool

    fileprivate init(
        id: UInt32,
        usesSubscriptionIdentifiers: Bool,
        continuation: MQTTSubscription.Continuation,
        topicFilters: [TopicFilter],
        openedBySession: Bool
    ) {
        self.id = id
        self.usesSubscriptionIdentifiers = usesSubscriptionIdentifiers
        self.topicFilters = topicFilters
        self.continuation = continuation
        self.openedBySession = openedBySession
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
