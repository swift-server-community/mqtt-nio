import NIO

class EchoClientHandler: ChannelDuplexHandler {
    public typealias OutboundIn = String
    public typealias OutboundOut = ByteBuffer
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = String
    private var numBytes = 0
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let request = unwrapOutboundIn(data)
        let bb = ByteBufferAllocator().buffer(string: request)
        numBytes = bb.readableBytes
        context.write(wrapOutboundOut(bb), promise: promise)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let byteBuffer = self.unwrapInboundIn(data)
        self.numBytes -= byteBuffer.readableBytes

        if self.numBytes == 0 {
            let string = String(buffer: byteBuffer)
            print("Received: '\(string)' back from the server, closing channel.")
            context.fireChannelRead(wrapInboundOut(string))
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("error: ", error)
        context.close(promise: nil)
    }
}

class EchoClient {
    let eventLoopGroup: EventLoopGroup

    init() throws {
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }
    
    func post(_ string: String) -> Task<String> {
        let task = Task<String>(on: eventLoopGroup.next())
        let taskHandler = TaskHandler(task: task)
        
        ClientBootstrap(group: eventLoopGroup)
            // Enable SO_REUSEADDR.
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([EchoClientHandler(), taskHandler])
            }
            .connect(host: "localhost", port: 8001)
            .flatMap { channel in
                channel.writeAndFlush(string)
            }.whenFailure { error in
                task.fail(error)
            }
        return task
    }

    func syncShutdownGracefully() throws {
        try eventLoopGroup.syncShutdownGracefully()
    }
}
