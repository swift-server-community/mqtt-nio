//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

import NIOCore
import NIOHTTP1

// The HTTP handler to be used to initiate the request.
// This initial request will be adapted by the WebSocket upgrader to contain the upgrade header parameters.
// Channel read will only be called if the upgrade fails.
final class WebSocketInitialRequestHandler: ChannelInboundHandler, RemovableChannelHandler, Sendable {
    public typealias InboundIn = HTTPClientResponsePart
    public typealias OutboundOut = HTTPClientRequestPart

    let host: String
    let urlPath: String
    let additionalHeaders: HTTPHeaders
    let upgradePromise: EventLoopPromise<Void>

    init(host: String, urlPath: String, additionalHeaders: HTTPHeaders, upgradePromise: EventLoopPromise<Void>) {
        self.host = host
        self.urlPath = urlPath
        self.additionalHeaders = additionalHeaders
        self.upgradePromise = upgradePromise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            sendInitialRequest(context: context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        sendInitialRequest(context: context)
        context.fireChannelActive()
    }

    func sendInitialRequest(context: ChannelHandlerContext) {
        // We are connected. It's time to send the message to the server to initialize the upgrade dance.
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "host", value: self.host)
        headers.add(name: "Sec-WebSocket-Protocol", value: "mqtt")
        headers.add(contentsOf: self.additionalHeaders)

        let requestHead = HTTPRequestHead(
            version: HTTPVersion(major: 1, minor: 1),
            method: .GET,
            uri: urlPath,
            headers: headers
        )

        context.write(self.wrapOutboundOut(.head(requestHead)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let clientResponse = self.unwrapInboundIn(data)

        switch clientResponse {
        case .head:
            self.upgradePromise.fail(MQTTError.websocketUpgradeFailed)
        case .body:
            break
        case .end:
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        self.upgradePromise.fail(error)
        // As we are not really interested getting notified on success or failure
        // we just pass nil as promise to reduce allocations.
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // If channel is closed while this ChannelHandler is still active then we should
        // fail the upgrade
        self.upgradePromise.fail(ChannelError.ioOnClosedChannel)
    }
}
