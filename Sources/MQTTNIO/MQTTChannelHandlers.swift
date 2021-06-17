import Logging
import NIO

/// Handler encoding MQTT Messages into ByteBuffers
final class MQTTEncodeHandler: ChannelOutboundHandler {
    public typealias OutboundIn = MQTTOutboundMessage
    public typealias OutboundOut = ByteBuffer

    let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let message = unwrapOutboundIn(data)
        if let messageWithPacketId = message as? MQTTOutboundWithPacketIdMessage {
            logger.debug("MQTT Out", metadata: ["mqtt_message": .string("\(message)"), "mqtt_packet_id": .string("\(messageWithPacketId.packetId)")])
        } else {
            logger.debug("MQTT Out", metadata: ["mqtt_message": .string("\(message)")])
        }
        var bb = context.channel.allocator.buffer(capacity: 0)
        do {
            try message.serialize(to: &bb)
            context.write(wrapOutboundOut(bb), promise: promise)
        } catch {
            promise?.fail(error)
        }
    }
}

/// Decode ByteBuffers into MQTT Messages
struct ByteToMQTTMessageDecoder: ByteToMessageDecoder {
    typealias InboundOut = MQTTInboundMessage
    
    let client: MQTTClient
    
    init(client: MQTTClient) {
        self.client = client
    }

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        var readBuffer = buffer
        do {
            let packet = try MQTTSerializer.readIncomingPacket(from: &readBuffer)
            let message: MQTTInboundMessage
            switch packet.type {
            case .PUBLISH:
                do {
                    let publish = try MQTTSerializer.readPublish(from: packet)
                    let publishMessage = MQTTPublishMessage(publish: publish.publishInfo, packetId: publish.packetId)
                    client.logger.debug("MQTT In", metadata: [
                        "mqtt_message": .string("\(publishMessage)"),
                        "mqtt_packet_id": .string("\(publishMessage.packetId)"),
                        "mqtt_topicName": .string("\(publishMessage.publish.topicName)")
                    ])
                    self.respondToPublish(publishMessage)
                } catch MQTTSerializer.InternalError.incompletePacket {
                    return .needMoreData
                } catch {
                    self.client.publishListeners.notify(.failure(error))
                }
                buffer = readBuffer
                return .continue
            case .CONNACK:
                let connack = try MQTTSerializer.readConnack(from: packet)
                message = MQTTConnAckMessage(returnCode: connack.returnCode, sessionPresent: connack.sessionPresent)
            case .PUBACK, .PUBREC, .PUBREL, .PUBCOMP, .SUBACK, .UNSUBACK:
                let packetId = try MQTTSerializer.readAck(from: packet)
                message = MQTTAckMessage(type: packet.type, packetId: packetId)
            case .PINGRESP:
                message = MQTTPingrespMessage()
            default:
                throw MQTTClient.Error.decodeError
            }
            client.logger.debug("MQTT In", metadata: ["mqtt_message": .string("\(message)"), "mqtt_packet_id": .string("\(message.packetId)")])
            if message.type == .PUBREL {
                respondToPubrel(message)
            }
            context.fireChannelRead(wrapInboundOut(message))
        } catch MQTTSerializer.InternalError.incompletePacket {
            return .needMoreData
        } catch {
            context.fireErrorCaught(error)
        }
        buffer = readBuffer
        return .continue
    }

    /// Respond to PUBLISH message
    func respondToPublish(_ message: MQTTPublishMessage) {
        guard let connection = client.connection else { return }
        switch message.publish.qos {
        case .atMostOnce:
            client.publishListeners.notify(.success(message.publish))

        case .atLeastOnce:
            connection.sendMessageNoWait(MQTTAckMessage(type: .PUBACK, packetId: message.packetId))
                .map { _ in return message.publish }
                .whenComplete { self.client.publishListeners.notify($0) }

        case .exactlyOnce:
            var publish = message.publish
            connection.sendMessageWithRetry(MQTTAckMessage(type: .PUBREC, packetId: message.packetId), maxRetryAttempts: client.configuration.maxRetryAttempts) { newMessage in
                guard newMessage.packetId == message.packetId else { return false }
                // if we receive a publish message while waiting for a PUBREL from broker then replace data to be published and retry PUBREC
                if newMessage.type == .PUBLISH, let publishMessage = newMessage as? MQTTPublishMessage {
                    publish = publishMessage.publish
                    throw MQTTClient.Error.retrySend
                }
                // if we receive anything but a PUBREL then throw unexpected message
                guard newMessage.type == .PUBREL else { throw MQTTClient.Error.unexpectedMessage }
                // now we have received the PUBREL we can process the published message. PUBCOMP is sent by `respondToPubrel`
                return true
            }
            .map { _ in return publish }
            .whenComplete { result in
                // do not report retrySend error
                if case .failure(let error) = result, case MQTTClient.Error.retrySend = error {
                    return
                }
                self.client.publishListeners.notify(result)
            }
        }
    }

    /// Respond to PUBREL message by sending PUBCOMP. Do this separate from `responeToPublish` as the broker might send
    /// multiple PUBREL messages, if the client is slow to respond
    func respondToPubrel(_ message: MQTTInboundMessage) {
        guard let connection = client.connection else { return }
        _ = connection.sendMessageNoWait(MQTTAckMessage(type: .PUBCOMP, packetId: message.packetId))
    }
}

