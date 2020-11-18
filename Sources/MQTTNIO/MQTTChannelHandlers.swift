import NIO

final class MQTTEncodeHandler: ChannelOutboundHandler {
    public typealias OutboundIn = MQTTOutboundMessage
    public typealias OutboundOut = ByteBuffer

    let client: MQTTClient

    init(client: MQTTClient) {
        self.client = client
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let message = unwrapOutboundIn(data)
        print("\(client.clientIdentifier) Out: \(message)")
        var bb = context.channel.allocator.buffer(capacity: 0)
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
            //print(buffer.readableBytesView.map {String(format: "0x%02x", $0)})
            let packet = try MQTTSerializer.readIncomingPacket(from: &buffer)
            let message: MQTTInboundMessage
            switch packet.type {
            case .PUBLISH:
                do {
                    let publish = try MQTTSerializer.readPublish(from: packet)
                    let publishMessage = MQTTPublishMessage(publish: publish.publishInfo, packetId: publish.packetId)
                    print("\(client.clientIdentifier) In: \(publishMessage)")
                    self.publish(publishMessage)
                } catch MQTTSerializer.Error.incompletePacket {
                    return .needMoreData
                } catch {
                    self.client.publishCallback(.failure(error))
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
            client.publishCallback(.success(message.publish))
        case .atLeastOnce:
            client.sendMessageNoWait(MQTTAckMessage(type: .PUBACK, packetId: message.packetId))
                .map { _ in return message.publish }
                .whenComplete { self.client.publishCallback($0) }
        case .exactlyOnce:
            client.sendMessage(MQTTAckMessage(type: .PUBREC, packetId: message.packetId)) { newMessage in
                guard newMessage.packetId == message.packetId else { return false }
                guard newMessage.type == .PUBREL else { throw MQTTClient.Error.unexpectedMessage }
                return true
            }
            .flatMap { _ in
                self.client.sendMessageNoWait(MQTTAckMessage(type: .PUBCOMP, packetId: message.packetId))
            }
            .map { _ in return message.publish }
            .whenComplete { self.client.publishCallback($0) }
        }

    }
}

/// Channel handler for sending PINGREQ messages to keep connect alive
final class PingreqHandler: ChannelDuplexHandler {
    typealias OutboundIn = MQTTOutboundMessage
    typealias OutboundOut = MQTTOutboundMessage
    typealias InboundIn = MQTTInboundMessage
    typealias InboundOut = MQTTInboundMessage

    let client: MQTTClient
    let timeout: TimeAmount
    var lastEventTime: NIODeadline
    var task: Scheduled<Void>?

    init(client: MQTTClient, timeout: TimeAmount) {
        self.client = client
        self.timeout = timeout
        self.lastEventTime = .now()
        self.task = nil
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            scheduleTask(context)
        }
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        cancelTask()
    }

    public func channelActive(context: ChannelHandlerContext) {
        if self.task == nil {
            scheduleTask(context)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.lastEventTime = .now()
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.lastEventTime = .now()
        context.write(data, promise: promise)
    }

    func scheduleTask(_ context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }

        self.task = context.eventLoop.scheduleTask(deadline: lastEventTime + timeout) {
            // if lastEventTime plus the timeout is less than now send PINGREQ
            // otherwise reschedule task
            if self.lastEventTime + self.timeout <= .now() {
                guard context.channel.isActive else { return }

                self.client.pingreq().whenComplete { result in
                    switch result {
                    case .failure(let error):
                        context.fireErrorCaught(error)
                    case .success:
                        break
                    }
                    self.lastEventTime = .now()
                    self.scheduleTask(context)
                }
            } else {
                self.scheduleTask(context)
            }
        }
    }

    func cancelTask() {
        self.task?.cancel()
        self.task = nil
    }
}
