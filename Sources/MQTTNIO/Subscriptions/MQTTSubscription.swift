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

/// A sequence of messages from a MQTT subscription.
public struct MQTTSubscription: AsyncSequence, Sendable {
    /// The type that the sequence produces.
    public typealias Element = MQTTPublishInfo

    typealias BaseAsyncSequence = AsyncThrowingStream<MQTTPublishInfo, any Error>
    typealias Continuation = BaseAsyncSequence.Continuation

    let base: BaseAsyncSequence

    static func makeStream() -> (Self, Self.Continuation) {
        let (stream, continuation) = BaseAsyncSequence.makeStream()
        return (.init(base: stream), continuation)
    }

    /// Creates a sequence of subscription messages.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: self.base.makeAsyncIterator())
    }

    /// An iterator that provides subscription messages.
    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: BaseAsyncSequence.AsyncIterator

        @concurrent
        public mutating func next() async throws -> Element? {
            try await self.base.next()
        }

        public mutating func next(isolation actor: isolated (any Actor)?) async throws(any Error) -> MQTTPublishInfo? {
            try await self.base.next(isolation: actor)
        }
    }
}
