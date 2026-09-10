# Distributed Tracing

Support for distributed tracing and propagating the trace context.

## Overview

Distributed tracing is a method for tracking a request from a client device as it moves through various backend services. It records where the request went and how long it spent doing it. 

MQTTNIO has support for creating tracing spans when publishing data or when subscribed to a topic. It also propagates the tracing context via MQTT publish packet so a publish can be linked to the processing of it by a subscriber.

## Enabling distributed tracing

Distributed tracing is enabled by the Swift package trait "DistributedTracing". This trait is enabled by default.

By default when you create a ``MQTTConnectionConfiguration`` it will setup tracing to use the tracer that is currently bootstrapped. 

## Publish spans

Once tracing is setup it will automatically create a tracing span for every publish packet.

## Subscription spans

If you want to create span for processing a publish packet received from a subscription you need to use ``MQTTConnection/withMessageSpan(_:createChildSpan:_:)`` from ``MQTTConnection``.

```swift
try await connection.subscribe(to: [.init(topicFilter: "myTopic", qos: .atLeastOnce)]) { subscription in
    for try await message in subscription {
        try await connection.withMessageSpan(message) { span in
            try await processMessage(message)
        }
    }
}
```

By default `withMessageSpan` creates a span that is the child of the current span and then adds a span link to the propagated publish tracing context. Alternatively you can call `withMessageSpan` with `createChildSpan` to create a span that is a child of the propagated publish tracing span.

## Configuration

``MQTTConnectionConfiguration`` includes a member ``MQTTConnectionConfiguration/tracing`` that allows you to configure tracing within MQTT. 

### Configuring span attributes names

It includes names for span attributes and default span attribute values. The defaults follow the naming conventions from [Open Telemetry](https://opentelemetry.io/docs/specs/semconv/messaging/messaging-spans/). You can edit these as follows.

```swift
var tracingConfig = MQTTTracingConfiguration()
tracingConfig.attributeNames.messagingOperationName = "mqtt.operation"
tracingConfig.attributeNames.messagingDestinationName = "mqtt.topic"

var configuration = MQTTConnectionConfiguration()
configuration.tracing = tracingConfig
```

### Configuring context propagation

The tracing configuration includes a member value ``MQTTTracingConfiguration/contextPropagator`` which is used to define how the tracing context is propagated from publisher to subscribers via MQTT. This is an existential type of a protocol ``MQTTContextPropagator`` that defines how the trace context can be injected into a `PUBLISH` packet and how the context can be extracted from a `PUBLISH` packet.

There is no defined industry standard on how the trace context is propagated but a number of key MQTT server implementations use the user properties of the `PUBLISH` packet and this is the default setup in `MQTTTracingConfiguration`.