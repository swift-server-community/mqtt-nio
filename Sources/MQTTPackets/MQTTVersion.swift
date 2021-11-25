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

/// Version of MQTT server to connect to
public enum MQTTVersion {
    case v3_1_1
    case v5_0

    var versionByte: UInt8 {
        switch self {
        case .v3_1_1:
            return 4
        case .v5_0:
            return 5
        }
    }
}

