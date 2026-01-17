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

enum InternalError: Swift.Error {
    case incompletePacket
    case notImplemented
}

/// Protocol for all MQTT packet types
protocol MQTTPacket: CustomStringConvertible, Sendable {
    /// packet type
    var type: MQTTPacketType { get }
    /// packet id (default to zero if not used)
    var packetId: UInt16 { get }
    /// write packet to bytebuffer
    func write(version: MQTTConnectionConfiguration.Version, to: inout ByteBuffer) throws
    /// read packet from incoming packet
    static func read(version: MQTTConnectionConfiguration.Version, from: MQTTIncomingPacket) throws -> Self
}

extension MQTTPacket {
    /// default packet to zero
    var packetId: UInt16 { 0 }
}

extension MQTTPacket {
    /// write fixed header for packet
    func writeFixedHeader(packetType: MQTTPacketType, flags: UInt8 = 0, size: Int, to byteBuffer: inout ByteBuffer) {
        byteBuffer.writeInteger(packetType.rawValue | flags)
        MQTTSerializer.writeVariableLengthInteger(size, to: &byteBuffer)
    }
}

extension MQTTConnectionConfiguration.Version {
    var versionByte: UInt8 {
        switch self {
        case .v3_1_1:
            return 4
        case .v5_0:
            return 5
        }
    }
}

struct MQTTConnectPacket: MQTTPacket {
    enum ConnectFlags {
        static let reserved: UInt8 = 1
        static let cleanSession: UInt8 = 2
        static let willFlag: UInt8 = 4
        static let willQoSShift: UInt8 = 3
        static let willQoSMask: UInt8 = 24
        static let willRetain: UInt8 = 32
        static let password: UInt8 = 64
        static let userName: UInt8 = 128
    }

    var type: MQTTPacketType { .CONNECT }
    var description: String { "CONNECT" }

    /// Whether to establish a new, clean session or resume a previous session.
    let cleanSession: Bool

    /// MQTT keep alive period.
    let keepAliveSeconds: UInt16

    /// MQTT client identifier. Must be unique per client.
    let clientIdentifier: String

    /// MQTT user name.
    let userName: String?

    /// MQTT password.
    let password: String?

    /// MQTT v5 properties
    let properties: MQTTProperties

    /// will published when connected
    let will: MQTTPublishInfo?

    /// write connect packet to bytebuffer
    func write(version: MQTTConnectionConfiguration.Version, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: .CONNECT, size: self.packetSize(version: version), to: &byteBuffer)
        // variable header
        try MQTTSerializer.writeString("MQTT", to: &byteBuffer)
        // protocol level
        byteBuffer.writeInteger(version.versionByte)
        // connect flags
        var flags = self.cleanSession ? ConnectFlags.cleanSession : 0
        if let will {
            flags |= ConnectFlags.willFlag
            flags |= will.retain ? ConnectFlags.willRetain : 0
            flags |= will.qos.rawValue << ConnectFlags.willQoSShift
        }
        flags |= self.password != nil ? ConnectFlags.password : 0
        flags |= self.userName != nil ? ConnectFlags.userName : 0
        byteBuffer.writeInteger(flags)
        // keep alive
        byteBuffer.writeInteger(self.keepAliveSeconds)
        // v5 properties
        if version == .v5_0 {
            try self.properties.write(to: &byteBuffer)
        }

        // payload
        try MQTTSerializer.writeString(self.clientIdentifier, to: &byteBuffer)
        if let will {
            if version == .v5_0 {
                try will.properties.write(to: &byteBuffer)
            }
            try MQTTSerializer.writeString(will.topicName, to: &byteBuffer)
            try MQTTSerializer.writeBuffer(will.payload, to: &byteBuffer)
        }
        if let userName {
            try MQTTSerializer.writeString(userName, to: &byteBuffer)
        }
        if let password {
            try MQTTSerializer.writeString(password, to: &byteBuffer)
        }
    }

    /// read connect packet from incoming packet
    static func read(version: MQTTConnectionConfiguration.Version, from packet: MQTTIncomingPacket) throws -> MQTTConnectPacket {
        assert(packet.type == .CONNECT)
        var remainingData = packet.remainingData
        let protocolName = try MQTTSerializer.readString(from: &remainingData)
        guard protocolName == "MQTT" else { throw MQTTError.badResponse }
        guard let header: (UInt8, UInt8, UInt16) = remainingData.readMultipleIntegers() else { throw MQTTError.badResponse }
        // version
        guard header.0 == 4 || header.0 == 5 else { throw MQTTError.badResponse }
        // flags
        let flags = header.1
        let cleanSession = (flags & ConnectFlags.cleanSession) != 0
        let keepAliveInterval = header.2
        // read properties
        let properties: MQTTProperties
        if version == .v5_0 {
            properties = try MQTTProperties.read(from: &remainingData)
        } else {
            properties = .init()
        }
        // payload
        // identifier
        let identifier = try MQTTSerializer.readString(from: &remainingData)

        // will
        var will: MQTTPublishInfo? = nil
        if (flags & ConnectFlags.willFlag) != 0 {
            // read will properties
            let willProperties: MQTTProperties
            if version == .v5_0 {
                willProperties = try MQTTProperties.read(from: &remainingData)
            } else {
                willProperties = .init()
            }
            let willTopicName = try MQTTSerializer.readString(from: &remainingData)
            let willPayload = try MQTTSerializer.readBuffer(from: &remainingData)
            guard let willQoS = MQTTQoS(rawValue: UInt8(flags & ConnectFlags.willQoSMask) >> ConnectFlags.willQoSShift) else {
                throw MQTTError.badResponse
            }
            will = MQTTPublishInfo(
                qos: willQoS,
                retain: (flags & ConnectFlags.willRetain) != 0,
                dup: false,
                topicName: willTopicName,
                payload: willPayload,
                properties: willProperties
            )
        }
        var userName: String? = nil
        if (flags & ConnectFlags.userName) != 0 {
            userName = try MQTTSerializer.readString(from: &remainingData)
        }
        var password: String? = nil
        if (flags & ConnectFlags.password) != 0 {
            password = try MQTTSerializer.readString(from: &remainingData)
        }
        return MQTTConnectPacket(
            cleanSession: cleanSession,
            keepAliveSeconds: keepAliveInterval,
            clientIdentifier: identifier,
            userName: userName,
            password: password,
            properties: properties,
            will: will
        )
    }

    /// calculate size of connect packet
    func packetSize(version: MQTTConnectionConfiguration.Version) -> Int {
        // variable header
        var size = 10
        // properties
        if version == .v5_0 {
            let propertiesPacketSize = self.properties.packetSize
            size += MQTTSerializer.variableLengthIntegerPacketSize(propertiesPacketSize) + propertiesPacketSize
        }
        // payload
        // client identifier
        size += self.clientIdentifier.utf8.count + 2
        // will publish
        if let will {
            // properties
            if version == .v5_0 {
                let propertiesPacketSize = will.properties.packetSize
                size += MQTTSerializer.variableLengthIntegerPacketSize(propertiesPacketSize) + propertiesPacketSize
            }
            // will topic
            size += will.topicName.utf8.count + 2
            // will message
            size += will.payload.readableBytes + 2
        }
        // user name
        if let userName {
            size += userName.utf8.count + 2
        }
        // password
        if let password {
            size += password.utf8.count + 2
        }
        return size
    }
}

struct MQTTPublishPacket: MQTTPacket {
    enum PublishFlags {
        static let duplicate: UInt8 = 8
        static let retain: UInt8 = 1
        static let qosShift: UInt8 = 1
        static let qosMask: UInt8 = 6
    }

    var type: MQTTPacketType { .PUBLISH }
    var description: String { "PUBLISH" }

    let publish: MQTTPublishInfo
    let packetId: UInt16

    func write(version: MQTTConnectionConfiguration.Version, to byteBuffer: inout ByteBuffer) throws {
        var flags: UInt8 = self.publish.retain ? PublishFlags.retain : 0
        flags |= self.publish.qos.rawValue << PublishFlags.qosShift
        flags |= self.publish.dup ? PublishFlags.duplicate : 0

        writeFixedHeader(packetType: .PUBLISH, flags: flags, size: self.packetSize(version: version), to: &byteBuffer)
        // write variable header
        try MQTTSerializer.writeString(self.publish.topicName, to: &byteBuffer)
        if self.publish.qos != .atMostOnce {
            byteBuffer.writeInteger(self.packetId)
        }
        // v5 properties
        if version == .v5_0 {
            try self.publish.properties.write(to: &byteBuffer)
        }
        // write payload
        var payload = self.publish.payload
        byteBuffer.writeBuffer(&payload)
    }

    static func read(version: MQTTConnectionConfiguration.Version, from packet: MQTTIncomingPacket) throws -> Self {
        assert(packet.type == .PUBLISH)
        var remainingData = packet.remainingData
        var packetId: UInt16 = 0
        // read topic name
        let topicName = try MQTTSerializer.readString(from: &remainingData)
        // read packet id if QoS is not atMostOnce
        guard let qos = MQTTQoS(rawValue: (packet.flags & PublishFlags.qosMask) >> PublishFlags.qosShift) else { throw MQTTError.badResponse }
        if qos != .atMostOnce {
            guard let readPacketId: UInt16 = remainingData.readInteger() else { throw MQTTError.badResponse }
            packetId = readPacketId
        }
        // read properties
        let properties: MQTTProperties
        if version == .v5_0 {
            properties = try MQTTProperties.read(from: &remainingData)
        } else {
            properties = .init()
        }

        // read payload
        let payload = remainingData.readSlice(length: remainingData.readableBytes) ?? MQTTPublishInfo.emptyByteBuffer
        // create publish info
        let publishInfo = MQTTPublishInfo(
            qos: qos,
            retain: packet.flags & PublishFlags.retain != 0,
            dup: packet.flags & PublishFlags.duplicate != 0,
            topicName: topicName,
            payload: payload,
            properties: properties
        )
        return MQTTPublishPacket(publish: publishInfo, packetId: packetId)
    }

    /// calculate size of publish packet
    func packetSize(version: MQTTConnectionConfiguration.Version) -> Int {
        // topic name
        var size = self.publish.topicName.utf8.count + 2
        // packet identifier
        if self.publish.qos != .atMostOnce {
            size += 2
        }
        // properties
        if version == .v5_0 {
            let propertiesPacketSize = self.publish.properties.packetSize
            size += MQTTSerializer.variableLengthIntegerPacketSize(propertiesPacketSize) + propertiesPacketSize
        }
        // payload
        size += self.publish.payload.readableBytes
        return size
    }
}

struct MQTTSubscribePacket: MQTTPacket {
    enum SubscribeFlags {
        static let qosMask: UInt8 = 3
        static let noLocal: UInt8 = 4
        static let retainAsPublished: UInt8 = 8
        static let retainHandlingShift: UInt8 = 4
        static let retainHandlingMask: UInt8 = 48
    }

    var type: MQTTPacketType { .SUBSCRIBE }
    var description: String { "SUBSCRIBE" }

    let subscriptions: [MQTTSubscribeInfoV5]
    let properties: MQTTProperties?
    let packetId: UInt16

    func write(version: MQTTConnectionConfiguration.Version, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: .SUBSCRIBE, size: self.packetSize(version: version), to: &byteBuffer)
        // write variable header
        byteBuffer.writeInteger(self.packetId)
        // v5 properties
        if version == .v5_0 {
            let properties = self.properties ?? MQTTProperties()
            try properties.write(to: &byteBuffer)
        }
        // write payload
        for info in self.subscriptions {
            try MQTTSerializer.writeString(info.topicFilter, to: &byteBuffer)
            switch version {
            case .v3_1_1:
                byteBuffer.writeInteger(info.qos.rawValue)
            case .v5_0:
                var flags = info.qos.rawValue & SubscribeFlags.qosMask
                flags |= info.noLocal ? SubscribeFlags.noLocal : 0
                flags |= info.retainAsPublished ? SubscribeFlags.retainAsPublished : 0
                flags |= (info.retainHandling.rawValue << SubscribeFlags.retainHandlingShift) & SubscribeFlags.retainHandlingMask
                byteBuffer.writeInteger(flags)
            }
        }
    }

    static func read(version: MQTTConnectionConfiguration.Version, from packet: MQTTIncomingPacket) throws -> Self {
        assert(packet.type == .SUBSCRIBE)
        var remainingData = packet.remainingData
        /// packet id
        guard let packetId: UInt16 = remainingData.readInteger() else { throw MQTTError.badResponse }
        // read properties
        let properties: MQTTProperties? =
            if version == .v5_0 {
                try MQTTProperties.read(from: &remainingData)
            } else {
                nil
            }
        var subscribeInfos: [MQTTSubscribeInfoV5] = []
        while remainingData.readableBytes > 0 {
            let topicFilter = try MQTTSerializer.readString(from: &remainingData)
            guard let flags: UInt8 = remainingData.readInteger() else { throw MQTTError.badResponse }
            guard let qos = MQTTQoS(rawValue: flags & SubscribeFlags.qosMask) else { throw MQTTError.badResponse }
            let noLocal = (flags & SubscribeFlags.noLocal) != 0
            let retainAsPublished = (flags & SubscribeFlags.retainAsPublished) != 0
            guard
                let retainHandling = MQTTSubscribeInfoV5.RetainHandling(
                    rawValue: (flags & SubscribeFlags.retainHandlingMask) >> SubscribeFlags.retainHandlingShift
                )
            else {
                throw MQTTError.badResponse
            }
            subscribeInfos.append(
                .init(topicFilter: topicFilter, qos: qos, noLocal: noLocal, retainAsPublished: retainAsPublished, retainHandling: retainHandling)
            )
        }
        return MQTTSubscribePacket(subscriptions: subscribeInfos, properties: properties, packetId: packetId)
    }

    /// calculate size of subscribe packet
    func packetSize(version: MQTTConnectionConfiguration.Version) -> Int {
        // packet identifier
        var size = 2
        // properties
        if version == .v5_0 {
            let propertiesPacketSize = self.properties?.packetSize ?? 0
            size += MQTTSerializer.variableLengthIntegerPacketSize(propertiesPacketSize) + propertiesPacketSize
        }
        // payload
        return self.subscriptions.reduce(size) {
            $0 + 2 + $1.topicFilter.utf8.count + 1  // topic filter length + topic filter + qos
        }
    }
}

struct MQTTUnsubscribePacket: MQTTPacket {
    var type: MQTTPacketType { .UNSUBSCRIBE }
    var description: String { "UNSUBSCRIBE" }

    let subscriptions: [String]
    let properties: MQTTProperties?
    let packetId: UInt16

    func write(version: MQTTConnectionConfiguration.Version, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: .UNSUBSCRIBE, size: self.packetSize(version: version), to: &byteBuffer)
        // write variable header
        byteBuffer.writeInteger(self.packetId)
        // v5 properties
        if version == .v5_0 {
            let properties = self.properties ?? MQTTProperties()
            try properties.write(to: &byteBuffer)
        }
        // write payload
        for sub in self.subscriptions {
            try MQTTSerializer.writeString(sub, to: &byteBuffer)
        }
    }

    static func read(version: MQTTConnectionConfiguration.Version, from packet: MQTTIncomingPacket) throws -> Self {
        assert(packet.type == .UNSUBSCRIBE)
        var remainingData = packet.remainingData
        /// packet id
        guard let packetId: UInt16 = remainingData.readInteger() else { throw MQTTError.badResponse }
        // read properties
        let properties: MQTTProperties? =
            if version == .v5_0 {
                try MQTTProperties.read(from: &remainingData)
            } else {
                nil
            }
        var subscribeInfos: [String] = []
        while remainingData.readableBytes > 0 {
            let topicFilter = try MQTTSerializer.readString(from: &remainingData)
            subscribeInfos.append(topicFilter)
        }
        return MQTTUnsubscribePacket(subscriptions: subscribeInfos, properties: properties, packetId: packetId)
    }

    /// calculate size of subscribe packet
    func packetSize(version: MQTTConnectionConfiguration.Version) -> Int {
        // packet identifier
        var size = 2
        // properties
        if version == .v5_0 {
            let propertiesPacketSize = self.properties?.packetSize ?? 0
            size += MQTTSerializer.variableLengthIntegerPacketSize(propertiesPacketSize) + propertiesPacketSize
        }
        // payload
        return self.subscriptions.reduce(size) {
            $0 + 2 + $1.utf8.count  // topic filter length + topic filter
        }
    }
}

struct MQTTPubAckPacket: MQTTPacket {
    var description: String { "ACK \(self.type)" }
    let type: MQTTPacketType
    let packetId: UInt16
    let reason: MQTTReasonCode
    let properties: MQTTProperties

    init(
        type: MQTTPacketType,
        packetId: UInt16,
        reason: MQTTReasonCode = .success,
        properties: MQTTProperties = .init()
    ) {
        self.type = type
        self.packetId = packetId
        self.reason = reason
        self.properties = properties
    }

    func write(version: MQTTConnectionConfiguration.Version, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: self.type, size: self.packetSize(version: version), to: &byteBuffer)
        byteBuffer.writeInteger(self.packetId)
        if version == .v5_0,
            self.reason != .success || self.properties.count > 0
        {
            byteBuffer.writeInteger(self.reason.rawValue)
            try self.properties.write(to: &byteBuffer)
        }
    }

    static func read(version: MQTTConnectionConfiguration.Version, from packet: MQTTIncomingPacket) throws -> Self {
        assert(packet.type == .PUBACK || packet.type == .PUBREC || packet.type == .PUBREL || packet.type == .PUBCOMP)
        var remainingData = packet.remainingData
        guard let packetId: UInt16 = remainingData.readInteger() else { throw MQTTError.badResponse }
        switch version {
        case .v3_1_1:
            return MQTTPubAckPacket(type: packet.type, packetId: packetId)
        case .v5_0:
            if remainingData.readableBytes == 0 {
                return MQTTPubAckPacket(type: packet.type, packetId: packetId)
            }
            guard let reasonByte: UInt8 = remainingData.readInteger(),
                let reason = MQTTReasonCode(rawValue: reasonByte)
            else {
                throw MQTTError.badResponse
            }
            let properties = try MQTTProperties.read(from: &remainingData)
            return MQTTPubAckPacket(type: packet.type, packetId: packetId, reason: reason, properties: properties)
        }
    }

    func packetSize(version: MQTTConnectionConfiguration.Version) -> Int {
        if version == .v5_0,
            self.reason != .success || self.properties.count > 0
        {
            let propertiesPacketSize = self.properties.packetSize
            return 3 + MQTTSerializer.variableLengthIntegerPacketSize(propertiesPacketSize) + propertiesPacketSize
        }
        return 2
    }
}

struct MQTTSubAckPacket: MQTTPacket {
    var description: String { "ACK \(self.type)" }
    let type: MQTTPacketType
    let packetId: UInt16
    let reasons: [MQTTReasonCode]
    let properties: MQTTProperties

    init(type: MQTTPacketType, packetId: UInt16, reasons: [MQTTReasonCode], properties: MQTTProperties = .init()) {
        self.type = type
        self.packetId = packetId
        self.reasons = reasons
        self.properties = properties
    }

    func write(version: MQTTConnectionConfiguration.Version, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: self.type, size: self.packetSize(version: version), to: &byteBuffer)
        byteBuffer.writeInteger(self.packetId)
        if version == .v5_0 {
            try self.properties.write(to: &byteBuffer)
        }
        for reason in reasons {
            byteBuffer.writeInteger(reason.rawValue)
        }
    }

    static func read(version: MQTTConnectionConfiguration.Version, from packet: MQTTIncomingPacket) throws -> Self {
        assert(packet.type == .SUBACK || packet.type == .UNSUBACK)
        var remainingData = packet.remainingData
        guard let packetId: UInt16 = remainingData.readInteger() else { throw MQTTError.badResponse }
        var properties: MQTTProperties
        if version == .v5_0 {
            properties = try MQTTProperties.read(from: &remainingData)
        } else {
            properties = .init()
        }
        var reasons: [MQTTReasonCode]?
        if let reasonBytes = remainingData.readBytes(length: remainingData.readableBytes) {
            reasons = try reasonBytes.map { byte -> MQTTReasonCode in
                guard let reason = MQTTReasonCode(rawValue: byte) else {
                    throw MQTTError.badResponse
                }
                return reason
            }
        }
        return MQTTSubAckPacket(type: packet.type, packetId: packetId, reasons: reasons ?? [], properties: properties)
    }

    func packetSize(version: MQTTConnectionConfiguration.Version) -> Int {
        if version == .v5_0 {
            let propertiesPacketSize = self.properties.packetSize
            return 2 + reasons.count + MQTTSerializer.variableLengthIntegerPacketSize(propertiesPacketSize) + propertiesPacketSize
        }
        return 2 + reasons.count
    }
}

struct MQTTPingreqPacket: MQTTPacket {
    var type: MQTTPacketType { .PINGREQ }
    var description: String { "PINGREQ" }
    func write(version: MQTTConnectionConfiguration.Version, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: .PINGREQ, size: self.packetSize, to: &byteBuffer)
    }

    static func read(version: MQTTConnectionConfiguration.Version, from packet: MQTTIncomingPacket) throws -> Self {
        assert(packet.type == .PINGREQ)
        return MQTTPingreqPacket()
    }

    var packetSize: Int { 0 }
}

struct MQTTPingrespPacket: MQTTPacket {
    var type: MQTTPacketType { .PINGRESP }
    var description: String { "PINGRESP" }

    func write(version: MQTTConnectionConfiguration.Version, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: self.type, size: self.packetSize, to: &byteBuffer)
    }

    static func read(version: MQTTConnectionConfiguration.Version, from packet: MQTTIncomingPacket) throws -> Self {
        assert(packet.type == .PINGRESP)
        return MQTTPingrespPacket()
    }

    var packetSize: Int { 0 }
}

struct MQTTDisconnectPacket: MQTTPacket {
    var type: MQTTPacketType { .DISCONNECT }
    var description: String { "DISCONNECT" }
    let reason: MQTTReasonCode
    let properties: MQTTProperties

    init(reason: MQTTReasonCode = .success, properties: MQTTProperties = .init()) {
        self.reason = reason
        self.properties = properties
    }

    func write(version: MQTTConnectionConfiguration.Version, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: self.type, size: self.packetSize(version: version), to: &byteBuffer)
        if version == .v5_0,
            self.reason != .success || self.properties.count > 0
        {
            byteBuffer.writeInteger(self.reason.rawValue)
            try self.properties.write(to: &byteBuffer)
        }
    }

    static func read(version: MQTTConnectionConfiguration.Version, from packet: MQTTIncomingPacket) throws -> Self {
        assert(packet.type == .DISCONNECT)
        var buffer = packet.remainingData
        switch version {
        case .v3_1_1:
            return MQTTDisconnectPacket()
        case .v5_0:
            if buffer.readableBytes == 0 {
                return MQTTDisconnectPacket(reason: .success)
            }
            guard let reasonByte: UInt8 = buffer.readInteger(),
                let reason = MQTTReasonCode(rawValue: reasonByte)
            else {
                throw MQTTError.badResponse
            }
            let properties = try MQTTProperties.read(from: &buffer)
            return MQTTDisconnectPacket(reason: reason, properties: properties)
        }
    }

    func packetSize(version: MQTTConnectionConfiguration.Version) -> Int {
        if version == .v5_0,
            self.reason != .success || self.properties.count > 0
        {
            let propertiesPacketSize = self.properties.packetSize
            return 1 + MQTTSerializer.variableLengthIntegerPacketSize(propertiesPacketSize) + propertiesPacketSize
        }
        return 0
    }
}

struct MQTTConnAckPacket: MQTTPacket {
    var type: MQTTPacketType { .CONNACK }
    var description: String { "CONNACK" }
    let returnCode: UInt8
    let acknowledgeFlags: UInt8
    let properties: MQTTProperties

    var sessionPresent: Bool { self.acknowledgeFlags & 0x1 == 0x1 }

    func write(version: MQTTConnectionConfiguration.Version, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: self.type, size: self.packetSize, to: &byteBuffer)
        byteBuffer.writeInteger(acknowledgeFlags)
        byteBuffer.writeInteger(returnCode)
        try self.properties.write(to: &byteBuffer)
    }

    static func read(version: MQTTConnectionConfiguration.Version, from packet: MQTTIncomingPacket) throws -> Self {
        assert(packet.type == .CONNACK)
        var remainingData = packet.remainingData
        guard let bytes = remainingData.readBytes(length: 2) else { throw MQTTError.badResponse }
        let properties: MQTTProperties
        if version == .v5_0 {
            properties = try MQTTProperties.read(from: &remainingData)
        } else {
            properties = .init()
        }
        return MQTTConnAckPacket(
            returnCode: bytes[1],
            acknowledgeFlags: bytes[0],
            properties: properties
        )
    }

    var packetSize: Int {
        let propertiesPacketSize = self.properties.packetSize
        return 2 + MQTTSerializer.variableLengthIntegerPacketSize(propertiesPacketSize) + propertiesPacketSize
    }
}

struct MQTTAuthPacket: MQTTPacket {
    var type: MQTTPacketType { .AUTH }
    var description: String { "AUTH" }
    let reason: MQTTReasonCode
    let properties: MQTTProperties

    func write(version: MQTTConnectionConfiguration.Version, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: self.type, size: self.packetSize, to: &byteBuffer)
        byteBuffer.writeInteger(self.reason.rawValue)
        try self.properties.write(to: &byteBuffer)
    }

    static func read(version: MQTTConnectionConfiguration.Version, from packet: MQTTIncomingPacket) throws -> Self {
        assert(packet.type == .AUTH)
        var remainingData = packet.remainingData
        // if no data attached then can assume success
        if remainingData.readableBytes == 0 {
            return MQTTAuthPacket(reason: .success, properties: .init())
        }
        guard let reasonByte: UInt8 = remainingData.readInteger(),
            let reason = MQTTReasonCode(rawValue: reasonByte)
        else {
            throw MQTTError.badResponse
        }
        let properties = try MQTTProperties.read(from: &remainingData)
        return MQTTAuthPacket(reason: reason, properties: properties)
    }

    var packetSize: Int {
        let propertiesPacketSize = self.properties.packetSize
        return 1 + MQTTSerializer.variableLengthIntegerPacketSize(propertiesPacketSize) + propertiesPacketSize
    }
}

/// MQTT incoming packet parameters.
struct MQTTIncomingPacket: MQTTPacket {
    var description: String { "Incoming Packet 0x\(String(self.type.rawValue, radix: 16))" }

    /// Type of incoming MQTT packet.
    let type: MQTTPacketType

    /// packet flags
    let flags: UInt8

    /// Remaining serialized data in the MQTT packet.
    let remainingData: ByteBuffer

    func write(version: MQTTConnectionConfiguration.Version, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: self.type, flags: self.flags, size: self.remainingData.readableBytes, to: &byteBuffer)
        var buffer = self.remainingData
        byteBuffer.writeBuffer(&buffer)
    }

    static func read(version: MQTTConnectionConfiguration.Version, from packet: MQTTIncomingPacket) throws -> Self {
        throw InternalError.notImplemented
    }

    /// read incoming packet
    ///
    /// read fixed header and data attached. Throws incomplete packet error if if cannot read
    /// everything
    static func read(from byteBuffer: inout ByteBuffer) throws -> MQTTIncomingPacket {
        guard let byte: UInt8 = byteBuffer.readInteger() else { throw InternalError.incompletePacket }
        guard let type = MQTTPacketType(rawValue: byte) ?? MQTTPacketType(rawValue: byte & 0xF0) else {
            throw MQTTError.unrecognisedPacketType
        }
        let length = try MQTTSerializer.readVariableLengthInteger(from: &byteBuffer)
        guard let bytes = byteBuffer.readSlice(length: length) else { throw InternalError.incompletePacket }
        return MQTTIncomingPacket(type: type, flags: byte & 0xF, remainingData: bytes)
    }
}
