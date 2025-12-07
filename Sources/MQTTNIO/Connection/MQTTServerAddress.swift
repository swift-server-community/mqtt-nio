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

/// A MQTT broker address to connect to.
public struct MQTTServerAddress: Sendable, Equatable, Hashable {
    enum _Internal: Equatable, Hashable {
        case hostname(_ host: String, port: Int)
        case unixDomainSocket(path: String)
    }

    let value: _Internal
    init(_ value: _Internal) {
        self.value = value
    }

    // Address defined by host and port.
    public static func hostname(_ host: String, port: Int = 1883) -> Self { .init(.hostname(host, port: port)) }
    // Address defined by UNIX domain socket.
    public static func unixDomainSocket(path: String) -> Self { .init(.unixDomainSocket(path: path)) }
}
