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
        logger.debug("MQTT Out", metadata: ["mqtt_message": .string("\(message)")])
        var bb = context.channel.allocator.buffer(capacity: 0)
        try! message.serialize(to: &bb)
        context.write(wrapOutboundOut(bb), promise: promise)
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
        do {
            let packet = try MQTTSerializer.readIncomingPacket(from: &buffer)
            let message: MQTTInboundMessage
            switch packet.type {
            case .PUBLISH:
                do {
                    let publish = try MQTTSerializer.readPublish(from: packet)
                    let publishMessage = MQTTPublishMessage(publish: publish.publishInfo, packetId: publish.packetId)
                    client.logger.debug("MQTT In", metadata: ["mqtt_message": .string("\(publishMessage)")])
                    self.publish(publishMessage)
                } catch MQTTSerializer.Error.incompletePacket {
                    return .needMoreData
                } catch {
                    self.client.publishListeners.notify(.failure(error))
                }
                return .continue
            case .CONNACK:
                let connack = try MQTTSerializer.readAck(from: packet)
                message = MQTTConnAckMessage(packetId: connack.packetId, sessionPresent: connack.sessionPresent)
            case .PUBACK, .PUBREC, .PUBREL, .PUBCOMP, .SUBACK, .UNSUBACK:
                let ack = try MQTTSerializer.readAck(from: packet)
                message = MQTTAckMessage(type: packet.type, packetId: ack.packetId)
            case .PINGRESP:
                message = MQTTPingrespMessage()
            default:
                throw MQTTClient.Error.decodeError
            }
            client.logger.debug("MQTT In", metadata: ["mqtt_message": .string("\(message)")])
            context.fireChannelRead(wrapInboundOut(message))
        } catch MQTTSerializer.Error.incompletePacket {
            return .needMoreData
        } catch {
            context.fireErrorCaught(error)
        }
        return .continue
    }
    
    func publish(_ message: MQTTPublishMessage) {
        switch message.publish.qos {
        case .atMostOnce:
            client.publishListeners.notify(.success(message.publish))
        case .atLeastOnce:
            client.connection!.sendMessageNoWait(MQTTAckMessage(type: .PUBACK, packetId: message.packetId))
                .map { _ in return message.publish }
                .whenComplete { self.client.publishListeners.notify($0) }
        case .exactlyOnce:
            client.connection!.sendMessage(MQTTAckMessage(type: .PUBREC, packetId: message.packetId)) { newMessage in
                guard newMessage.packetId == message.packetId else { return false }
                guard newMessage.type == .PUBREL else { throw MQTTClient.Error.unexpectedMessage }
                return true
            }
            .flatMap { _ in
                self.client.connection!.sendMessageNoWait(MQTTAckMessage(type: .PUBCOMP, packetId: message.packetId))
            }
            .map { _ in return message.publish }
            .whenComplete { self.client.publishListeners.notify($0) }
        }

    }
}

