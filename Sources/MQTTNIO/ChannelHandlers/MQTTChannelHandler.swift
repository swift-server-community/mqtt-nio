//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2021 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIOCore
import Synchronization

final class MQTTChannelHandler: ChannelDuplexHandler {
    struct Configuration {
        let disablePing: Bool
        let pingInterval: TimeAmount
        let timeout: TimeAmount?
        let version: MQTTConnectionConfiguration.Version
    }

    typealias InboundIn = ByteBuffer
    typealias InboundOut = MQTTPacket
    typealias OutboundIn = MQTTPacket
    typealias OutboundOut = ByteBuffer

    private let eventLoop: any EventLoop
    @usableFromInline
    var stateMachine: StateMachine<ChannelHandlerContext>
    let session: MQTTSession

    private var decoder: NIOSingleStepByteToMessageProcessor<ByteToMQTTMessageDecoder>
    private let logger: Logger
    private let configuration: Configuration

    private var pingreqTimeout: TimeAmount
    private var lastPingreqEventTime: NIODeadline
    private var pingreqCallback: NIOScheduledCallback?

    /// The Maximum Packet Size for this Server.
    var maxPacketSize: UInt32 = .max

    init(
        configuration: Configuration,
        eventLoop: any EventLoop,
        session: MQTTSession,
        logger: Logger
    ) {
        self.configuration = configuration
        self.eventLoop = eventLoop
        self.session = session
        self.decoder = .init(.init(version: configuration.version))
        self.stateMachine = .init()
        self.logger = logger

        self.pingreqTimeout = configuration.pingInterval
        self.lastPingreqEventTime = .now()
        self.pingreqCallback = nil
    }

    private func setInitialized(context: ChannelHandlerContext) {
        self.stateMachine.setInitialized(context: context)
        if !self.configuration.disablePing {
            guard self.pingreqCallback == nil else { return }
            self.schedulePingreqCallback()
        }
    }

    func waitOnInitialized() -> EventLoopFuture<Void> {
        switch self.stateMachine.waitOnInitialized() {
        case .reportedClosed(let error):
            return self.eventLoop.makeFailedFuture(error ?? MQTTError.connectionClosed)
        case .done:
            return self.eventLoop.makeSucceededVoidFuture()
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            self.setInitialized(context: context)
        }
        self.logger.trace("MQTTChannelHandler added to pipeline, channel.isActive: \(context.channel.isActive)")
    }

    func channelActive(context: ChannelHandlerContext) {
        self.setInitialized(context: context)
        self.logger.trace("Channel became active.")
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.pingreqCallback?.cancel()
        self.pingreqCallback = nil

        // channel is inactive so we should fail all tasks in progress
        self.failTasksAndCloseSubscriptions(with: MQTTError.serverClosedConnection)
        self.logger.trace("Channel became inactive.")

        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // we caught an error so we should fail all active tasks
        self.failTasksAndCloseSubscriptions(with: error)
        self.logger.error("Error caught in channel handler: \(error)")
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let message = unwrapOutboundIn(data)
        var bb = context.channel.allocator.buffer(capacity: 0)
        do {
            try message.write(version: self.configuration.version, to: &bb)
            guard bb.readableBytes <= self.maxPacketSize else {
                throw MQTTError.packetTooLarge
            }
            context.write(wrapOutboundOut(bb), promise: promise)
        } catch {
            promise?.fail(error)
        }
        self.logger.trace("MQTT Out", metadata: ["mqtt_message": .string("\(message)"), "mqtt_packet_id": .string("\(message.packetId)")])
        self.lastPingreqEventTime = .now()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        do {
            try self.decoder.process(buffer: buffer) { message in
                self.logger.trace(
                    "MQTT In",
                    metadata: ["mqtt_message": .stringConvertible(message), "mqtt_packet_id": .stringConvertible(message.packetId)]
                )
                switch self.stateMachine.receivedPacket(message) {
                case .respondAndReturn:
                    let publishMessage = message as! MQTTPublishPacket
                    // publish logging includes topic name
                    self.logger.trace(
                        "MQTT Publish In",
                        metadata: [
                            "mqtt_topicName": .string(publishMessage.publish.topicName)
                        ]
                    )
                    self.respondToPublish(publishMessage, context: context)
                    return
                case .succeedTask(let task):
                    if message.type == .PUBREL {
                        self.respondToPubrel(message, context: context)
                    }
                    task.succeed(message)
                case .failTask(let task, let error):
                    task.fail(error)
                case .unhandledTask:
                    self.processUnhandledPacket(message, context: context)
                case .closeConnection(let error):
                    self.failTasksAndCloseSubscriptions(with: error)
                    context.fireErrorCaught(error)
                    context.close(promise: nil)
                    if case MQTTError.unexpectedMessage = error {
                        self.logger.error("Unexpected MQTT Message", metadata: ["mqtt_message": .string("\(message)")])
                        return
                    }
                }
            }
        } catch {
            self.failTasksAndCloseSubscriptions(with: error)
            context.fireErrorCaught(error)
            context.close(promise: nil)
            self.logger.error("Error processing MQTT message", metadata: ["mqtt_error": .string("\(error)")])
        }
    }

    @usableFromInline
    func cancel(requestID: Int, error: any Error = MQTTError.cancelledTask) {
        self.eventLoop.assertInEventLoop()
        switch self.stateMachine.cancel(requestID: requestID) {
        case .failTask(let cancelledTask):
            cancelledTask.promise.fail(error)
        case .doNothing:
            break
        }
    }

    /// Respond to PUBLISH message
    /// If QoS is `.atMostOnce` then no response is required
    /// If QoS is `.atLeastOnce` then send PUBACK
    /// If QoS is `.exactlyOnce` then send PUBREC, wait for PUBREL and then respond with PUBCOMP (in `respondToPubrel`)
    private func respondToPublish(_ message: MQTTPublishPacket, context: ChannelHandlerContext) {
        struct DuplicatePublishError: Error {}
        switch message.publish.qos {
        case .atMostOnce:
            self.session.subscriptions.withLock { $0.notify(message.publish) }

        case .atLeastOnce:
            context.channel.writeAndFlush(MQTTPubAckPacket(type: .PUBACK, packetId: message.packetId))
                .assumeIsolated()
                .map { _ in message.publish }
                .whenComplete { result in
                    switch result {
                    case .success(let publish):
                        self.session.subscriptions.withLock { $0.notify(publish) }
                    case .failure(let error):
                        self.failTasksAndCloseSubscriptions(with: error)
                        context.fireErrorCaught(error)
                        context.close(promise: nil)
                        self.logger.error("Error sending PUBACK", metadata: ["mqtt_error": .string("\(error)")])
                    }
                }

        case .exactlyOnce:
            self.sendMessage(
                MQTTPubAckPacket(type: .PUBREC, packetId: message.packetId),
                requestID: MQTTConnection.requestIDGenerator.next()
            ) { newMessage in
                guard newMessage.packetId == message.packetId else { return false }
                // if we receive a publish message while waiting for a PUBREL from server this is a
                // duplicate. We need to reset the response and send a PUBREC again. Here we throw an error
                // which is caught further down and at that trigger a new PUBREC
                if newMessage.type == .PUBLISH {
                    throw DuplicatePublishError()
                }
                // if we receive anything but a PUBREL then throw unexpected message
                guard newMessage.type == .PUBREL else { throw MQTTError.unexpectedMessage }
                // now we have received the PUBREL we can process the published message. PUBCOMP is sent by `respondToPubrel`
                return true
            }
            .assumeIsolated()
            .whenComplete { result in
                switch result {
                case .failure(let error):
                    switch error {
                    case is DuplicatePublishError:
                        // ignore duplicate publish error and initiate the PUBLISH handshake again
                        self.respondToPublish(message, context: context)
                        return
                    default:
                        self.failTasksAndCloseSubscriptions(with: error)
                        context.fireErrorCaught(error)
                        context.close(promise: nil)
                        self.logger.error("Error during QoS 2 publish flow", metadata: ["mqtt_error": .string("\(error)")])
                    }
                case .success:
                    self.session.subscriptions.withLock { $0.notify(message.publish) }
                }
            }
        }
    }

    /// Respond to PUBREL message by sending PUBCOMP. Do this separate from `responeToPublish` as the broker might send
    /// multiple PUBREL messages, if the client is slow to respond
    private func respondToPubrel(_ message: any MQTTPacket, context: ChannelHandlerContext) {
        _ = context.channel.writeAndFlush(MQTTPubAckPacket(type: .PUBCOMP, packetId: message.packetId))
    }

    // MARK: - Subscriptions

    /// Add a subscription to ``MQTTSubscriptions``.
    ///
    /// - Parameters:
    ///   - id: Provide a subscription ID if the subscription was opened by a ``MQTTSession``.
    ///         If `nil`, a new subscription ID will automatically be generated.
    ///   - continuation: The subscription stream continuation to send messages to.
    ///   - packet: The ``MQTTSubscribePacket`` containing the subscription information.
    ///   - promise: The promise to complete with the subscription ID once the subscription is added.
    ///   - requestID: The request ID for the subscribe operation.
    func subscribe(
        id: UInt32? = nil,
        streamContinuation: MQTTSubscription.Continuation,
        packet: MQTTSubscribePacket,
        promise: MQTTPromise<UInt32>,
        requestID: Int
    ) {
        self.eventLoop.assertInEventLoop()

        let subscribeAction: MQTTSubscriptions.SubscribeAction
        do {
            subscribeAction = try self.session.subscriptions.withLock { subscriptions in
                try subscriptions.addSubscription(
                    id: id,
                    continuation: streamContinuation,
                    subscriptions: packet.subscriptions,
                    version: self.configuration.version
                )
            }
        } catch {
            promise.fail(error)
            return
        }
        switch subscribeAction {
        case .subscribe(let subscription):
            let subscriptionID = subscription.id
            guard !packet.subscriptions.isEmpty else {
                promise.fail(MQTTPacketError.atLeastOneTopicRequired)
                return
            }
            var packet = packet
            if self.configuration.version == .v5_0 {
                var properties = packet.properties ?? []
                properties.append(.subscriptionIdentifier(subscriptionID))
                packet = MQTTSubscribePacket(
                    subscriptions: packet.subscriptions,
                    properties: properties,
                    packetId: packet.packetId
                )
            }
            self.sendMessage(packet, requestID: requestID) { message in
                guard message.packetId == packet.packetId else { return false }
                guard message.type == .SUBACK else { throw MQTTError.unexpectedMessage }
                return true
            }.assumeIsolated().whenComplete { result in
                switch result {
                case .success:
                    promise.succeed(subscriptionID)
                case .failure(let error):
                    self.session.subscriptions.withLock { $0.removeSubscription(id: subscriptionID) }
                    promise.fail(error)
                }
            }
        case .doNothing(let subscriptionID):
            promise.succeed(subscriptionID)
        }
    }

    func unsubscribe(
        id: UInt32,
        packetID: UInt16,
        properties: MQTTProperties,
        promise: MQTTPromise<Void>,
        requestID: Int
    ) {
        self.eventLoop.assertInEventLoop()
        switch self.session.subscriptions.withLock({ $0.unsubscribe(id: id) }) {
        case .unsubscribe(let subscriptions):
            let packet = MQTTUnsubscribePacket(subscriptions: subscriptions, properties: properties, packetId: packetID)
            guard !packet.subscriptions.isEmpty else {
                promise.fail(MQTTPacketError.atLeastOneTopicRequired)
                return
            }
            self.sendMessage(packet, requestID: requestID) { message in
                guard message.packetId == packet.packetId else { return false }
                guard message.type == .UNSUBACK else { throw MQTTError.unexpectedMessage }
                return true
            }.assumeIsolated().whenComplete { result in
                switch result {
                case .success:
                    promise.succeed(())
                case .failure(let error):
                    promise.fail(error)
                }
            }
        case .doNothing:
            promise.succeed(())
        }
    }

    // MARK: - Sending Messages

    func sendMessageNoWait(_ message: any MQTTPacket) throws {
        self.eventLoop.assertInEventLoop()
        switch self.stateMachine.sendPacket(nil) {
        case .sendPacket(let context):
            var sendError: (any Error)?
            context.channel.writeAndFlush(message).assumeIsolated().whenFailure { error in
                sendError = error
            }
            if let sendError { throw sendError }
        case .throwError(let error):
            throw error
        }
    }

    func sendMessage(
        _ message: any MQTTPacket,
        promise: MQTTPromise<any MQTTPacket>,
        requestID: Int,
        checkInbound: @escaping (any MQTTPacket) throws -> Bool
    ) {
        self.eventLoop.assertInEventLoop()

        let task = MQTTTask(
            promise: promise,
            requestID: requestID,
            on: self.eventLoop,
            timeout: self.configuration.timeout,
            checkInbound: checkInbound
        )

        switch self.stateMachine.sendPacket(task) {
        case .sendPacket(let context):
            context.channel.writeAndFlush(message).assumeIsolated().whenFailure { error in
                self.cancel(requestID: requestID, error: error)
            }
        case .throwError(let error):
            task.fail(error)
        }
    }

    func sendMessage(
        _ message: any MQTTPacket,
        requestID: Int,
        checkInbound: @escaping (any MQTTPacket) throws -> Bool
    ) -> EventLoopFuture<any MQTTPacket> {
        let promise = self.eventLoop.makePromise(of: (any MQTTPacket).self)
        self.sendMessage(message, promise: .nio(promise), requestID: requestID, checkInbound: checkInbound)
        return promise.futureResult
    }

    // MARK: - Task Handling

    /// process packets where no equivalent task was found
    private func processUnhandledPacket(_ packet: any MQTTPacket, context: ChannelHandlerContext) {
        // we only send response to v5 server
        guard self.configuration.version == .v5_0 else { return }
        switch packet.type {
        case .PUBREC:
            _ = context.channel.writeAndFlush(
                MQTTPubAckPacket(
                    type: .PUBREL,
                    packetId: packet.packetId,
                    reason: .packetIdentifierNotFound
                )
            )
        case .PUBREL:
            _ = context.channel.writeAndFlush(
                MQTTPubAckPacket(
                    type: .PUBCOMP,
                    packetId: packet.packetId,
                    reason: .packetIdentifierNotFound
                )
            )
        default:
            break
        }
    }

    private func failTasksAndCloseSubscriptions(with error: any Error) {
        switch self.stateMachine.close() {
        case .failTasksAndClose(let tasks):
            for task in tasks {
                task.fail(error)
            }
            self.session.subscriptions.withLock { $0.close(error: error) }
        case .doNothing:
            break
        }
    }

    // MARK: - Pingreq Handling

    struct MQTTPingreqSchedule: NIOScheduledCallbackHandler {
        let channelHandler: NIOLoopBound<MQTTChannelHandler>

        func handleScheduledCallback(eventLoop: some EventLoop) {
            let channelHandler = self.channelHandler.value
            switch channelHandler.stateMachine.schedulePingReq() {
            case .doNothing:
                break
            case .schedule(let context):
                // if lastEventTime plus the timeout is less than now send PINGREQ
                // otherwise reschedule task
                if channelHandler.lastPingreqEventTime + channelHandler.pingreqTimeout <= .now() {
                    guard context.channel.isActive else { return }
                    channelHandler.sendMessage(
                        MQTTPingreqPacket(),
                        requestID: MQTTConnection.requestIDGenerator.next()
                    ) { message in
                        guard message.type == .PINGRESP else { return false }
                        return true
                    }
                    .assumeIsolated()
                    .whenComplete { result in
                        switch result {
                        case .failure(let error):
                            channelHandler.failTasksAndCloseSubscriptions(with: error)
                            context.fireErrorCaught(error)
                        case .success:
                            break
                        }
                        channelHandler.lastPingreqEventTime = .now()
                        channelHandler.schedulePingreqCallback()
                    }
                } else {
                    channelHandler.schedulePingreqCallback()
                }
            }
        }
    }

    func updatePingreqTimeout(_ timeout: TimeAmount) {
        self.pingreqTimeout = timeout
    }

    func schedulePingreqCallback() {
        self.pingreqCallback = try? self.eventLoop.scheduleCallback(
            at: self.lastPingreqEventTime + self.pingreqTimeout,
            handler: MQTTPingreqSchedule(channelHandler: .init(self, eventLoop: self.eventLoop))
        )
    }
}

extension MQTTChannelHandler.Configuration {
    init(_ other: MQTTConnectionConfiguration) {
        self.disablePing = other.disablePing
        self.pingInterval = other.pingInterval ?? .seconds(5)  // TODO: fix this
        self.timeout = other.timeout
        self.version = other.version
    }
}
