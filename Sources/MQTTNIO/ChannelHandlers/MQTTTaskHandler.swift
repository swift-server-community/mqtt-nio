//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2021 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import MQTTPackets
import NIO

/// Task handler.
final class MQTTTaskHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = MQTTPacket

    var eventLoop: EventLoop!
    var client: MQTTClient

    init(client: MQTTClient) {
        self.client = client
        self.eventLoop = nil
        self.tasks = []
    }

    func addTask(_ task: MQTTTask) -> EventLoopFuture<Void> {
        return self.eventLoop.submit {
            self.tasks.append(task)
        }
    }

    private func _removeTask(_ task: MQTTTask) {
        self.tasks.removeAll { $0 === task }
    }

    private func removeTask(_ task: MQTTTask) {
        if self.eventLoop.inEventLoop {
            self._removeTask(task)
        } else {
            self.eventLoop.execute {
                self._removeTask(task)
            }
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.eventLoop = context.eventLoop
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        for task in self.tasks {
            do {
                // should this task respond to inbound packet
                if try task.checkInbound(response) {
                    self.removeTask(task)
                    task.succeed(response)
                    return
                }
            } catch {
                self.removeTask(task)
                task.fail(error)
                return
            }
        }

        self.processUnhandledPacket(response)
    }

    /// process packets where no equivalent task was found
    func processUnhandledPacket(_ packet: MQTTPacket) {
        // we only send response to v5 server
        guard self.client.configuration.version == .v5_0 else { return }
        guard let connection = client.connection else { return }

        switch packet.type {
        case .PUBREC:
            _ = connection.sendMessageNoWait(MQTTPubAckPacket(type: .PUBREL, packetId: packet.packetId, reason: .packetIdentifierNotFound))
        case .PUBREL:
            _ = connection.sendMessageNoWait(MQTTPubAckPacket(type: .PUBCOMP, packetId: packet.packetId, reason: .packetIdentifierNotFound))
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // channel is inactive so we should fail or tasks in progress
        self.tasks.forEach { $0.fail(MQTTError.serverClosedConnection) }
        self.tasks.removeAll()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // we caught an error so we should fail all active tasks
        self.tasks.forEach { $0.fail(error) }
        self.tasks.removeAll()
    }

    var tasks: [MQTTTask]
}
