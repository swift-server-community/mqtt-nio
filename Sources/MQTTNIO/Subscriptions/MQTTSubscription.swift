//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

/// A sequence of messages from a MQTT subscription.
public struct MQTTSubscription: AsyncSequence, Sendable {
    /// The type that the sequence produces.
    public typealias Element = MQTTPublishInfo

    @usableFromInline
    typealias BaseAsyncSequence = AsyncThrowingStream<Element, any Error>
    typealias Continuation = BaseAsyncSequence.Continuation

    @usableFromInline
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
        @usableFromInline
        var base: BaseAsyncSequence.AsyncIterator

        @concurrent
        @inlinable
        public mutating func next() async throws -> Element? {
            try await self.base.next()
        }

        @inlinable
        public mutating func next(isolation actor: isolated (any Actor)?) async throws -> Element? {
            try await self.base.next(isolation: actor)
        }
    }
}

@available(*, unavailable)
extension MQTTSubscription.AsyncIterator: Sendable {}
