# Sessions

Support for MQTT sessions.

## Overview

MQTT sessions allow clients to maintain state across multiple connections to the broker.
Sessions in MQTTNIO are represented by the ``MQTTSession`` type.
It is an object that is shared across multiple connections and can be used to maintain state such as pending QoS 1 and 2 messages and subscriptions.

Create an ``MQTTSession`` with a client ID and pass it to the ``MQTTConnection/withConnection(address:configuration:session:eventLoop:logger:operation:)-(_,_,_,_,_,(MQTTConnection,Bool)->Value)``.
You can check if the server has an existing session for the client ID by checking the optional `Bool` parameter passed to the closure.

```swift
let session = MQTTSession(clientID: "My Client", logger: Logger(...))

try await MQTTConnection.withConnection(
    address: .hostname("localhost"),
    session: session,
    logger: Logger(...)
) { connection, sessionPresent in
    if sessionPresent {
        print("The server has an existing session for this client ID")
    } else {
        print("The server does not have an existing session for this client ID")
    }
}
```

Upon connection, if there are pending QoS 2 acknowledgements that need to be sent to the broker, they will be sent automatically by MQTTNIO.

You can also open subscriptions via ``MQTTSession/subscribe(to:subscribeProperties:unsubscribeProperties:process:)``, which will keep the subscription active across multiple connections as long as the session is not expired on the server.
When there's an active connection that uses the session, the subscription will receive messages as normal.

```swift
let session = MQTTSession(clientID: "My Client", logger: Logger(...))

await withThrowingTaskGroup { group in
    group.addTask {
        try await session.subscribe(to: [.init(topicFilter: "my-topics", qos: .atLeastOnce)]) { subscription in
            for try await message in subscription {
                var buffer = message.payload
                let string = buffer.readString(length: buffer.readableBytes)
                print(string)
            }
        }
    }

    group.addTask {
        try await MQTTConnection.withConnection(
            address: .hostname("localhost"),
            session: session,
            logger: Logger(...)
        ) { connection in
            // The subscription will receive messages as normal while this connection is active.
            // When this connection is closed, the subscription will remain active
            // and will receive messages when a new connection is opened with the same session.
        }
    }
}
```

You can use the ``MQTTConnection/waitUntilNoActiveSubscriptions()`` method to wait until there are no active subscriptions opened either on the current connection or on the session the connection is using.

```swift
let session = MQTTSession(clientID: "My Client", logger: Logger(...))

await withThrowingTaskGroup { group in
    group.addTask {
        try await session.subscribe(to: [.init(topicFilter: "my-topics", qos: .atLeastOnce)]) { subscription in
            for try await message in subscription {
                var buffer = message.payload
                let string = buffer.readString(length: buffer.readableBytes)
                print(string)
            }
        }
    }

    group.addTask {
        try await MQTTConnection.withConnection(
            address: .hostname("localhost"),
            session: session,
            logger: Logger(...)
        ) { connection in
            await connection.waitUntilNoActiveSubscriptions()
            // This will wait until there are no active subscriptions on the connection or the session.
        }
    }
}
```

> Note: In the previous example, it's highly likely that the session subscription will not be active by the time `waitUntilNoActiveSubscriptions()` is called, since the connection task will likely finish before the subscription task.
This is just an example of how to use the method, but in a real application you would likely want to wait for the subscription to be active before calling `waitUntilNoActiveSubscriptions()`, otherwise it will just return immediately.