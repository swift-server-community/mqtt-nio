
import NIO

class MQTTTask {
    let eventLoop: EventLoop
    let promise: EventLoopPromise<MQTTInboundMessage>
    let checkInbound: (MQTTInboundMessage) throws -> Bool
    
    init(on eventLoop: EventLoop, checkInbound: @escaping (MQTTInboundMessage) throws -> Bool) {
        self.eventLoop = eventLoop
        self.checkInbound = checkInbound
        self.promise = self.eventLoop.makePromise(of: MQTTInboundMessage.self)
    }
    
    func succeed(_ response: MQTTInboundMessage) {
        promise.succeed(response)
    }
    
    func fail(_ error: Error) {
        promise.fail(error)
    }
}

class MQTTTaskHandler: ChannelInboundHandler, RemovableChannelHandler {
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
