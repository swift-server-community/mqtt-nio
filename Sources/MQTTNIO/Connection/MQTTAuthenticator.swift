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

public protocol MQTTAuthenticator: Sendable {
    /// Authentication method name passed from client to server and back in the authentication method property
    var methodName: String { get }
    /// Respond to AUTH packet sent from server.
    func authenticate(_ authPackage: MQTTAuthV5) async throws -> MQTTAuthV5
}
