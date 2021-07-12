import Logging
import NIO

/// Handler encoding MQTT Messages into ByteBuffers
final class MQTTEncodeHandler: ChannelOutboundHandler {
    public typealias OutboundIn = MQTTPacket
    public typealias OutboundOut = ByteBuffer

    let client: MQTTClient

    init(client: MQTTClient) {
        self.client = client
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
    }
}

/// Decode ByteBuffers into MQTT Messages
struct ByteToMQTTMessageDecoder: ByteToMessageDecoder {
    typealias InboundOut = MQTTPacket

    let client: MQTTClient

    init(client: MQTTClient) {
        self.client = client
    }

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        var readBuffer = buffer
        do {
            let packet = try MQTTIncomingPacket.read(from: &readBuffer)
            let message: MQTTPacket
            switch packet.type {
            case .PUBLISH:
                do {
                    let publishMessage = try MQTTPublishPacket.read(version: self.client.configuration.version, from: packet)
                    // let publish = try MQTTSerializer.readPublish(from: packet)
                    // let publishMessage = MQTTPublishPacket(publish: publish.publishInfo, packetId: publish.packetId)
                    self.client.logger.trace("MQTT In", metadata: [
                        "mqtt_message": .string("\(publishMessage)"),
                        "mqtt_packet_id": .string("\(publishMessage.packetId)"),
                        "mqtt_topicName": .string("\(publishMessage.publish.topicName)"),
                    ])
                    self.respondToPublish(publishMessage)
                } catch InternalError.incompletePacket {
                    return .needMoreData
                } catch {
                    self.client.publishListeners.notify(.failure(error))
                }
                buffer = readBuffer
                return .continue
            case .CONNACK:
                message = try MQTTConnAckPacket.read(version: self.client.configuration.version, from: packet)
            case .PUBACK, .PUBREC, .PUBREL, .PUBCOMP:
                message = try MQTTPubAckPacket.read(version: self.client.configuration.version, from: packet)
                if packet.type == .PUBREL {
                    self.respondToPubrel(message)
                }
            case .SUBACK, .UNSUBACK:
                message = try MQTTSubAckPacket.read(version: self.client.configuration.version, from: packet)
            case .PINGRESP:
                message = try MQTTPingrespPacket.read(version: self.client.configuration.version, from: packet)
            case .DISCONNECT:
                let disconnectMessage = try MQTTDisconnectPacket.read(version: self.client.configuration.version, from: packet)
                let ack = MQTTAckV5(reason: disconnectMessage.reason, properties: disconnectMessage.properties)
                context.fireErrorCaught(MQTTError.serverDisconnection(ack))
                return .continue
            case .AUTH:
                message = try MQTTAuthPacket.read(version: self.client.configuration.version, from: packet)
            default:
                throw MQTTError.decodeError
            }
            self.client.logger.trace("MQTT In", metadata: ["mqtt_message": .string("\(message)"), "mqtt_packet_id": .string("\(message.packetId)")])
            context.fireChannelRead(wrapInboundOut(message))
        } catch InternalError.incompletePacket {
            return .needMoreData
        } catch {
            context.fireErrorCaught(error)
        }
        buffer = readBuffer
        return .continue
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
