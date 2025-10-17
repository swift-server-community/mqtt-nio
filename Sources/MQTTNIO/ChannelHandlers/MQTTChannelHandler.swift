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

    let pingreqHandler: PingreqHandler?

    private let eventLoop: any EventLoop
    private let publishListeners: MQTTListeners<Result<MQTTPublishInfo, Error>>

    var decoder: NIOSingleStepByteToMessageProcessor<ByteToMQTTMessageDecoder>
    private let logger: Logger
    private let configuration: Configuration

    var tasks: [MQTTTask]

    init(
        configuration: Configuration,
        eventLoop: any EventLoop,
        logger: Logger,
        publishListeners: MQTTListeners<Result<MQTTPublishInfo, Error>>,
        _client: MQTTClient
    ) {
        self.configuration = configuration
        if configuration.disablePing {
            self.pingreqHandler = nil
        } else {
            self.pingreqHandler = .init(client: _client, timeout: configuration.pingInterval)
        }
        self.eventLoop = eventLoop
        self.publishListeners = publishListeners
        self.decoder = .init(.init(version: configuration.version))
        self.logger = logger
        self.tasks = []
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            self.pingreqHandler?.start(context: context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        self.pingreqHandler?.start(context: context)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.pingreqHandler?.stop()

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
        self.pingreqHandler?.write()
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
                    self.respondToPublish(context: context, publishMessage)
                    return

                case .CONNACK, .PUBACK, .PUBREC, .PUBCOMP, .SUBACK, .UNSUBACK, .PINGRESP, .AUTH:
                    self.taskHandlingOnChannelRead(context: context, response: message)
                    context.fireChannelRead(wrapInboundOut(message))

                case .PUBREL:
                    self.respondToPubrel(context: context, message)
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

    func updatePingreqTimeout(_ timeout: TimeAmount) {
        self.pingreqHandler?.updateTimeout(timeout)
    }

    /// Respond to PUBLISH message
    /// If QoS is `.atMostOnce` then no response is required
    /// If QoS is `.atLeastOnce` then send PUBACK
    /// If QoS is `.exactlyOnce` then send PUBREC, wait for PUBREL and then respond with PUBCOMP (in `respondToPubrel`)
    private func respondToPublish(context: ChannelHandlerContext, _ message: MQTTPublishPacket) {
        switch message.publish.qos {
        case .atMostOnce:
            self.publishListeners.notify(.success(message.publish))

        case .atLeastOnce:
            context.channel.writeAndFlush(MQTTPubAckPacket(type: .PUBACK, packetId: message.packetId))
                .map { _ in message.publish }
                .whenComplete { self.publishListeners.notify($0) }

        case .exactlyOnce:
            var publish = message.publish
            self.sendMessage(context: context, MQTTPubAckPacket(type: .PUBREC, packetId: message.packetId)) { newMessage in
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
    private func respondToPubrel(context: ChannelHandlerContext, _ message: MQTTPacket) {
        _ = context.channel.writeAndFlush(MQTTPubAckPacket(type: .PUBCOMP, packetId: message.packetId))
    }

    func sendMessage(context: ChannelHandlerContext, _ message: MQTTPacket, checkInbound: @escaping (MQTTPacket) throws -> Bool) -> EventLoopFuture<MQTTPacket> {
        let task = MQTTTask(on: context.channel.eventLoop, timeout: self.configuration.timeout, checkInbound: checkInbound)

        self.addTask(task)
            .flatMap {
                context.channel.writeAndFlush(message)
            }
            .whenFailure { error in
                task.fail(error)
            }
        
        guard case .nio(let promise) = task.promise else {
            fatalError("Only NIO promises are supported here")
        }
        return promise.futureResult
    }

    // MARK: - Task Handling

    func addTask(_ task: MQTTTask) -> EventLoopFuture<Void> {
        if self.eventLoop.inEventLoop {
            self._addTask(task)
            return self.eventLoop.makeSucceededVoidFuture()
        } else {
            return self.eventLoop.submit {
                self.tasks.append(task)
            }
        }
    }

    private func _addTask(_ task: MQTTTask) {
        self.tasks.append(task)
    }

    private func _removeTask(_ task: MQTTTask) {
        self.tasks.removeAll { $0 === task }
    }

    private func removeTask(_ task: MQTTTask) {
        if self.eventLoop.inEventLoop {
            self._removeTask(task)
        } else {
            self.eventLoop.execute {
                self._removeTask(task)
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

        self.processUnhandledPacket(context: context, response)
    }

    /// process packets where no equivalent task was found
    func processUnhandledPacket(context: ChannelHandlerContext, _ packet: MQTTPacket) {
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
}
