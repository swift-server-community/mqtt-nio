//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

package import Logging
import NIOCore
import Synchronization

/// MQTT session data.
package struct MQTTSessionStorage: Sendable {
    var inflight: MQTTInflight
    var subscriptions: MQTTSubscriptions
    var clientID: String

    package init(clientID: String, logger: Logger) {
        self.inflight = .init()
        self.subscriptions = .init(logger: logger)
        self.clientID = clientID
    }
}
