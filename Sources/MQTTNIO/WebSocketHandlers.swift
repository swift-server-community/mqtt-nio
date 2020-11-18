import NIO
import NIOWebSocket

final class WebSocketHandler: ChannelDuplexHandler {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = WebSocketFrame
    typealias InboundIn = WebSocketFrame
    typealias InboundOut = ByteBuffer

    let testFrameData: String = "Hello World"
    var webSocketFrameSequence: WebSocketFrameSequence?

    // This is being hit, channel active won't be called as it is already added.
    public func handlerAdded(context: ChannelHandlerContext) {
        print("WebSocket handler added.")
        self.pingTestFrameData(context: context)
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        print("WebSocket handler removed.")
    }

    func channelActive(context: ChannelHandlerContext) {
        pingTestFrameData(context: context)
        context.fireChannelActive()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard context.channel.isActive else { return }

        var buffer = unwrapOutboundIn(data)
        let maskKey = WebSocketMaskingKey((0..<4).map { _ in UInt8.random(in: 1 ..< 255) })
        /*if let maskKey = maskKey {
            buffer.webSocketMask(maskKey)
        }*/
        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: maskKey, data: buffer)
        context.writeAndFlush(wrapOutboundOut(frame), promise: promise)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        print(frame)
        switch frame.opcode {
        case .pong:
            self.pong(context: context, frame: frame)
        case .ping:
            self.ping(context: context, frame: frame)
        case .text:
            if var frameSeq = self.webSocketFrameSequence {
                frameSeq.append(frame)
                self.webSocketFrameSequence = frameSeq
            } else {
                var frameSeq = WebSocketFrameSequence(type: .text)
                frameSeq.append(frame)
                self.webSocketFrameSequence = frameSeq
            }
        case .binary:
            if var frameSeq = self.webSocketFrameSequence {
                frameSeq.append(frame)
                self.webSocketFrameSequence = frameSeq
            } else {
                var frameSeq = WebSocketFrameSequence(type: .binary)
                frameSeq.append(frame)
                self.webSocketFrameSequence = frameSeq
            }
        case .continuation:
            if var frameSeq = self.webSocketFrameSequence {
                frameSeq.append(frame)
                self.webSocketFrameSequence = frameSeq
            } else {
                self.close(context: context, code: .protocolError, promise: nil)
            }
        case .connectionClose:
            self.receivedClose(context: context, frame: frame)

        default:
            break
        }

        if let frameSeq = self.webSocketFrameSequence, frame.fin {
            switch frameSeq.type {
            case .binary, .text:
                context.fireChannelRead(wrapInboundOut(frameSeq.buffer))
            default: break
            }
            self.webSocketFrameSequence = nil
        }
    }

    private func receivedClose(context: ChannelHandlerContext, frame: WebSocketFrame) {
        // Handle a received close frame. We're just going to close.
        print("Received Close instruction from server")
        context.close(promise: nil)
    }

    private func pingTestFrameData(context: ChannelHandlerContext) {
        /*_ = context.eventLoop.scheduleTask(in: .seconds(5)) {
            let buffer = context.channel.allocator.buffer(string: self.testFrameData)
            self.send(context: context, buffer: buffer, opcode: .ping)
        }*/
    }

    private func send(
        context: ChannelHandlerContext,
        buffer: ByteBuffer,
        opcode: WebSocketOpcode,
        fin: Bool = true,
        promise: EventLoopPromise<Void>? = nil
    ) {
        let maskKey = makeMaskKey()
        let frame = WebSocketFrame(fin: true, opcode: .text, maskKey: maskKey, data: buffer)
        context.writeAndFlush(wrapOutboundOut(frame), promise: promise)
    }

    private func pong(context: ChannelHandlerContext, frame: WebSocketFrame) {
        var frameData = frame.unmaskedData
        if let frameDataString = frameData.readString(length: self.testFrameData.count) {
            print("Pong: Received: \(frameDataString)")
        }
    }

    private func ping(context: ChannelHandlerContext, frame: WebSocketFrame) {
        print("Ping")
        if frame.fin {
            self.send(context: context, buffer: frame.unmaskedData, opcode: .pong, fin: true, promise: nil)
        } else {
            self.close(context: context, code: .protocolError, promise: nil)
        }
    }

    func makeMaskKey() -> WebSocketMaskingKey? {
        let bytes: [UInt8] = (0...3).map { _ in UInt8.random(in: 1...255) }
        return WebSocketMaskingKey(bytes)
    }

    public func close(context: ChannelHandlerContext, code: WebSocketErrorCode = .goingAway, promise: EventLoopPromise<Void>?) {
        let codeAsInt = UInt16(webSocketErrorCode: code)
        let codeToSend: WebSocketErrorCode
        if codeAsInt == 1005 || codeAsInt == 1006 {
            /// Code 1005 and 1006 are used to report errors to the application, but must never be sent over
            /// the wire (per https://tools.ietf.org/html/rfc6455#section-7.4)
            codeToSend = .normalClosure
        } else {
            codeToSend = code
        }

        var buffer = context.channel.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: codeToSend)
        self.send(context: context, buffer: buffer, opcode: .connectionClose, fin: true, promise: promise)
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

    func channelInactive(context: ChannelHandlerContext) {

        // We always forward the error on to let others see it.
        context.fireChannelInactive()
    }
}

struct WebSocketFrameSequence {
    var buffer: ByteBuffer
    var type: WebSocketOpcode

    init(type: WebSocketOpcode) {
        self.buffer = ByteBufferAllocator().buffer(capacity: 0)
        self.type = type
    }

    mutating func append(_ frame: WebSocketFrame) {
        var data = frame.unmaskedData
        switch type {
        case .binary, .text:
            self.buffer.writeBuffer(&data)
        default: break
        }
    }
}
