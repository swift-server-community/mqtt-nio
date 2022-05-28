# MQTT Version 5.0

MQTTNIO support for MQTT v5 protocol.

Version 2.0 of MQTTNIO added support for MQTT v5.0. To create a client that will connect to a v5 MQTT broker you need to set the version in the configuration as follows

```swift
let client = MQTTClient(
    host: host,
    identifier: "MyAWSClient",
    eventLoopGroupProvider: .createNew,
    configuration: .init(version: .v5_0)
)
```

You can then use the same functions available to the v3.1.1 client but there are also v5.0 specific versions of `connect`, `publish`, `subscribe`, `unsubscribe` and `disconnect`. These can be accessed via the variable `MQTTClient.v5`. The v5.0 functions add support for MQTT properties in both function parameters and return types and the additional subscription parameters. For example here is a `publish` call adding the `contentType` property.

```swift
_ = try await client.v5.publish(
    to: "JSONTest",
    payload: payload,
    qos: .atLeastOnce,
    properties: [.contentType("application/json")]
)
```

Whoever subscribes to the "JSONTest" topic with a v5.0 client will also receive the `.contentType` property along with the payload.
