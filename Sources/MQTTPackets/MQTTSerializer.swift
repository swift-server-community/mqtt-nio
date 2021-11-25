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

enum MQTTSerializer {
    /// write variable length
    static func writeVariableLengthInteger(_ value: Int, to byteBuffer: inout ByteBuffer) {
        var value = value
        repeat {
            let byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 {
                byteBuffer.writeInteger(byte | 0x80)
            } else {
                byteBuffer.writeInteger(byte)
            }
        } while value != 0
    }

    static func variableLengthIntegerPacketSize(_ value: Int) -> Int {
        var value = value
        var size = 0
        repeat {
            size += 1
            value >>= 7
        } while value != 0
        return size
    }

    /// write string to byte buffer
    static func writeString(_ string: String, to byteBuffer: inout ByteBuffer) throws {
        let length = string.utf8.count
        guard length < 65536 else { throw MQTTPacketError.badParameter }
        byteBuffer.writeInteger(UInt16(length))
        byteBuffer.writeString(string)
    }

    /// write buffer to byte buffer
    static func writeBuffer(_ buffer: ByteBuffer, to byteBuffer: inout ByteBuffer) throws {
        let length = buffer.readableBytes
        guard length < 65536 else { throw MQTTPacketError.badParameter }
        var buffer = buffer
        byteBuffer.writeInteger(UInt16(length))
        byteBuffer.writeBuffer(&buffer)
    }

    /// read variable length from bytebuffer
    static func readVariableLengthInteger(from byteBuffer: inout ByteBuffer) throws -> Int {
        var value = 0
        var shift = 0
        repeat {
            guard let byte: UInt8 = byteBuffer.readInteger() else { throw InternalError.incompletePacket }
            value += (Int(byte) & 0x7F) << shift
            if byte & 0x80 == 0 {
                break
            }
            shift += 7
        } while true
        return value
    }

    /// read string from bytebuffer
    static func readString(from byteBuffer: inout ByteBuffer) throws -> String {
        guard let length: UInt16 = byteBuffer.readInteger() else { throw MQTTError.badResponse }
        guard let string = byteBuffer.readString(length: Int(length)) else { throw MQTTError.badResponse }
        return string
    }

    /// read slice from bytebuffer
    static func readBuffer(from byteBuffer: inout ByteBuffer) throws -> ByteBuffer {
        guard let length: UInt16 = byteBuffer.readInteger() else { throw MQTTError.badResponse }
        guard let buffer = byteBuffer.readSlice(length: Int(length)) else { throw MQTTError.badResponse }
        return buffer
    }
}
