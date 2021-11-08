import Logging
import NIO

class MQTTChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = MQTTPacket
    typealias OutboundIn = MQTTPacket
    typealias OutboundOut = MQTTPacket

    let client: MQTTClient
    var decoder: NIOSingleStepByteToMessageProcessor<ByteToMQTTMessageDecoder>

    init(_ client: MQTTClient) {
        self.client = client
        self.decoder = .init(.init(client: client))
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)

        do {
            try self.decoder.process(buffer: buffer) { message in
                switch message.type {
                case .PUBLISH:
                    let publishMessage = message as! MQTTPublishPacket
                    self.client.logger.trace("MQTT In", metadata: [
                        "mqtt_message": .string("\(publishMessage)"),
                        "mqtt_packet_id": .string("\(publishMessage.packetId)"),
                        "mqtt_topicName": .string("\(publishMessage.publish.topicName)"),
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
                    context.fireErrorCaught(MQTTError.decodeError)
                }
                self.client.logger.trace("MQTT In", metadata: ["mqtt_message": .string("\(message)"), "mqtt_packet_id": .string("\(message.packetId)")])
            }
        } catch {
            print("\(error)")
        }
    }

    /// Respond to PUBLISH message
    func respondToPublish(_ message: MQTTPublishPacket) {
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
    func respondToPubrel(_ message: MQTTPacket) {
        guard let connection = client.connection else { return }
        _ = connection.sendMessageNoWait(MQTTPubAckPacket(type: .PUBCOMP, packetId: message.packetId))
    }
}
