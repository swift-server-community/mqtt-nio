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
import NIO

class MQTTChannelHandler: ChannelDuplexHandler {
    struct Configuration {
        let disablePing: Bool
        let pingInterval: TimeAmount
        let timeout: TimeAmount?
        let version: MQTTClient.Version
    }

    typealias InboundIn = ByteBuffer
    typealias InboundOut = MQTTPacket
    typealias OutboundIn = MQTTPacket
    typealias OutboundOut = ByteBuffer

    private let eventLoop: any EventLoop
    private let publishListeners: MQTTListeners<Result<MQTTPublishInfo, Error>>

    var decoder: NIOSingleStepByteToMessageProcessor<ByteToMQTTMessageDecoder>
    private let logger: Logger
    private let configuration: Configuration

    var tasks: [MQTTTask]

    var pingreqTimeout: TimeAmount
    var lastPingreqEventTime: NIODeadline
    var pingreqCallback: NIOScheduledCallback?

    init(
        configuration: Configuration,
        eventLoop: any EventLoop,
        logger: Logger,
        publishListeners: MQTTListeners<Result<MQTTPublishInfo, Error>>
    ) {
        self.configuration = configuration
        self.eventLoop = eventLoop
        self.publishListeners = publishListeners
        self.decoder = .init(.init(version: configuration.version))
        self.logger = logger

        self.tasks = []

        self.pingreqTimeout = configuration.pingInterval
        self.lastPingreqEventTime = .now()
        self.pingreqCallback = nil
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            if !self.configuration.disablePing {
                guard self.pingreqCallback == nil else { return }
                self.schedulePingreqCallback(context)
            }
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        if !self.configuration.disablePing {
            guard self.pingreqCallback == nil else { return }
            self.schedulePingreqCallback(context)
        }
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.pingreqCallback?.cancel()
        self.pingreqCallback = nil

        // channel is inactive so we should fail or tasks in progress
        self.failTasks(with: MQTTError.serverClosedConnection)

        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // we caught an error so we should fail all active tasks
        self.failTasks(with: error)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let message = unwrapOutboundIn(data)
        self.logger.trace("MQTT Out", metadata: ["mqtt_message": .string("\(message)"), "mqtt_packet_id": .string("\(message.packetId)")])
        var bb = context.channel.allocator.buffer(capacity: 0)
        do {
            try message.write(version: self.configuration.version, to: &bb)
            context.write(wrapOutboundOut(bb), promise: promise)
        } catch {
            promise?.fail(error)
        }
        self.lastPingreqEventTime = .now()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)

        do {
            try self.decoder.process(buffer: buffer) { message in
                switch message.type {
                case .PUBLISH:
                    let publishMessage = message as! MQTTPublishPacket
                    // publish logging includes topic name
                    self.logger.trace(
                        "MQTT In",
                        metadata: [
                            "mqtt_message": .stringConvertible(publishMessage),
                            "mqtt_packet_id": .stringConvertible(publishMessage.packetId),
                            "mqtt_topicName": .string(publishMessage.publish.topicName),
                        ]
                    )
                    self.respondToPublish(publishMessage, context: context)
                    return

                case .CONNACK, .PUBACK, .PUBREC, .PUBCOMP, .SUBACK, .UNSUBACK, .PINGRESP, .AUTH:
                    self.taskHandlingOnChannelRead(context: context, response: message)
                    context.fireChannelRead(wrapInboundOut(message))

                case .PUBREL:
                    self.respondToPubrel(message, context: context)
                    self.taskHandlingOnChannelRead(context: context, response: message)
                    context.fireChannelRead(wrapInboundOut(message))

                case .DISCONNECT:
                    let disconnectMessage = message as! MQTTDisconnectPacket
                    let ack = MQTTAckV5(reason: disconnectMessage.reason, properties: disconnectMessage.properties)
                    let error = MQTTError.serverDisconnection(ack)
                    self.failTasks(with: error)
                    context.fireErrorCaught(error)
                    context.close(promise: nil)

                case .CONNECT, .SUBSCRIBE, .UNSUBSCRIBE, .PINGREQ:
                    let error = MQTTError.unexpectedMessage
                    self.failTasks(with: error)
                    context.fireErrorCaught(error)
                    context.close(promise: nil)
                    self.logger.error("Unexpected MQTT Message", metadata: ["mqtt_message": .string("\(message)")])
                    return
                }
                self.logger.trace(
                    "MQTT In",
                    metadata: ["mqtt_message": .stringConvertible(message), "mqtt_packet_id": .stringConvertible(message.packetId)]
                )
            }
        } catch {
            self.failTasks(with: error)
            context.fireErrorCaught(error)
            context.close(promise: nil)
            self.logger.error("Error processing MQTT message", metadata: ["mqtt_error": .string("\(error)")])
        }
    }

    /// Respond to PUBLISH message
    /// If QoS is `.atMostOnce` then no response is required
    /// If QoS is `.atLeastOnce` then send PUBACK
    /// If QoS is `.exactlyOnce` then send PUBREC, wait for PUBREL and then respond with PUBCOMP (in `respondToPubrel`)
    private func respondToPublish(_ message: MQTTPublishPacket, context: ChannelHandlerContext) {
        switch message.publish.qos {
        case .atMostOnce:
            self.publishListeners.notify(.success(message.publish))

        case .atLeastOnce:
            context.channel.writeAndFlush(MQTTPubAckPacket(type: .PUBACK, packetId: message.packetId))
                .map { _ in message.publish }
                .whenComplete { self.publishListeners.notify($0) }

        case .exactlyOnce:
            var publish = message.publish
            self.sendMessage(channel: context.channel, MQTTPubAckPacket(type: .PUBREC, packetId: message.packetId)) { newMessage in
                guard newMessage.packetId == message.packetId else { return false }
                // if we receive a publish message while waiting for a PUBREL from broker then replace data to be published and retry PUBREC
                if newMessage.type == .PUBLISH, let publishMessage = newMessage as? MQTTPublishPacket {
                    publish = publishMessage.publish
                    throw MQTTError.retrySend
                }
                // if we receive anything but a PUBREL then throw unexpected message
                guard newMessage.type == .PUBREL else { throw MQTTError.unexpectedMessage }
                // now we have received the PUBREL we can process the published message. PUBCOMP is sent by `respondToPubrel`
                return true
            }
            .map { _ in publish }
            .whenComplete { result in
                // do not report retrySend error
                if case .failure(let error) = result, case MQTTError.retrySend = error {
                    return
                }
                self.publishListeners.notify(result)
            }
        }
    }

    /// Respond to PUBREL message by sending PUBCOMP. Do this separate from `responeToPublish` as the broker might send
    /// multiple PUBREL messages, if the client is slow to respond
    private func respondToPubrel(_ message: MQTTPacket, context: ChannelHandlerContext) {
        _ = context.channel.writeAndFlush(MQTTPubAckPacket(type: .PUBCOMP, packetId: message.packetId))
    }

    // MARK: - Sending Messages

    private func sendMessage(
        channel: any Channel,
        _ message: MQTTPacket,
        promise: MQTTPromise<MQTTPacket>,
        checkInbound: @escaping (MQTTPacket) throws -> Bool
    ) {
        let task = MQTTTask(
            promise: promise,
            on: channel.eventLoop,
            timeout: self.configuration.timeout,
            checkInbound: checkInbound
        )

        self.addTask(task)
            .flatMap {
                channel.writeAndFlush(message)
            }
            .whenFailure { error in
                task.fail(error)
            }
    }

    func sendMessage(
        channel: any Channel,
        _ message: MQTTPacket,
        checkInbound: @escaping (MQTTPacket) throws -> Bool
    ) async throws -> MQTTPacket {
        try await withCheckedThrowingContinuation { continuation in
            self.sendMessage(channel: channel, message, promise: .swift(continuation), checkInbound: checkInbound)
        }
    }

    func sendMessage(
        channel: any Channel,
        _ message: MQTTPacket,
        checkInbound: @escaping (MQTTPacket) throws -> Bool
    ) -> EventLoopFuture<MQTTPacket> {
        let promise = self.eventLoop.makePromise(of: MQTTPacket.self)
        self.sendMessage(channel: channel, message, promise: .nio(promise), checkInbound: checkInbound)
        return promise.futureResult
    }

    // MARK: - Task Handling

    func addTask(_ task: MQTTTask) -> EventLoopFuture<Void> {
        if self.eventLoop.inEventLoop {
            self.tasks.append(task)
            return self.eventLoop.makeSucceededVoidFuture()
        } else {
            return self.eventLoop.submit {
                self.tasks.append(task)
            }
        }
    }

    private func removeTask(_ task: MQTTTask) {
        if self.eventLoop.inEventLoop {
            self.tasks.removeAll { $0 === task }
        } else {
            self.eventLoop.execute {
                self.tasks.removeAll { $0 === task }
            }
        }
    }

    func taskHandlingOnChannelRead(context: ChannelHandlerContext, response: MQTTPacket) {
        for task in self.tasks {
            do {
                // should this task respond to inbound packet
                if try task.checkInbound(response) {
                    self.removeTask(task)
                    task.succeed(response)
                    return
                }
            } catch {
                self.removeTask(task)
                task.fail(error)
                return
            }
        }

        self.processUnhandledPacket(response, context: context)
    }

    /// process packets where no equivalent task was found
    func processUnhandledPacket(_ packet: MQTTPacket, context: ChannelHandlerContext) {
        // we only send response to v5 server
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

    func failTasks(with error: Error) {
        self.tasks.forEach { $0.fail(error) }
        self.tasks.removeAll()
    }

    // MARK: - Pingreq Handling

    struct MQTTPingreqSchedule: NIOScheduledCallbackHandler {
        let channelHandler: NIOLoopBound<MQTTChannelHandler>
        let context: NIOLoopBound<ChannelHandlerContext>

        func handleScheduledCallback(eventLoop: some EventLoop) {
            let channelHandler = self.channelHandler.value
            let context = self.context.value
            // if lastEventTime plus the timeout is less than now send PINGREQ
            // otherwise reschedule task
            if channelHandler.lastPingreqEventTime + channelHandler.pingreqTimeout <= .now() {
                guard context.channel.isActive else { return }
                channelHandler.sendMessage(channel: context.channel, MQTTPingreqPacket()) { message in
                    guard message.type == .PINGRESP else { return false }
                    return true
                }
                .whenComplete { result in
                    switch result {
                    case .failure(let error):
                        channelHandler.failTasks(with: error)
                        context.fireErrorCaught(error)
                    case .success:
                        break
                    }
                    channelHandler.lastPingreqEventTime = .now()
                    channelHandler.schedulePingreqCallback(context)
                }
            } else {
                channelHandler.schedulePingreqCallback(context)
            }
        }
    }

    func updatePingreqTimeout(_ timeout: TimeAmount) {
        self.pingreqTimeout = timeout
    }

    func schedulePingreqCallback(_ context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }

        self.pingreqCallback = try? context.eventLoop.scheduleCallback(
            at: self.lastPingreqEventTime + self.pingreqTimeout,
            handler: MQTTPingreqSchedule(
                channelHandler: .init(self, eventLoop: context.eventLoop),
                context: .init(context, eventLoop: context.eventLoop)
            )
        )
    }
}
