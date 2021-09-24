
import NIO

final class MQTTTask {
    let promise: EventLoopPromise<MQTTPacket>
    let checkInbound: (MQTTPacket) throws -> Bool
    let timeout: TimeAmount?

    init(on eventLoop: EventLoop, timeout: TimeAmount?, checkInbound: @escaping (MQTTPacket) throws -> Bool) {
        self.promise = eventLoop.makePromise(of: MQTTPacket.self)
        self.checkInbound = checkInbound
        self.timeout = timeout
    }

    func succeed(_ response: MQTTPacket) {
        self.promise.succeed(response)
    }

    func fail(_ error: Error) {
        self.promise.fail(error)
    }
}

final class MQTTTaskHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = MQTTPacket

    let task: MQTTTask
    let channel: Channel
    var timeoutTask: Scheduled<Void>?

    init(task: MQTTTask, channel: Channel) {
        self.task = task
        self.channel = channel
        self.timeoutTask = nil
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        self.addTimeoutTask()
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.timeoutTask?.cancel()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        do {
            if try self.task.checkInbound(response) {
                self.channel.pipeline.removeHandler(self).whenSuccess { _ in
                    self.timeoutTask?.cancel()
                    self.task.succeed(response)
                }
            } else {
                context.fireChannelRead(data)
            }
        } catch {
            self.errorCaught(context: context, error: error)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.task.fail(MQTTError.serverClosedConnection)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.timeoutTask?.cancel()
        self.channel.pipeline.removeHandler(self).whenSuccess { _ in
            self.task.fail(error)
        }
    }

    func addTimeoutTask() {
        if let timeout = task.timeout {
            self.timeoutTask = self.channel.eventLoop.scheduleTask(in: timeout) {
                self.channel.pipeline.removeHandler(self).whenSuccess { _ in
                    self.task.fail(MQTTError.timeout)
                }
            }
        } else {
            self.timeoutTask = nil
        }
    }
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
