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

class MQTTMessageHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = MQTTPacket
    typealias OutboundIn = MQTTPacket
    typealias OutboundOut = ByteBuffer

    let client: MQTTClient
    let pingreqHandler: PingreqHandler?
    var decoder: NIOSingleStepByteToMessageProcessor<ByteToMQTTMessageDecoder>

    init(_ client: MQTTClient, pingInterval: TimeAmount) {
        self.client = client
        if client.configuration.disablePing {
            self.pingreqHandler = nil
        } else {
            self.pingreqHandler = .init(client: client, timeout: pingInterval)
        }
        self.decoder = .init(.init(version: client.configuration.version))
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.pingreqHandler?.start(context: context)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.pingreqHandler?.stop()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let message = unwrapOutboundIn(data)
        self.client.logger.trace("MQTT Out", metadata: ["mqtt_message": .string("\(message)"), "mqtt_packet_id": .string("\(message.packetId)")])
        var bb = context.channel.allocator.buffer(capacity: 0)
        do {
            try message.write(version: self.client.configuration.version, to: &bb)
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
                    self.client.logger.trace("MQTT In", metadata: [
                        "mqtt_message": .stringConvertible(publishMessage),
                        "mqtt_packet_id": .stringConvertible(publishMessage.packetId),
                        "mqtt_topicName": .string(publishMessage.publish.topicName),
                    ])
                    self.respondToPublish(publishMessage)
                    return

                case .CONNACK, .PUBACK, .PUBREC, .PUBCOMP, .SUBACK, .UNSUBACK, .PINGRESP, .AUTH:
                    context.fireChannelRead(wrapInboundOut(message))

                case .PUBREL:
                    self.respondToPubrel(message)
                    context.fireChannelRead(wrapInboundOut(message))

                case .DISCONNECT:
                    let disconnectMessage = message as! MQTTDisconnectPacket
                    let ack = MQTTAckV5(reason: disconnectMessage.reason, properties: disconnectMessage.properties)
                    context.fireErrorCaught(MQTTError.serverDisconnection(ack))
                    context.close(promise: nil)

                case .CONNECT, .SUBSCRIBE, .UNSUBSCRIBE, .PINGREQ:
                    context.fireErrorCaught(MQTTError.unexpectedMessage)
                    context.close(promise: nil)
                    self.client.logger.error("Unexpected MQTT Message", metadata: ["mqtt_message": .string("\(message)")])
                    return
                }
                self.client.logger.trace("MQTT In", metadata: ["mqtt_message": .stringConvertible(message), "mqtt_packet_id": .stringConvertible(message.packetId)])
            }
        } catch {
            context.fireErrorCaught(error)
            context.close(promise: nil)
            self.client.logger.error("Error processing MQTT message", metadata: ["mqtt_error": .string("\(error)")])
        }
    }

    func updatePingreqTimeout(_ timeout: TimeAmount) {
        self.pingreqHandler?.updateTimeout(timeout)
    }

    /// Respond to PUBLISH message
    /// If QoS is `.atMostOnce` then no response is required
    /// If QoS is `.atLeastOnce` then send PUBACK
    /// If QoS is `.exactlyOnce` then send PUBREC, wait for PUBREL and then respond with PUBCOMP (in `respondToPubrel`)
    private func respondToPublish(_ message: MQTTPublishPacket) {
        guard let connection = client.connection else { return }
        switch message.publish.qos {
        case .atMostOnce:
            self.client.publishListeners.notify(.success(message.publish))

        case .atLeastOnce:
            connection.sendMessageNoWait(MQTTPubAckPacket(type: .PUBACK, packetId: message.packetId))
                .map { _ in return message.publish }
                .whenComplete { self.client.publishListeners.notify($0) }

        case .exactlyOnce:
            var publish = message.publish
            connection.sendMessage(MQTTPubAckPacket(type: .PUBREC, packetId: message.packetId)) { newMessage in
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
            .map { _ in return publish }
            .whenComplete { result in
                // do not report retrySend error
                if case .failure(let error) = result, case MQTTError.retrySend = error {
                    return
                }
                self.client.publishListeners.notify(result)
            }
        }
    }

    /// Respond to PUBREL message by sending PUBCOMP. Do this separate from `responeToPublish` as the broker might send
    /// multiple PUBREL messages, if the client is slow to respond
    private func respondToPubrel(_ message: MQTTPacket) {
        guard let connection = client.connection else { return }
        _ = connection.sendMessageNoWait(MQTTPubAckPacket(type: .PUBCOMP, packetId: message.packetId))
    }
}
