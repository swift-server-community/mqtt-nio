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

#if compiler(>=5.6)
public typealias _MQTTSendable = Sendable
public protocol _MQTTSendableProtocol: Sendable {}
#else
public typealias _MQTTSendable = Any
public protocol _MQTTSendableProtocol {}
#endif