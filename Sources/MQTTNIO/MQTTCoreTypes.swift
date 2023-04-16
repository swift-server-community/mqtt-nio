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

import NIOCore

/// Indicates the level of assurance for delivery of a packet.
public enum MQTTQoS: UInt8, Sendable {
    /// fire and forget
    case atMostOnce = 0
    /// wait for PUBACK, if you don't receive it after a period of time retry sending
    case atLeastOnce = 1
    /// wait for PUBREC, send PUBREL and then wait for PUBCOMP
    case exactlyOnce = 2
}

/// MQTT Packet type enumeration
public enum MQTTPacketType: UInt8, Sendable {
    case CONNECT = 0x10
    case CONNACK = 0x20
    case PUBLISH = 0x30
    case PUBACK = 0x40
    case PUBREC = 0x50
    case PUBREL = 0x62
    case PUBCOMP = 0x70
    case SUBSCRIBE = 0x82
    case SUBACK = 0x90
    case UNSUBSCRIBE = 0xA2
    case UNSUBACK = 0xB0
    case PINGREQ = 0xC0
    case PINGRESP = 0xD0
    case DISCONNECT = 0xE0
    case AUTH = 0xF0
}

/// MQTT PUBLISH packet parameters.
public struct MQTTPublishInfo: Sendable {
    /// Quality of Service for message.
    public let qos: MQTTQoS

    /// Whether this is a retained message.
    public let retain: Bool

    /// Whether this is a duplicate publish message.
    public let dup: Bool

    /// Topic name on which the message is published.
    public let topicName: String

    /// MQTT v5 properties
    public let properties: MQTTProperties

    /// Message payload.
    public let payload: ByteBuffer

    public init(qos: MQTTQoS, retain: Bool, dup: Bool = false, topicName: String, payload: ByteBuffer, properties: MQTTProperties) {
        self.qos = qos
        self.retain = retain
        self.dup = dup
        self.topicName = topicName
        self.payload = payload
        self.properties = properties
    }

    static let emptyByteBuffer = ByteBufferAllocator().buffer(capacity: 0)
}

/// MQTT SUBSCRIBE packet parameters.
public struct MQTTSubscribeInfo: Sendable {
    /// Topic filter to subscribe to.
    public let topicFilter: String

    /// Quality of Service for subscription.
    public let qos: MQTTQoS

    public init(topicFilter: String, qos: MQTTQoS) {
        self.qos = qos
        self.topicFilter = topicFilter
    }
}

/// MQTT Sub ACK
///
/// Contains data returned in subscribe ack packets
public struct MQTTSuback: Sendable {
    public enum ReturnCode: UInt8, Sendable {
        case grantedQoS0 = 0
        case grantedQoS1 = 1
        case grantedQoS2 = 2
        case failure = 0x80
    }

    /// MQTT v5 subscribe return codes
    public let returnCodes: [ReturnCode]

    init(returnCodes: [MQTTSuback.ReturnCode]) {
        self.returnCodes = returnCodes
    }
}
