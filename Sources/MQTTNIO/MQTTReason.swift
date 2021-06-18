/// MQTT v5.0 reason codes. A reason code is a one byte unsigned value that indicates the result of an operation.
/// Reason codes less than 128 are considered successful. Codes greater than or equal to 128 are considered
/// a failure
enum MQTTReasonCode: UInt8 {
    case success = 0
    case grantedQoS1 = 1
    case grantedQoS2 = 2
    case disconnectWithWill = 4
    case noMatchingSubscriber = 16
    case noSubscriptionExisted = 17
    case continueAuthentication = 24
    case reAuthenticate = 25
    case unspecifiedError = 128
    case malformedPacket = 129
    case protocolError = 130
    case implementationSpecificError = 131
    case unsupportedProtocolVersion = 132
    case clientIdentifierNotValid = 133
    case badUsernameOrPassword = 134
    case notAuthorized = 135
    case serverUnavailable = 136
    case serverBusy = 137
    case banned = 138
    case serverShuttingDown = 139
    case badAuthenticationMethod = 140
    case keepAliveTimeout = 141
    case sessionTakenOver = 142
    case topicFilterInvalid = 143
    case topicNameInvalid = 144
    case packetIdentifierInUse = 145
    case packetIdentifierNotFound = 146
    case receiveMaximumExceeded = 147
    case topicAliasInvalid = 148
    case packetTooLarge = 149
    case messageRateTooHigh = 150
    case quotaExceeeded = 151
    case administrativeAction = 152
    case payloadFormatInvalid = 153
    case retainNotSupported = 154
    case qosNotSupported = 155
    case useAnotherServer = 156
    case serverMoved = 157
    case sharedSubscriptionsNotSupported = 158
    case connectionRateExceeeded = 159
    case maximumConnectTime = 160
    case subscriptionIdentifiersNotSupported = 161
    case wildcardSubscriptionsNotSupported = 162
}
