import NIO

final class MQTTTaskHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = MQTTPacket

    var eventLoop: EventLoop!

    init() {
        self.eventLoop = nil
        self.tasks = []
    }

    func addTask(_ task: MQTTTask) -> EventLoopFuture<Void> {
        return self.eventLoop.submit {
            self.tasks.append(task)
        }
    }

    func removeTask(_ task: MQTTTask) {
        return self.eventLoop.execute {
            self.tasks.removeAll { $0 === task }
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.eventLoop = context.eventLoop
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        for task in self.tasks {
            do {
                if try task.checkInbound(response) {
                    task.succeed(response)
                    removeTask(task)
                    return
                }
            } catch {
                task.fail(error)
                removeTask(task)
                return
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        tasks.forEach { $0.fail(MQTTError.serverClosedConnection) }
        tasks.removeAll()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        tasks.forEach { $0.fail(error) }
        tasks.removeAll()
    }

    var tasks: [MQTTTask]
}

/// If packet reaches this handler then it was never dealt with by a task
final class MQTTUnhandledPacketHandler: ChannelInboundHandler {
    typealias InboundIn = MQTTPacket
    let client: MQTTClient

    init(client: MQTTClient) {
        self.client = client
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // we only send response to v5 server
        guard self.client.configuration.version == .v5_0 else { return }
        guard let connection = client.connection else { return }
        let response = self.unwrapInboundIn(data)
        switch response.type {
        case .PUBREC:
            _ = connection.sendMessageNoWait(MQTTPubAckPacket(type: .PUBREL, packetId: response.packetId, reason: .packetIdentifierNotFound))
        case .PUBREL:
            _ = connection.sendMessageNoWait(MQTTPubAckPacket(type: .PUBCOMP, packetId: response.packetId, reason: .packetIdentifierNotFound))
        default:
            break
        }
    }
}
