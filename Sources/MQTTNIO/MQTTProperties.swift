import NIO

/// MQTT v5.0 properties. A property consists of a identifier and a value
public struct MQTTProperties {
    public enum PropertyId: UInt8 {
        case payloadFormat = 1
        case messageExpiry = 2
        case contentType = 3
        case responseTopic = 8
        case correlationData = 9
        case subscriptionIdentifier = 11
        case sessionExpiryInterval = 17
        case assignedClientIdentifier = 18
        case serverKeepAlive = 19
        case authenticationMethod = 21
        case authenticationData = 22
        case requestProblemInformation = 23
        case willDelayInterval = 24
        case requestResponseInformation = 25
        case responseInformation = 26
        case serverReference = 28
        case reasonString = 31
        case receiveMaximum = 33
        case topicAliasMaximum = 34
        case topicAlias = 35
        case maximumQoS = 36
        case retainAvailable = 37
        case userProperty = 38
        case maximumPacketSize = 39
        case wildcardSubscriptionAvailable = 40
        case subscriptionIdentifierAvailable = 41
        case sharedSubscriptionAvailable = 42
    }
    
    public enum PropertyValue: Equatable {
        case byte(UInt8)
        case twoByteInteger(UInt16)
        case fourByteInteger(UInt32)
        case variableLengthInteger(UInt)
        case string(String)
        case stringPair(String, String)
        case binaryData(ByteBuffer)

        var type: PropertyValueType {
            switch self {
            case .byte: return .byte
            case .twoByteInteger: return .twoByteInteger
            case .fourByteInteger: return .fourByteInteger
            case .variableLengthInteger: return .variableLengthInteger
            case .string: return .string
            case .stringPair: return .stringPair
            case .binaryData: return .binaryData
            }
        }
    }

    public init() {
        self.properties = [:]
    }
    
    public init(_ properties: [PropertyId: PropertyValue]) throws {
        try properties.forEach {
            guard $0.key.definition.type == $0.value.type else { throw MQTTError.invalidPropertyValue }
        }
        self.properties = properties
    }
    
    public mutating func add(_ id: PropertyId, _ value: UInt) throws {
        switch id.definition.type {
        case .byte:
            guard (0...255).contains(value) else { throw MQTTError.propertyValueOutOfRange }
            properties[id] = .byte(UInt8(value))
        case .twoByteInteger:
            guard (0...65536).contains(value) else { throw MQTTError.propertyValueOutOfRange }
            properties[id] = .twoByteInteger(UInt16(value))
        case .fourByteInteger:
            guard (0..<(1<<32)).contains(value) else { throw MQTTError.propertyValueOutOfRange }
            properties[id] = .fourByteInteger(UInt32(value))
        case .variableLengthInteger:
            guard (0..<(1<<28)).contains(value) else { throw MQTTError.propertyValueOutOfRange }
            properties[id] = .variableLengthInteger(value)
        default:
            throw MQTTError.invalidPropertyValue
        }
    }
    
    public mutating func add(_ id: PropertyId, _ value: String) throws {
        guard id.definition.type == .string else { throw MQTTError.invalidPropertyValue }
        properties[id] = .string(value)
    }
    
    public mutating func add(_ id: PropertyId, _ value: (String, String)) throws {
        guard id.definition.type == .stringPair else { throw MQTTError.invalidPropertyValue }
        properties[id] = .stringPair(value.0, value.1)
    }
    
    public mutating func add(_ id: PropertyId, _ value: ByteBuffer) throws {
        guard id.definition.type == .binaryData else { throw MQTTError.invalidPropertyValue }
        properties[id] = .binaryData(value)
    }

    public subscript(_ id: PropertyId) -> PropertyValue? {
        return properties[id]
    }
    
    func write(to byteBuffer: inout ByteBuffer) throws {
        MQTTSerializer.writeVariableLengthInteger(self.packetSize, to: &byteBuffer)
        
        for property in properties {
            byteBuffer.writeInteger(property.key.rawValue)
            try property.value.write(to: &byteBuffer)
        }
    }

    static func read(from byteBuffer: inout ByteBuffer) throws -> Self {
        var properties: [PropertyId: PropertyValue] = [:]
        guard byteBuffer.readableBytes > 0 else {
            return try Self(properties)
        }
        let packetSize = try MQTTSerializer.readVariableLengthInteger(from: &byteBuffer)
        guard var propertyBuffer = byteBuffer.readSlice(length: packetSize) else { throw MQTTError.badResponse }
        while propertyBuffer.readableBytes > 0 {
            let property = try PropertyValue.read(from: &propertyBuffer)
            properties[property.id] = property.value
        }
        return try Self(properties)
    }
    
    var packetSize: Int {
        return properties.reduce(0) { $0 + 1 + $1.value.packetSize }
    }
    var properties: [PropertyId: PropertyValue]

    enum PropertyValueType {
        case byte
        case twoByteInteger
        case fourByteInteger
        case variableLengthInteger
        case string
        case stringPair
        case binaryData
    }

    struct MQTTPropertyDefinition {
        let type: PropertyValueType
    }
}

extension MQTTProperties.PropertyId {
    var definition: MQTTProperties.MQTTPropertyDefinition {
        switch self {
        case .payloadFormat: return .init(type: .byte)
        case .messageExpiry: return .init(type: .fourByteInteger)
        case .contentType: return .init(type: .string)
        case .responseTopic: return .init(type: .string)
        case .correlationData: return .init(type: .binaryData)
        case .subscriptionIdentifier: return .init(type: .variableLengthInteger)
        case .sessionExpiryInterval: return .init(type: .fourByteInteger)
        case .assignedClientIdentifier: return .init(type: .string)
        case .serverKeepAlive: return .init(type: .twoByteInteger)
        case .authenticationMethod: return .init(type: .string)
        case .authenticationData: return .init(type: .binaryData)
        case .requestProblemInformation: return .init(type: .byte)
        case .willDelayInterval: return .init(type: .fourByteInteger)
        case .requestResponseInformation: return .init(type: .byte)
        case .responseInformation: return .init(type: .string)
        case .serverReference: return .init(type: .string)
        case .reasonString: return .init(type: .string)
        case .receiveMaximum: return .init(type: .twoByteInteger)
        case .topicAliasMaximum: return .init(type: .twoByteInteger)
        case .topicAlias: return .init(type: .twoByteInteger)
        case .maximumQoS: return .init(type: .byte)
        case .retainAvailable: return .init(type: .byte)
        case .userProperty: return .init(type: .stringPair)
        case .maximumPacketSize: return .init(type: .fourByteInteger)
        case .wildcardSubscriptionAvailable: return .init(type: .byte)
        case .subscriptionIdentifierAvailable: return .init(type: .byte)
        case .sharedSubscriptionAvailable: return .init(type: .byte)
        }
    }

}

extension MQTTProperties.PropertyValue {
    var packetSize: Int {
        switch self {
        case .byte:
            return 1
        case .twoByteInteger:
            return 2
        case .fourByteInteger:
            return 4
        case .variableLengthInteger(let value):
            return MQTTSerializer.variableLengthIntegerPacketSize(Int(value))
        case .string(let string):
            return 2 + string.utf8.count
        case .stringPair(let string1, let string2):
            return 2 + string1.utf8.count + 2 + string2.utf8.count
        case .binaryData(let buffer):
            return 2 + buffer.readableBytes
        }
    }
    
    func write(to byteBuffer: inout ByteBuffer) throws {
        switch self {
        case .byte(let value):
            byteBuffer.writeInteger(value)
        case .twoByteInteger(let value):
            byteBuffer.writeInteger(value)
        case .fourByteInteger(let value):
            byteBuffer.writeInteger(value)
        case .variableLengthInteger(let value):
            MQTTSerializer.writeVariableLengthInteger(Int(value), to: &byteBuffer)
        case .string(let string):
            try MQTTSerializer.writeString(string, to: &byteBuffer)
        case .stringPair(let string1, let string2):
            try MQTTSerializer.writeString(string1, to: &byteBuffer)
            try MQTTSerializer.writeString(string2, to: &byteBuffer)
        case .binaryData(let buffer):
            try MQTTSerializer.writeBuffer(buffer, to: &byteBuffer)
        }
    }
    
    static func read(from byteBuffer: inout ByteBuffer) throws -> (id: MQTTProperties.PropertyId, value: Self) {
        guard let idValue: UInt8 = byteBuffer.readInteger() else { throw MQTTError.badResponse }
        guard let id = MQTTProperties.PropertyId(rawValue: idValue) else { throw MQTTError.badResponse }
        let propertyValue: Self
        switch id.definition.type {
        case .byte:
            guard let byte: UInt8 = byteBuffer.readInteger() else { throw MQTTError.badResponse}
            propertyValue = .byte(byte)
        case .twoByteInteger:
            guard let short: UInt16 = byteBuffer.readInteger() else { throw MQTTError.badResponse}
            propertyValue = .twoByteInteger(short)
        case .fourByteInteger:
            guard let integer: UInt32 = byteBuffer.readInteger() else { throw MQTTError.badResponse}
            propertyValue = .fourByteInteger(integer)
        case .variableLengthInteger:
            let integer = try MQTTSerializer.readVariableLengthInteger(from: &byteBuffer)
            propertyValue = .variableLengthInteger(UInt(integer))
        case .string:
            let string = try MQTTSerializer.readString(from: &byteBuffer)
            propertyValue = .string(string)
        case .stringPair:
            let string1 = try MQTTSerializer.readString(from: &byteBuffer)
            let string2 = try MQTTSerializer.readString(from: &byteBuffer)
            propertyValue = .stringPair(string1, string2)
        case .binaryData:
            let buffer = try MQTTSerializer.readBuffer(from: &byteBuffer)
            propertyValue = .binaryData(buffer)
        }
        return (id: id, value: propertyValue)
    }
}
