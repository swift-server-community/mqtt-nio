
import NIO

final class MQTTTask {
    let promise: EventLoopPromise<MQTTInboundMessage>
    let checkInbound: (MQTTInboundMessage) throws -> Bool
    let timeout: TimeAmount?

    init(on eventLoop: EventLoop, timeout: TimeAmount?, checkInbound: @escaping (MQTTInboundMessage) throws -> Bool) {
        self.promise = eventLoop.makePromise(of: MQTTInboundMessage.self)
        self.checkInbound = checkInbound
        self.timeout = timeout
    }

    func succeed(_ response: MQTTInboundMessage) {
        self.promise.succeed(response)
    }

    func fail(_ error: Error) {
        self.promise.fail(error)
    }
}

final class MQTTTaskHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = MQTTInboundMessage

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
            }
        } catch {
            self.errorCaught(context: context, error: error)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.task.fail(MQTTClient.Error.serverClosedConnection)
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
                    self.task.fail(MQTTClient.Error.timeout)
                }
            }
        } else {
            self.timeoutTask = nil
        }
    }
}
