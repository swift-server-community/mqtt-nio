# MQTT Version 5.0

MQTTNIO support for MQTT v5 protocol.

## Overview

To create a connection to a v5 MQTT broker you need to set the version in the ``MQTTConnectionConfiguration``.
Inside ``MQTTConnectionConfiguration/VersionConfiguration/v5_0(connectProperties:disconnectProperties:will:authWorkflow:)-enum.case`` you can also provide ``MQTTProperties`` that will be sent in the `CONNECT` message when the connection is established and in the `DISCONNECT` message when the connection is closed.
You can also provide a v5 authentication workflow as an ``MQTTAuthenticator``.

```swift
try await MQTTConnection.withConnection(
    address: .hostname(host),
    configuration: .init(versionConfiguration: .v5_0()),
    identifier: "My V5 Client",
    logger: Logger(...)
) { connection in
    // You are now connected to the MQTT v5 broker
}
```

You can then use the same functions available to the v3.1.1 client but there are also v5.0 specific versions of ``MQTTConnection/V5/publish(to:payload:qos:retain:properties:)`` and ``MQTTConnection/V5/subscribe(to:subscribeProperties:unsubscribeProperties:process:)``.
These can be accessed via the variable ``MQTTConnection/v5``.
The v5.0 functions add support for MQTT properties in both function parameters and return types and the additional subscription parameters.
For example here is a `publish` call adding the `contentType` property.

```swift
_ = try await connection.v5.publish(
    to: "JSONTest",
    payload: payload,
    qos: .atLeastOnce,
    properties: [.contentType("application/json")]
)
```

Whoever subscribes to the "JSONTest" topic with a v5.0 client will also receive the `.contentType` property along with the payload.

When subscribing to a topic with the ``MQTTConnection/V5/subscribe(to:subscribeProperties:unsubscribeProperties:process:)`` method, the `AsyncSequence` of incoming messages will receive only messages that match the subscription ID that was automatically generated for that subscription.

There's also a ``MQTTConnection/V5/auth(properties:authWorkflow:)`` function available to perform MQTT v5 authentication workflows.
