
import NIO

/// Class encapsulating a single task
final class MQTTTask {
    let promise: EventLoopPromise<MQTTPacket>
    let checkInbound: (MQTTPacket) throws -> Bool
    let timeout: TimeAmount?
    let timeoutTask: Scheduled<Void>?

    init(on eventLoop: EventLoop, timeout: TimeAmount?, checkInbound: @escaping (MQTTPacket) throws -> Bool) {
        let promise = eventLoop.makePromise(of: MQTTPacket.self)
        self.promise = promise
        self.checkInbound = checkInbound
        self.timeout = timeout
        if let timeout = timeout {
            self.timeoutTask = eventLoop.scheduleTask(in: timeout) {
                promise.fail(MQTTError.timeout)
            }
        } else {
            self.timeoutTask = nil
        }
    }

    func succeed(_ response: MQTTPacket) {
        self.timeoutTask?.cancel()
        self.promise.succeed(response)
    }

    func fail(_ error: Error) {
        self.timeoutTask?.cancel()
        self.promise.fail(error)
    }
}

final class MQTTTaskHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = MQTTPacket

    let task: MQTTTask
    let channel: Channel

    init(task: MQTTTask, channel: Channel) {
        self.task = task
        self.channel = channel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        do {
            if try self.task.checkInbound(response) {
                self.channel.pipeline.removeHandler(self).whenSuccess { _ in
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
        self.channel.pipeline.removeHandler(self).whenSuccess { _ in
            self.task.fail(error)
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
