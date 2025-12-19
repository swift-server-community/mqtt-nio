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
import Testing

@testable import MQTTNIO

@Suite("MQTTSubscriptions Tests")
struct MQTTSubscriptionsTests {
    @Test("Subscribe and Unsubscribe")
    func subscribeAndUnsubscribe() throws {
        var subscriptions = MQTTSubscriptions(logger: self.logger)
        let subscribeInfos = [
            MQTTSubscribeInfoV5(topicFilter: "test/topic/1", qos: .atMostOnce),
            MQTTSubscribeInfoV5(topicFilter: "test/topic/2/#", qos: .atLeastOnce),
            MQTTSubscribeInfoV5(topicFilter: "test/+/3", qos: .exactlyOnce),
        ]
        let (_, continuation) = MQTTSubscription.makeStream()

        var subscriptionID = 0

        switch try subscriptions.addSubscription(continuation: continuation, subscriptions: subscribeInfos) {
        case .subscribe(let subscriptionRef):
            subscriptionID = subscriptionRef.id
            #expect(subscriptionID > 0)
            #expect(subscriptionRef.topicFilters.count == 3)
        case .doNothing:
            Issue.record("Expected to subscribe")
        }
        #expect(subscriptions.subscriptionIDMap[subscriptionID] != nil)
        for topicFilter in subscribeInfos.map({ $0.topicFilter }) {
            let tf = try TopicFilter(topicFilter)
            #expect(subscriptions.subscriptionMap[tf] != nil)
        }

        switch subscriptions.unsubscribe(id: subscriptionID) {
        case .unsubscribe(let topicFilters):
            #expect(topicFilters.count == 3)
        case .doNothing:
            Issue.record("Expected to unsubscribe")
        }
        #expect(subscriptions.subscriptionIDMap[subscriptionID] == nil)
        for topicFilter in subscribeInfos.map({ $0.topicFilter }) {
            let tf = try TopicFilter(topicFilter)
            #expect(subscriptions.subscriptionMap[tf] != nil)
        }
    }

    @Test("Subscribe and Remove")
    func subscribeAndRemove() throws {
        var subscriptions = MQTTSubscriptions(logger: self.logger)
        let subscribeInfos = [
            MQTTSubscribeInfoV5(topicFilter: "test/topic/1", qos: .atMostOnce),
            MQTTSubscribeInfoV5(topicFilter: "test/topic/2/#", qos: .atLeastOnce),
            MQTTSubscribeInfoV5(topicFilter: "test/+/3", qos: .exactlyOnce),
        ]
        let (_, continuation) = MQTTSubscription.makeStream()

        var subscriptionID = 0

        switch try subscriptions.addSubscription(continuation: continuation, subscriptions: subscribeInfos) {
        case .subscribe(let subscriptionRef):
            subscriptionID = subscriptionRef.id
            #expect(subscriptionID > 0)
            #expect(subscriptionRef.topicFilters.count == 3)
        case .doNothing:
            Issue.record("Expected to subscribe")
        }
        #expect(subscriptions.subscriptionIDMap[subscriptionID] != nil)
        for topicFilter in subscribeInfos.map({ $0.topicFilter }) {
            let tf = try TopicFilter(topicFilter)
            #expect(subscriptions.subscriptionMap[tf] != nil)
        }

        subscriptions.removeSubscription(id: subscriptionID)
        #expect(subscriptions.subscriptionIDMap[subscriptionID] == nil)
        for topicFilter in subscribeInfos.map({ $0.topicFilter }) {
            let tf = try TopicFilter(topicFilter)
            #expect(subscriptions.subscriptionMap[tf] == nil)
        }
    }

    let logger: Logger = {
        var logger = Logger(label: "MQTTNIOTests")
        logger.logLevel = .trace
        return logger
    }()
}
