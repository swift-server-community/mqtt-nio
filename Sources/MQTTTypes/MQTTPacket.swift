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

import NIO
import Foundation

public enum InternalError: Swift.Error {
    case incompletePacket
    case notImplemented
}

/// Protocol for all MQTT packet types
public protocol MQTTPacket: CustomStringConvertible {
    /// packet type
    var type: MQTTPacketType { get }
    /// packet id (default to zero if not used)
    var packetId: UInt16 { get }
    /// write packet to bytebuffer
    func write(version: MQTTVersion, to: inout ByteBuffer) throws
    /// read packet from incoming packet
    static func read(version: MQTTVersion, from: MQTTIncomingPacket) throws -> Self
}

extension MQTTPacket {
    /// default packet to zero
    public var packetId: UInt16 { 0 }
}

extension MQTTPacket {
    /// write fixed header for packet
    func writeFixedHeader(packetType: MQTTPacketType, flags: UInt8 = 0, size: Int, to byteBuffer: inout ByteBuffer) {
        byteBuffer.writeInteger(packetType.rawValue | flags)
        MQTTSerializer.writeVariableLengthInteger(size, to: &byteBuffer)
    }
}

public struct MQTTConnectPacket: MQTTPacket {
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

    public var type: MQTTPacketType { .CONNECT }
    public var description: String { "CONNECT" }

    /// Whether to establish a new, clean session or resume a previous session.
    public let cleanSession: Bool

    /// MQTT keep alive period.
    public let keepAliveSeconds: UInt16

    /// MQTT client identifier. Must be unique per client.
    public let clientIdentifier: String

    /// MQTT user name.
    public let userName: String?

    /// MQTT password.
    public let password: String?

    /// MQTT v5 properties
    public let properties: MQTTProperties

    /// will published when connected
    public let will: MQTTPublishInfo?

    public init(cleanSession: Bool, keepAliveSeconds: UInt16, clientIdentifier: String, userName: String?, password: String?, properties: MQTTProperties, will: MQTTPublishInfo?) {
        self.cleanSession = cleanSession
        self.keepAliveSeconds = keepAliveSeconds
        self.clientIdentifier = clientIdentifier
        self.userName = userName
        self.password = password
        self.properties = properties
        self.will = will
    }

    /// write connect packet to bytebuffer
    public func write(version: MQTTVersion, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: .CONNECT, size: self.packetSize(version: version), to: &byteBuffer)
        // variable header
        try MQTTSerializer.writeString("MQTT", to: &byteBuffer)
        // protocol level
        byteBuffer.writeInteger(version.versionByte)
        // connect flags
        var flags = self.cleanSession ? ConnectFlags.cleanSession : 0
        if let will = will {
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
        if let will = will {
            if version == .v5_0 {
                try will.properties.write(to: &byteBuffer)
            }
            try MQTTSerializer.writeString(will.topicName, to: &byteBuffer)
            try MQTTSerializer.writeBuffer(will.payload, to: &byteBuffer)
        }
        if let userName = userName {
            try MQTTSerializer.writeString(userName, to: &byteBuffer)
        }
        if let password = password {
            try MQTTSerializer.writeString(password, to: &byteBuffer)
        }
    }

    /// read connect packet from incoming packet (not implemented)
    public static func read(version: MQTTVersion, from: MQTTIncomingPacket) throws -> Self {
        throw InternalError.notImplemented
    }

    /// calculate size of connect packet
    func packetSize(version: MQTTVersion) -> Int {
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
        if let will = will {
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
        if let userName = userName {
            size += userName.utf8.count + 2
        }
        // password
        if let password = password {
            size += password.utf8.count + 2
        }
        return size
    }
}

public struct MQTTPublishPacket: MQTTPacket {
    enum PublishFlags {
        static let duplicate: UInt8 = 8
        static let retain: UInt8 = 1
        static let qosShift: UInt8 = 1
        static let qosMask: UInt8 = 6
    }

    public var type: MQTTPacketType { .PUBLISH }
    public var description: String { "PUBLISH" }

    public let publish: MQTTPublishInfo
    public let packetId: UInt16

    public init(publish: MQTTPublishInfo, packetId: UInt16) {
        self.publish = publish
        self.packetId = packetId
    }

    public func write(version: MQTTVersion, to byteBuffer: inout ByteBuffer) throws {
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

    public static func read(version: MQTTVersion, from packet: MQTTIncomingPacket) throws -> Self {
        var remainingData = packet.remainingData
        var packetId: UInt16 = 0
        // read topic name
        let topicName = try MQTTSerializer.readString(from: &remainingData)
        guard let qos = MQTTQoS(rawValue: (packet.flags & PublishFlags.qosMask) >> PublishFlags.qosShift) else { throw MQTTPacketError.badParameter }
        // read packet id if QoS is not atMostOnce
        if qos != .atMostOnce {
            guard let readPacketId: UInt16 = remainingData.readInteger() else { throw MQTTPacketError.badParameter }
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
    func packetSize(version: MQTTVersion) -> Int {
        // topic name
        var size = self.publish.topicName.utf8.count
        if self.publish.qos != .atMostOnce {
            size += 2
        }
        // packet identifier
        size += 2
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

public struct MQTTSubscribePacket: MQTTPacket {
    enum SubscribeFlags {
        static let qosMask: UInt8 = 3
        static let noLocal: UInt8 = 4
        static let retainAsPublished: UInt8 = 8
        static let retainHandlingShift: UInt8 = 4
        static let retainHandlingMask: UInt8 = 48
    }

    public var type: MQTTPacketType { .SUBSCRIBE }
    public var description: String { "SUBSCRIBE" }

    public let subscriptions: [MQTTSubscribeInfoV5]
    public let properties: MQTTProperties?
    public let packetId: UInt16

    public init(subscriptions: [MQTTSubscribeInfoV5], properties: MQTTProperties?, packetId: UInt16) {
        self.subscriptions = subscriptions
        self.properties = properties
        self.packetId = packetId
    }

    public func write(version: MQTTVersion, to byteBuffer: inout ByteBuffer) throws {
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

    public static func read(version: MQTTVersion, from packet: MQTTIncomingPacket) throws -> Self {
        throw InternalError.notImplemented
    }

    /// calculate size of subscribe packet
    func packetSize(version: MQTTVersion) -> Int {
        // packet identifier
        var size = 2
        // properties
        if version == .v5_0 {
            let propertiesPacketSize = self.properties?.packetSize ?? 0
            size += MQTTSerializer.variableLengthIntegerPacketSize(propertiesPacketSize) + propertiesPacketSize
        }
        // payload
        return self.subscriptions.reduce(size) {
            $0 + 2 + $1.topicFilter.utf8.count + 1 // topic filter length + topic filter + qos
        }
    }
}

public struct MQTTUnsubscribePacket: MQTTPacket {
    public var type: MQTTPacketType { .UNSUBSCRIBE }
    public var description: String { "UNSUBSCRIBE" }

    public let subscriptions: [String]
    public let properties: MQTTProperties?
    public let packetId: UInt16

    public init(subscriptions: [String], properties: MQTTProperties?, packetId: UInt16) {
        self.subscriptions = subscriptions
        self.properties = properties
        self.packetId = packetId
    }

    public func write(version: MQTTVersion, to byteBuffer: inout ByteBuffer) throws {
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

    public static func read(version: MQTTVersion, from packet: MQTTIncomingPacket) throws -> Self {
        throw InternalError.notImplemented
    }

    /// calculate size of subscribe packet
    func packetSize(version: MQTTVersion) -> Int {
        // packet identifier
        var size = 2
        // properties
        if version == .v5_0 {
            let propertiesPacketSize = self.properties?.packetSize ?? 0
            size += MQTTSerializer.variableLengthIntegerPacketSize(propertiesPacketSize) + propertiesPacketSize
        }
        // payload
        return self.subscriptions.reduce(size) {
            $0 + 2 + $1.utf8.count // topic filter length + topic filter
        }
    }
}

public struct MQTTPubAckPacket: MQTTPacket {
    public var description: String { "ACK \(self.type)" }
    public let type: MQTTPacketType
    public let packetId: UInt16
    public let reason: MQTTReasonCode
    public let properties: MQTTProperties

    public init(
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

    public func write(version: MQTTVersion, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: self.type, size: self.packetSize(version: version), to: &byteBuffer)
        byteBuffer.writeInteger(self.packetId)
        if version == .v5_0,
           self.reason != .success || self.properties.count > 0
        {
            byteBuffer.writeInteger(self.reason.rawValue)
            try self.properties.write(to: &byteBuffer)
        }
    }

    public static func read(version: MQTTVersion, from packet: MQTTIncomingPacket) throws -> Self {
        var remainingData = packet.remainingData
        guard let packetId: UInt16 = remainingData.readInteger() else { throw MQTTPacketError.badParameter }
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
                throw MQTTPacketError.badParameter
            }
            let properties = try MQTTProperties.read(from: &remainingData)
            return MQTTPubAckPacket(type: packet.type, packetId: packetId, reason: reason, properties: properties)
        }
    }

    func packetSize(version: MQTTVersion) -> Int {
        if version == .v5_0,
           self.reason != .success || self.properties.count > 0
        {
            let propertiesPacketSize = self.properties.packetSize
            return 3 + MQTTSerializer.variableLengthIntegerPacketSize(propertiesPacketSize) + propertiesPacketSize
        }
        return 2
    }
}

public struct MQTTSubAckPacket: MQTTPacket {
    public var description: String { "ACK \(self.type)" }
    public let type: MQTTPacketType
    public let packetId: UInt16
    public let reasons: [MQTTReasonCode]
    public let properties: MQTTProperties

    public init(type: MQTTPacketType, packetId: UInt16, reasons: [MQTTReasonCode], properties: MQTTProperties = .init()) {
        self.type = type
        self.packetId = packetId
        self.reasons = reasons
        self.properties = properties
    }

    public func write(version: MQTTVersion, to byteBuffer: inout ByteBuffer) throws {
        throw InternalError.notImplemented
    }

    public static func read(version: MQTTVersion, from packet: MQTTIncomingPacket) throws -> Self {
        var remainingData = packet.remainingData
        guard let packetId: UInt16 = remainingData.readInteger() else { throw MQTTPacketError.badParameter }
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
                    throw MQTTPacketError.badParameter
                }
                return reason
            }
        }
        return MQTTSubAckPacket(type: packet.type, packetId: packetId, reasons: reasons ?? [], properties: properties)
    }

    func packetSize(version: MQTTVersion) -> Int {
        if version == .v5_0 {
            let propertiesPacketSize = self.properties.packetSize
            return 2 + MQTTSerializer.variableLengthIntegerPacketSize(propertiesPacketSize) + propertiesPacketSize
        }
        return 2
    }
}

public struct MQTTPingreqPacket: MQTTPacket {
    public var type: MQTTPacketType { .PINGREQ }
    public var description: String { "PINGREQ" }

    public init() {}

    public func write(version: MQTTVersion, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: .PINGREQ, size: self.packetSize, to: &byteBuffer)
    }

    public static func read(version: MQTTVersion, from packet: MQTTIncomingPacket) throws -> Self {
        throw InternalError.notImplemented
    }

    var packetSize: Int { 0 }
}

public struct MQTTPingrespPacket: MQTTPacket {
    public var type: MQTTPacketType { .PINGRESP }
    public var description: String { "PINGRESP" }

    public init() {}

    public func write(version: MQTTVersion, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: self.type, size: self.packetSize, to: &byteBuffer)
    }

    public static func read(version: MQTTVersion, from packet: MQTTIncomingPacket) throws -> Self {
        return MQTTPingrespPacket()
    }

    var packetSize: Int { 0 }
}

public struct MQTTDisconnectPacket: MQTTPacket {
    public var type: MQTTPacketType { .DISCONNECT }
    public var description: String { "DISCONNECT" }
    public let reason: MQTTReasonCode
    public let properties: MQTTProperties

    public init(reason: MQTTReasonCode = .success, properties: MQTTProperties = .init()) {
        self.reason = reason
        self.properties = properties
    }

    public func write(version: MQTTVersion, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: self.type, size: self.packetSize(version: version), to: &byteBuffer)
        if version == .v5_0,
           self.reason != .success || self.properties.count > 0
        {
            byteBuffer.writeInteger(self.reason.rawValue)
            try self.properties.write(to: &byteBuffer)
        }
    }

    public static func read(version: MQTTVersion, from packet: MQTTIncomingPacket) throws -> Self {
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
                throw MQTTPacketError.badParameter
            }
            let properties = try MQTTProperties.read(from: &buffer)
            return MQTTDisconnectPacket(reason: reason, properties: properties)
        }
    }

    func packetSize(version: MQTTVersion) -> Int {
        if version == .v5_0,
           self.reason != .success || self.properties.count > 0
        {
            let propertiesPacketSize = self.properties.packetSize
            return 1 + MQTTSerializer.variableLengthIntegerPacketSize(propertiesPacketSize) + propertiesPacketSize
        }
        return 0
    }
}

public struct MQTTConnAckPacket: MQTTPacket {
    public var type: MQTTPacketType { .CONNACK }
    public var description: String { "CONNACK" }
    public let returnCode: UInt8
    public let acknowledgeFlags: UInt8
    public let properties: MQTTProperties

    public var sessionPresent: Bool { self.acknowledgeFlags & 0x1 == 0x1 }

    public init(returnCode: UInt8, acknowledgeFlags: UInt8, properties: MQTTProperties) {
        self.returnCode = returnCode
        self.acknowledgeFlags = acknowledgeFlags
        self.properties = properties
    }

    public func write(version: MQTTVersion, to: inout ByteBuffer) throws {
        throw InternalError.notImplemented
    }

    public static func read(version: MQTTVersion, from packet: MQTTIncomingPacket) throws -> Self {
        var remainingData = packet.remainingData
        guard let bytes = remainingData.readBytes(length: 2) else { throw MQTTPacketError.badParameter }
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
}

public struct MQTTAuthPacket: MQTTPacket {
    public var type: MQTTPacketType { .AUTH }
    public var description: String { "AUTH" }
    public let reason: MQTTReasonCode
    public let properties: MQTTProperties

    public init(reason: MQTTReasonCode, properties: MQTTProperties) {
        self.reason = reason
        self.properties = properties
    }

    public func write(version: MQTTVersion, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: self.type, size: self.packetSize, to: &byteBuffer)

        if self.reason != .success || self.properties.count > 0 {
            byteBuffer.writeInteger(self.reason.rawValue)
            try self.properties.write(to: &byteBuffer)
        }
    }

    public static func read(version: MQTTVersion, from packet: MQTTIncomingPacket) throws -> Self {
        var remainingData = packet.remainingData
        // if no data attached then can assume success
        if remainingData.readableBytes == 0 {
            return MQTTAuthPacket(reason: .success, properties: .init())
        }
        guard let reasonByte: UInt8 = remainingData.readInteger(),
              let reason = MQTTReasonCode(rawValue: reasonByte)
        else {
            throw MQTTPacketError.badParameter
        }
        let properties = try MQTTProperties.read(from: &remainingData)
        return MQTTAuthPacket(reason: reason, properties: properties)
    }

    var packetSize: Int {
        if self.reason == .success, self.properties.count == 0 {
            return 0
        }
        let propertiesPacketSize = self.properties.packetSize
        return 1 + MQTTSerializer.variableLengthIntegerPacketSize(propertiesPacketSize) + propertiesPacketSize
    }
}

/// MQTT incoming packet parameters.
public struct MQTTIncomingPacket: MQTTPacket {
    public var description: String { "Incoming Packet 0x\(String(format: "%x", self.type.rawValue))" }

    /// Type of incoming MQTT packet.
    public let type: MQTTPacketType

    /// packet flags
    public let flags: UInt8

    /// Remaining serialized data in the MQTT packet.
    public let remainingData: ByteBuffer

    public func write(version: MQTTVersion, to byteBuffer: inout ByteBuffer) throws {
        writeFixedHeader(packetType: self.type, flags: self.flags, size: self.remainingData.readableBytes, to: &byteBuffer)
        var buffer = self.remainingData
        byteBuffer.writeBuffer(&buffer)
    }

    public static func read(version: MQTTVersion, from packet: MQTTIncomingPacket) throws -> Self {
        throw InternalError.notImplemented
    }

    /// read incoming packet
    ///
    /// read fixed header and data attached. Throws incomplete packet error if if cannot read
    /// everything
    public static func read(from byteBuffer: inout ByteBuffer) throws -> MQTTIncomingPacket {
        guard let byte: UInt8 = byteBuffer.readInteger() else { throw InternalError.incompletePacket }
        guard let type = MQTTPacketType(rawValue: byte) ?? MQTTPacketType(rawValue: byte & 0xF0) else {
            throw MQTTPacketError.badParameter
        }
        let length = try MQTTSerializer.readVariableLengthInteger(from: &byteBuffer)
        guard let bytes = byteBuffer.readSlice(length: length) else { throw InternalError.incompletePacket }
        return MQTTIncomingPacket(type: type, flags: byte & 0xF, remainingData: bytes)
    }
}
