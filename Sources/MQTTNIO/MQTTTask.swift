
import NIO

final class MQTTTask {
    let promise: EventLoopPromise<MQTTInboundMessage>
    let checkInbound: (MQTTInboundMessage) throws -> Bool
    let timeoutTask: Scheduled<Void>?
    
    init(on eventLoop: EventLoop, timeout: TimeAmount?, checkInbound: @escaping (MQTTInboundMessage) throws -> Bool) {
        self.checkInbound = checkInbound
        let promise = eventLoop.makePromise(of: MQTTInboundMessage.self)
        self.promise = promise
        if let timeout = timeout {
            self.timeoutTask = eventLoop.scheduleTask(in: timeout) {
                promise.fail(MQTTClient.Error.timeout)
            }
        } else {
            self.timeoutTask = nil
        }
    }
    
    func succeed(_ response: MQTTInboundMessage) {
        timeoutTask?.cancel()
        promise.succeed(response)
    }
    
    func fail(_ error: Error) {
        timeoutTask?.cancel()
        promise.fail(error)
    }
}

final class MQTTTaskHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = MQTTInboundMessage
    
    let task: MQTTTask
    let channel: Channel

    init(task: MQTTTask, channel: Channel) {
        self.task = task
        self.channel = channel
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        do {
            if try task.checkInbound(response) {
                self.channel.pipeline.removeHandler(self).whenSuccess { _ in
                    self.task.succeed(response)
                }
            }
        } catch {
            self.errorCaught(context: context, error: error)
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        channel.pipeline.removeHandler(self).whenSuccess { _ in
            self.task.fail(error)
        }
    }
}
