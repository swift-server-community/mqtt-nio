
import NIO

class Task<Response> {
    let eventLoop: EventLoop
    let promise: EventLoopPromise<Response>
    
    init(on eventLoop: EventLoop) {
        self.eventLoop = eventLoop
        self.promise = self.eventLoop.makePromise(of: Response.self)
    }
    
    func succeed(_ response: Response) {
        promise.succeed(response)
    }
    
    func fail(_ error: Error) {
        promise.fail(error)
    }
}

class TaskHandler<Response>: ChannelInboundHandler {
    typealias InboundIn = Response
    
    let task: Task<Response>
    
    init(task: Task<Response>) {
        self.task = task
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        task.succeed(response)
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        task.fail(error)
    }
}
