import NIO

class MQTTEncodeHandler: ChannelOutboundHandler {
    public typealias OutboundIn = MQTTOutboundMessage
    public typealias OutboundOut = ByteBuffer

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let message = unwrapOutboundIn(data)
        print("Out: \(message)")
        var bb = ByteBufferAllocator().buffer(capacity: 0)
        try! message.serialize(to: &bb)
        context.write(wrapOutboundOut(bb), promise: promise)
    }
}

struct ByteToMQTTMessageDecoder: ByteToMessageDecoder {
    typealias InboundOut = MQTTInboundMessage
    
    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        do {
            let packet = try MQTTSerializer.readIncomingPacket(from: &buffer)
            let message: MQTTInboundMessage
            switch packet.type {
            case .PUBLISH:
                let publish = try MQTTSerializer.readPublish(from: packet)
                message = MQTTPublishMessage(publish: publish.publishInfo, packetId: publish.packetId)
            case .CONNACK:
                let connack = try MQTTSerializer.readAck(from: packet)
                message = MQTTConnAckMessage(packetId: connack.packetId, sessionPresent: connack.sessionPresent)
            case .PUBACK, .PUBREC, .PUBREL, .PUBCOMP, .SUBACK, .UNSUBACK:
                let ack = try MQTTSerializer.readAck(from: packet)
                message = MQTTAckMessage(type: packet.type, packetId: ack.packetId)
            default:
                fatalError()
            }
            print("In: \(message)")
            context.fireChannelRead(wrapInboundOut(message))
        } catch MQTTSerializer.Error.incompletePacket {
            return .needMoreData
        } catch {
            context.fireErrorCaught(error)
        }
        return .continue
    }
}
