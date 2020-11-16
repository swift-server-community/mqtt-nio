import NIO

class MQTTEncodeHandler: ChannelOutboundHandler {
    public typealias OutboundIn = MQTTOutboundMessage
    public typealias OutboundOut = ByteBuffer

    let client: MQTTClient

    init(client: MQTTClient) {
        self.client = client
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let message = unwrapOutboundIn(data)
        print("\(client.clientIdentifier) Out: \(message)")
        var bb = ByteBufferAllocator().buffer(capacity: 0)
        try! message.serialize(to: &bb)
        context.write(wrapOutboundOut(bb), promise: promise)
    }
}

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
                let publish = try MQTTSerializer.readPublish(from: packet)
                let publishMessage = MQTTPublishMessage(publish: publish.publishInfo, packetId: publish.packetId)
                print("\(client.clientIdentifier) In: \(publishMessage)")
                self.publish(publishMessage)
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
            print("\(client.clientIdentifier) In: \(message)")
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
            client.publishCallback(message.publish)
        case .atLeastOnce:
            client.sendMessageNoWait(MQTTAckMessage(type: .PUBACK, packetId: message.packetId))
                .whenSuccess { self.client.publishCallback(message.publish)}
        case .exactlyOnce:
            client.sendMessage(MQTTAckMessage(type: .PUBREC, packetId: message.packetId)) { newMessage in
                guard newMessage.packetId == message.packetId else { return false }
                guard newMessage.type == .PUBREL else { throw MQTTClient.Error.unexpectedMessage }
                return true
            }.flatMap { _ in
                self.client.sendMessageNoWait(MQTTAckMessage(type: .PUBCOMP, packetId: message.packetId))
            }
            .whenSuccess { self.client.publishCallback(message.publish)}
        }

    }
}

