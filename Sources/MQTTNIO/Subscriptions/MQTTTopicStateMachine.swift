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

@usableFromInline
struct MQTTTopicStateMachine<Value: Identifiable> where Value: AnyObject {
    @usableFromInline
    enum State {
        case uninitialized
        case active([Value])
        case closed
    }
    @usableFromInline
    var state: State

    init() {
        self.state = .uninitialized
    }

    private init(_ state: consuming State) {
        self.state = state
    }

    @usableFromInline
    enum AddAction {
        case doNothing
        case subscribe
    }
    // Add subscription to topic
    @usableFromInline
    mutating func add(subscription: Value) -> AddAction {
        switch state {
        case .uninitialized:
            self = .active([subscription])
            return .subscribe
        case .active(var subscriptions):
            subscriptions.append(subscription)
            self = .active(subscriptions)
            return .doNothing
        case .closed:
            self = .active([subscription])
            return .subscribe
        }
    }

    @usableFromInline
    enum ReceivedMessageAction {
        case forwardMessage([Value])
        case doNothing
    }
    @usableFromInline
    /// We received a message should we pass it on
    mutating func receivedMessage() -> ReceivedMessageAction {
        switch state {
        case .active(let subscriptions):
            self = .active(subscriptions)
            return .forwardMessage(subscriptions)
        case .uninitialized:
            self = .uninitialized
            return .doNothing
        case .closed:
            self = .closed
            return .doNothing
        }
    }

    @usableFromInline
    enum CloseAction {
        case doNothing
        case unsubscribe
    }
    @usableFromInline
    /// Subscription is being removed from Topic
    mutating func close(subscription: Value) -> CloseAction {
        switch self.state {
        case .uninitialized:
            self = .closed
            return .doNothing
        case .active(var subscriptions):
            if subscriptions.count == 1 {
                precondition(subscriptions[0].id == subscription.id, "Cannot be closing a subscription without adding it")
                self = .closed
                return .unsubscribe
            } else {
                guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else {
                    preconditionFailure("Cannot have added a subscription without adding it")
                }
                subscriptions.remove(at: index)
                self = .active(subscriptions)
                return .doNothing
            }
        case .closed:
            preconditionFailure("Removing a subscription from a closed topic is not allowed")
        }
    }

    private static var uninitialized: Self {
        MQTTTopicStateMachine(.uninitialized)
    }

    private static func active(_ subscriptions: [Value]) -> Self {
        MQTTTopicStateMachine(.active(subscriptions))
    }

    private static var closed: Self {
        MQTTTopicStateMachine(.closed)
    }
}
