import NIO
import NIOHTTP1
import NIOWebSocket

// The HTTP handler to be used to initiate the request.
// This initial request will be adapted by the WebSocket upgrader to contain the upgrade header parameters.
// Channel read will only be called if the upgrade fails.

final class HTTPInitialRequestHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPClientResponsePart
    public typealias OutboundOut = HTTPClientRequestPart

    let host: String

    init(host: String) {
        self.host = host
    }
    
    public func channelActive(context: ChannelHandlerContext) {
        print("Client connected to \(context.remoteAddress!)")

        // We are connected. It's time to send the message to the server to initialize the upgrade dance.
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(0)")
        headers.add(name: "host", value: host)

        let requestHead = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1),
                                          method: .GET,
                                          uri: "/",
                                          headers: headers)

        context.write(self.wrapOutboundOut(.head(requestHead)), promise: nil)

        let body = HTTPClientRequestPart.body(.byteBuffer(ByteBuffer()))
        context.write(self.wrapOutboundOut(body), promise: nil)

        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {

        let clientResponse = self.unwrapInboundIn(data)

        print("Upgrade failed")

        switch clientResponse {
        case .head(let responseHead):
            print("Received status: \(responseHead.status)")
        case .body(let byteBuffer):
            let string = String(buffer: byteBuffer)
            print("Received: '\(string)' back from the server.")
        case .end:
            print("Closing channel.")
            context.close(promise: nil)
        }
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        print("HTTP handler removed.")
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("error: ", error)

        // As we are not really interested getting notified on success or failure
        // we just pass nil as promise to reduce allocations.
        context.close(promise: nil)
    }
}

// The web socket handler to be used once the upgrade has occurred.
// One added, it sends a ping-pong round trip with "Hello World" data.
// It also listens for any text frames from the server and prints them.

final class WebSocketPingPongHandler: ChannelDuplexHandler {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = WebSocketFrame
    typealias InboundIn = WebSocketFrame
    typealias InboundOut = ByteBuffer

    let testFrameData: String = "Hello World"

    // This is being hit, channel active won't be called as it is already added.
    public func handlerAdded(context: ChannelHandlerContext) {
        print("WebSocket handler added.")
        self.pingTestFrameData(context: context)
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        print("WebSocket handler removed.")
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
        context.write(wrapOutboundOut(frame), promise: nil)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        switch frame.opcode {
        case .pong:
            self.pong(context: context, frame: frame)
        case .text:
            var data = frame.unmaskedData
            let text = data.readString(length: data.readableBytes) ?? ""
            print("Websocket: Received \(text)")
        case .connectionClose:
            self.receivedClose(context: context, frame: frame)
        case .binary, .continuation, .ping:
            context.fireChannelRead(wrapInboundOut(frame.unmaskedData))
        default:
            // Unknown frames are errors.
            self.closeOnError(context: context)
        }
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    private func receivedClose(context: ChannelHandlerContext, frame: WebSocketFrame) {
        // Handle a received close frame. We're just going to close.
        print("Received Close instruction from server")
        context.close(promise: nil)
    }

    private func pingTestFrameData(context: ChannelHandlerContext) {
        let buffer = context.channel.allocator.buffer(string: self.testFrameData)
        let frame = WebSocketFrame(fin: true, opcode: .ping, data: buffer)
        context.write(self.wrapOutboundOut(frame), promise: nil)
    }

    private func pong(context: ChannelHandlerContext, frame: WebSocketFrame) {
        var frameData = frame.data
        if let frameDataString = frameData.readString(length: self.testFrameData.count) {
            print("Websocket: Received: \(frameDataString)")
        }
    }

    private func closeOnError(context: ChannelHandlerContext) {
        // We have hit an error, we want to close. We do that by sending a close frame and then
        // shutting down the write side of the connection. The server will respond with a close of its own.
        var data = context.channel.allocator.buffer(capacity: 2)
        data.write(webSocketErrorCode: .protocolError)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
        context.write(self.wrapOutboundOut(frame)).whenComplete { (_: Result<Void, Error>) in
            context.close(mode: .output, promise: nil)
        }
    }
}

