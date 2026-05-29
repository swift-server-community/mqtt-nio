//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

@testable public import MQTTNIO

extension MQTTError: Equatable {
    public static func == (lhs: MQTTError, rhs: MQTTError) -> Bool {
        switch (lhs, rhs) {
        case (.failedToConnect, .failedToConnect),
            (.connectionClosed, .connectionClosed),
            (.serverClosedConnection, .serverClosedConnection),
            (.unexpectedMessage, .unexpectedMessage),
            (.decodeError, .decodeError),
            (.websocketUpgradeFailed, .websocketUpgradeFailed),
            (.timeout, .timeout),
            (.retrySend, .retrySend),
            (.wrongTLSConfig, .wrongTLSConfig),
            (.badResponse, .badResponse),
            (.unrecognisedPacketType, .unrecognisedPacketType),
            (.authWorkflowRequired, .authWorkflowRequired),
            (.cancelledTask, .cancelledTask),
            (.packetTooLarge, .packetTooLarge),
            (.alreadyConnectedWithSession, .alreadyConnectedWithSession),
            (.noSessionPresent, .noSessionPresent):
            true
        case (.connectionError(let lhsValue), .connectionError(let rhsValue)):
            lhsValue == rhsValue
        case (.reasonError(let lhsValue), .reasonError(let rhsValue)):
            lhsValue == rhsValue
        case (.serverDisconnection(let lhsValue), .serverDisconnection(let rhsValue)):
            lhsValue.reason == rhsValue.reason && lhsValue.properties == rhsValue.properties
        case (.versionMismatch(let expectedLHS, let actualLHS), .versionMismatch(let expectedRHS, let actualRHS)):
            expectedLHS == expectedRHS && actualLHS == actualRHS
        case (.invalidTopicFilter(let lhsValue), .invalidTopicFilter(let rhsValue)):
            lhsValue == rhsValue
        default:
            false
        }
    }
}
