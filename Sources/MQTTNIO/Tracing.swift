//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

#if DistributedTracingSupport

public import Tracing

/// Tracing context injector that injects into a ``MQTTPublishInfo``.
public protocol MQTTPublishInfoInjector: Injector where Carrier == MQTTPublishInfo {
}
/// Tracing context extractor that extracts from a ``MQTTPublishInfo``.
public protocol MQTTPublishInfoExtractor: Extractor where Carrier == MQTTPublishInfo {
}
/// Tracing context propagator that defines how the tracing context is propagated via
/// a ``MQTTPublishInfo``.
public protocol MQTTContextPropagator: Sendable {
    associatedtype Injector: MQTTPublishInfoInjector
    associatedtype Extractor: MQTTPublishInfoExtractor

    var injector: Injector { get }
    var extractor: Extractor { get }
}

/// Tracing context propagator that propagates the tracing context via the publish info
/// user properties
public struct UserPropertiesPropagator: MQTTContextPropagator {
    public struct Injector: MQTTPublishInfoInjector {
        public func inject(_ value: String, forKey key: String, into carrier: inout MQTTPublishInfo) {
            carrier.properties.append(.userProperty(key, value))
        }
    }
    public struct Extractor: MQTTPublishInfoExtractor {
        public func extract(key: String, from carrier: MQTTPublishInfo) -> String? {
            for property in carrier.properties {
                if case .userProperty(key, let propertyValue) = property {
                    return propertyValue
                }
            }
            return nil
        }
    }

    public var injector: Injector { .init() }
    public var extractor: Extractor { .init() }
}

extension MQTTContextPropagator where Self == UserPropertiesPropagator {
    public static var userProperties: Self { UserPropertiesPropagator() }
}

/// A configuration object that defines distributed tracing behavior of a MQTT client.
public struct MQTTTracingConfiguration: Sendable {
    /// The tracer to use, or `nil` to disable tracing.
    /// Defaults to the globally bootstrapped tracer.
    public var tracer: (any Tracer)? = InstrumentationSystem.tracer

    /// Tracing context propagator
    public var contextPropagator: any MQTTContextPropagator = .userProperties

    /// The attribute names used in spans created by Valkey. Defaults to OpenTelemetry semantics.
    public var attributeNames: AttributeNames = .init()

    /// The static attribute values used in spans created by Valkey.
    public var attributeValues: AttributeValues = .init()

    /// Attribute names used in spans created by Valkey.
    public struct AttributeNames: Sendable {
        public var messagingOperationName: String = "messaging.operation.name"
        public var messagingSystemName: String = "messaging.system"
        public var messagingDestinationName: String = "messaging.destination.name"
        public var networkPeerAddress: String = "network.peer.address"
        public var networkPeerPort: String = "network.peer.port"
        public var serverAddress: String = "server.address"
        public var serverPort: String = "server.port"
    }

    /// Static attribute values used in spans created by Valkey.
    public struct AttributeValues: Sendable {
        public var messagingSystem: String = "mqtt"
    }
}

extension MQTTConnection {
    func withMessageSpan<Value>(
        _ publishInfo: MQTTPublishInfo,
        _ operation: (any Span) async throws -> Value
    ) async throws -> Value {
        var serviceContext = ServiceContext.current ?? ServiceContext.topLevel
        self.tracer?.extract(publishInfo, into: &serviceContext, using: self.configuration.tracing.contextPropagator.extractor)
        return try await Tracing.withSpan("SUBSCRIBE", context: serviceContext, ofKind: .client) { span in
            span.updateAttributes { attributes in
                self.applyCommonSubscribeAttributes(to: &attributes)
                attributes[self.configuration.tracing.attributeNames.messagingDestinationName] = publishInfo.topicName
            }
            return try await operation(span)
        }
    }
}

#endif
