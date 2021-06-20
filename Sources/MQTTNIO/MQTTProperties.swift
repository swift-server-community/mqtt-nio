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
    
    public enum PropertyValue {
        case byte(UInt8)
        case twoByteInteger(UInt16)
        case fourByteInteger(UInt)
        case variableLengthInteger(UInt)
        case string(String)
        case stringPair((String, String))
        case binaryData(ByteBuffer)
        
    }

    public init() {
        self.properties = [:]
    }
    
    public init(_ properties: [PropertyId: PropertyValue]) {
        self.properties = properties
    }
    
    public mutating func addProperty(id: PropertyId, value: UInt) throws {
        switch id.definition.type {
        case .byte:
            guard (0...255).contains(value) else { throw MQTTError.propertyValueOutOfRange }
            properties[id] = .byte(UInt8(value))
        case .twoByteInteger:
            guard (0...65536).contains(value) else { throw MQTTError.propertyValueOutOfRange }
            properties[id] = .twoByteInteger(UInt16(value))
        case .fourByteInteger:
            guard (0..<(1<<32)).contains(value) else { throw MQTTError.propertyValueOutOfRange }
            properties[id] = .fourByteInteger(value)
        case .variableLengthInteger:
            guard (0..<(1<<28)).contains(value) else { throw MQTTError.propertyValueOutOfRange }
            properties[id] = .variableLengthInteger(value)
        default:
            throw MQTTError.invalidPropertyValue
        }
    }
    
    public mutating func addProperty(id: PropertyId, value: String) throws {
        guard id.definition.type == .string else { throw MQTTError.invalidPropertyValue }
        properties[id] = .string(value)
    }
    
    public mutating func addProperty(id: PropertyId, value: (String, String)) throws {
        guard id.definition.type == .stringPair else { throw MQTTError.invalidPropertyValue }
        properties[id] = .stringPair(value)
    }
    
    public mutating func addProperty(id: PropertyId, value: ByteBuffer) throws {
        guard id.definition.type == .binaryData else { throw MQTTError.invalidPropertyValue }
        properties[id] = .binaryData(value)
    }

    func write(to byteBuffer: inout ByteBuffer) throws {
        let packetSize = properties.reduce(0) { $0 + 1 + $1.value.packetSize }
        MQTTSerializer.writeVariableLengthInteger(packetSize, to: &byteBuffer)
        
        for property in properties {
            byteBuffer.writeInteger(property.key.rawValue)
            try property.value.write(to: &byteBuffer)
        }
    }

    static func read(from byteBuffer: inout ByteBuffer) throws -> Self {
        var properties: [PropertyId: PropertyValue] = [:]
        let packetSize = try MQTTSerializer.readVariableLengthInteger(from: &byteBuffer)
        guard var propertyBuffer = byteBuffer.readSlice(length: packetSize) else { throw MQTTError.badResponse }
        while propertyBuffer.readableBytes > 0 {
            let property = try PropertyValue.read(from: &propertyBuffer)
            properties[property.id] = property.value
        }
        return Self(properties)
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
        case .variableLengthInteger(var value):
            var size = 0
            repeat {
                size += 1
                value >>= 7
            } while value != 0
            return size
        case .string(let string):
            return 2 + string.utf8.count
        case .stringPair(let strings):
            return 2 + strings.0.utf8.count + 2 + strings.1.utf8.count
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
        case .stringPair(let strings):
            try MQTTSerializer.writeString(strings.0, to: &byteBuffer)
            try MQTTSerializer.writeString(strings.1, to: &byteBuffer)
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
            propertyValue = .fourByteInteger(UInt(integer))
        case .variableLengthInteger:
            let integer = try MQTTSerializer.readVariableLengthInteger(from: &byteBuffer)
            propertyValue = .variableLengthInteger(UInt(integer))
        case .string:
            let string = try MQTTSerializer.readString(from: &byteBuffer)
            propertyValue = .string(string)
        case .stringPair:
            let string1 = try MQTTSerializer.readString(from: &byteBuffer)
            let string2 = try MQTTSerializer.readString(from: &byteBuffer)
            propertyValue = .stringPair((string1, string2))
        case .binaryData:
            let buffer = try MQTTSerializer.readBuffer(from: &byteBuffer)
            propertyValue = .binaryData(buffer)
        }
        return (id: id, value: propertyValue)
    }

}
