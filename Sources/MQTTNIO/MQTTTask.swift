
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
        promise.succeed(response)
    }
    
    func fail(_ error: Error) {
        promise.fail(error)
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
        addTimeoutTask()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        do {
            if try task.checkInbound(response) {
                self.channel.pipeline.removeHandler(self).whenSuccess { _ in
                    self.timeoutTask?.cancel()
                    self.task.succeed(response)
                }
            }
        } catch {
            self.errorCaught(context: context, error: error)
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.timeoutTask?.cancel()
        channel.pipeline.removeHandler(self).whenSuccess { _ in
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
