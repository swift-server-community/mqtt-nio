import NIO

class MQTTClientHandler: ChannelDuplexHandler {
    public typealias OutboundIn = MQTTOutboundMessage
    public typealias OutboundOut = ByteBuffer
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = MQTTInboundMessage

    enum State {
        case setup
        case reading(ByteBuffer)
        case end(MQTTInboundMessage)
        case error(Error)
    }

    var state: State = .setup

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let message = unwrapOutboundIn(data)
        print("Out: \(message)")
        var bb = ByteBufferAllocator().buffer(capacity: 0)
        try! message.serialize(to: &bb)
        context.write(wrapOutboundOut(bb), promise: promise)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var byteBuffer = self.unwrapInboundIn(data)
        switch state {
        case .setup:
            state = try! readBuffer(byteBuffer)
            if case .end(let message) = state {
                context.fireChannelRead(wrapInboundOut(message))
                print("In: \(message)")
            }
        case .reading(var alreadyRead):
            alreadyRead.writeBuffer(&byteBuffer)
            state = try! readBuffer(alreadyRead)
            if case .end(let message) = state {
                context.fireChannelRead(wrapInboundOut(message))
                print("In: \(message)")
            }
            break

        case .end:
            fatalError("Shouldnt get here we have stopped receiving messages")
            break

        case .error:
            break
        }
    }

    func readBuffer(_ byteBuffer: ByteBuffer) throws -> State {
        var byteBuffer2 = byteBuffer
        do {
            let packet = try MQTTSerializer.readIncomingPacket(from: &byteBuffer2)
            switch packet.type {
            case .PUBLISH:
                let publish = try MQTTSerializer.readPublish(from: packet)
                return .end(MQTTPublishMessage(publish: publish.publishInfo, packetId: publish.packetId))
            case .CONNACK:
                let connack = try MQTTSerializer.readAck(from: packet)
                return .end(MQTTConnAckMessage(packetId: connack.packetId, sessionPresent: connack.sessionPresent))
            case .PUBACK, .PUBREC, .PUBREL, .PUBCOMP, .SUBACK, .UNSUBACK:
                let ack = try MQTTSerializer.readAck(from: packet)
                return .end(MQTTAckMessage(type: packet.type, packetId: ack.packetId))
            default:
                fatalError()
            }
        } catch MQTTSerializer.Error.incompletePacket {
            return .reading(byteBuffer)
        } catch {
            return .error(error)
        }

    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("error: ", error)
        context.close(promise: nil)
    }
}
