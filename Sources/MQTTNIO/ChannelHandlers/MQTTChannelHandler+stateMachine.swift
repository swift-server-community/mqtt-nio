//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2025 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension MQTTChannelHandler {
    @usableFromInline
    struct StateMachine<Context>: ~Copyable {
        @usableFromInline
        enum State: ~Copyable {
            case uninitialized
            case initialized(InitializedState)
            case closed

            @usableFromInline
            var description: String {
                borrowing get {
                    switch self {
                    case .uninitialized: "uninitialized"
                    case .initialized: "initialized"
                    case .closed: "closed"
                    }
                }
            }
        }
        @usableFromInline
        var state: State

        @usableFromInline
        struct InitializedState {
            let context: Context
            var tasks: [MQTTTask]
        }

        init() {
            self.state = .uninitialized
        }

        private init(_ state: consuming State) {
            self.state = state
        }

        /// handler has become active
        @usableFromInline
        mutating func setInitialized(context: Context) {
            switch consume self.state {
            case .uninitialized:
                self = .initialized(.init(context: context, tasks: []))
            case .initialized:
                preconditionFailure("Cannot set initialized state when state is initialized")
            case .closed:
                preconditionFailure("Cannot set initialized state when state is closed")
            }
        }

        @usableFromInline
        enum SendPacketAction {
            case sendPacket(Context)
            case throwError(any Error)
        }

        /// handler wants to send a packet
        @usableFromInline
        mutating func sendPacket(_ task: MQTTTask?) -> SendPacketAction {
            switch consume self.state {
            case .uninitialized:
                preconditionFailure("Cannot send packet when uninitialized")
            case .initialized(var state):
                if let task {
                    state.tasks.append(task)
                }
                self = .initialized(state)
                return .sendPacket(state.context)
            case .closed:
                self = .closed
                return .throwError(MQTTError.connectionClosed)
            }
        }

        @usableFromInline
        enum ReceivedPacketAction {
            /// .PUBLISH
            case respondAndReturn
            /// .CONNACK, .PUBACK, .PUBREC, .PUBCOMP, .SUBACK, .UNSUBACK, .PINGRESP, .AUTH
            /// .PUBREL
            case succeedTask(MQTTTask)
            /// checkInbound threw error
            case failTask(MQTTTask, any Error)
            /// process packets where no equivalent task was found
            case unhandledTask
            /// .DISCONNECT
            /// .CONNECT, .SUBSCRIBE, .UNSUBSCRIBE, .PINGREQ
            case closeConnection(any Error)
        }

        /// handler has received a packet
        @usableFromInline
        mutating func receivedPacket(_ packet: MQTTPacket) -> ReceivedPacketAction {
            switch consume self.state {
            case .uninitialized:
                preconditionFailure("Cannot receive packet when uninitialized")
            case .initialized(var state):
                switch packet.type {
                case .PUBLISH:
                    self = .initialized(state)
                    return .respondAndReturn
                case .CONNACK, .PUBACK, .PUBREC, .PUBCOMP, .SUBACK, .UNSUBACK, .PINGRESP, .AUTH, .PUBREL:
                    for task in state.tasks {
                        do {
                            // should this task respond to inbound packet
                            if try task.checkInbound(packet) {
                                state.tasks.removeAll { $0 === task }
                                self = .initialized(state)
                                return .succeedTask(task)
                            }
                        } catch {
                            state.tasks.removeAll { $0 === task }
                            self = .initialized(state)
                            return .failTask(task, error)
                        }
                    }
                    self = .initialized(state)
                    return .unhandledTask
                case .DISCONNECT:
                    let disconnectMessage = packet as! MQTTDisconnectPacket
                    let ack = MQTTAckV5(reason: disconnectMessage.reason, properties: disconnectMessage.properties)
                    self = .initialized(state)
                    return .closeConnection(MQTTError.serverDisconnection(ack))
                case .CONNECT, .SUBSCRIBE, .UNSUBSCRIBE, .PINGREQ:
                    self = .initialized(state)
                    return .closeConnection(MQTTError.unexpectedMessage)
                }
            case .closed:
                preconditionFailure("Cannot receive packet when closed")
            }
        }

        @usableFromInline
        enum WaitOnInitializedAction {
            case reportedClosed((any Error)?)
            case done
        }

        mutating func waitOnInitialized() -> WaitOnInitializedAction {
            switch consume self.state {
            case .uninitialized:
                preconditionFailure("Cannot wait until connection has succeeded")
            case .initialized(let state):
                self = .initialized(state)
                return .done
            case .closed:
                self = .closed
                return .reportedClosed(nil)
            }
        }

        @usableFromInline
        enum SchedulePingReqAction {
            case schedule(Context)
            case doNothing
        }

        @usableFromInline
        mutating func schedulePingReq() -> SchedulePingReqAction {
            switch consume self.state {
            case .uninitialized:
                preconditionFailure("Cannot schedule PINGREQ when uninitialized")
            case .initialized(let state):
                self = .initialized(state)
                return .schedule(state.context)
            case .closed:
                self = .closed
                return .doNothing
            }
        }

        @usableFromInline
        enum CloseAction {
            case failTasksAndClose([MQTTTask])
            case doNothing
        }
        /// Want to close the connection
        @usableFromInline
        mutating func close() -> CloseAction {
            switch consume self.state {
            case .uninitialized:
                self = .closed
                return .doNothing
            case .initialized(let state):
                self = .closed
                return .failTasksAndClose(state.tasks)
            case .closed:
                self = .closed
                return .doNothing
            }
        }

        private static var uninitialized: Self {
            StateMachine(.uninitialized)
        }

        private static func initialized(_ state: InitializedState) -> Self {
            StateMachine(.initialized(state))
        }

        private static var closed: Self {
            StateMachine(.closed)
        }
    }
}
