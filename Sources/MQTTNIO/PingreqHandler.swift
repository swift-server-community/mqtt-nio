import NIO

/// Channel handler for sending PINGREQ messages to keep connect alive
final class PingreqHandler: ChannelDuplexHandler {
    typealias OutboundIn = MQTTPacket
    typealias OutboundOut = MQTTPacket
    typealias InboundIn = MQTTPacket
    typealias InboundOut = MQTTPacket

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
            self.scheduleTask(context)
        }
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.cancelTask()
    }

    public func channelActive(context: ChannelHandlerContext) {
        if self.task == nil {
            self.scheduleTask(context)
        }
        context.fireChannelActive()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.lastEventTime = .now()
        context.write(data, promise: promise)
    }

    func scheduleTask(_ context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }

        self.task = context.eventLoop.scheduleTask(deadline: self.lastEventTime + self.timeout) {
            // if lastEventTime plus the timeout is less than now send PINGREQ
            // otherwise reschedule task
            if self.lastEventTime + self.timeout <= .now() {
                guard context.channel.isActive else { return }

                self.client.ping().whenComplete { result in
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
