//
//  File.swift
//  
//
//  Created by Adam Fowler on 24/11/2020.
//
#if canImport(Network)

import Network

extension tls_protocol_version_t {
    var sslProtocol: SSLProtocol {
        switch self {
        
        case .TLSv10:
            return .tlsProtocol1
        case .TLSv11:
            return .tlsProtocol11
        case .TLSv12:
            return .tlsProtocol12
        case .TLSv13:
            return .tlsProtocol13
        case .DTLSv10:
            return .dtlsProtocol1
        case .DTLSv12:
            return .dtlsProtocol12
        @unknown default:
            return .tlsProtocol1
        }
    }
}

/// Certificate verification modes.
public enum TSCertificateVerification {
    /// All certificate verification disabled.
    case none

    /// Certificates will be validated against the trust store and checked
    /// against the hostname of the service we are contacting.
    case fullVerification
}

/// TLS configuration for NIO Transport Services
public struct TSTLSConfiguration {
    /// The minimum TLS version to allow in negotiation. Defaults to tlsv1.
    public var minimumTLSVersion: tls_protocol_version_t

    /// The maximum TLS version to allow in negotiation. If nil, there is no upper limit. Defaults to nil.
    public var maximumTLSVersion: tls_protocol_version_t?

    /// The trust roots to use to validate certificates. This only needs to be provided if you intend to validate
    /// certificates.
    public var trustRoots: [SecCertificate]?

    /// The identity associated with the leaf certificate.
    public var clientIdentity: SecIdentity?

    /// Whether to verify remote certificates.
    public var certificateVerification: TSCertificateVerification
    
    /// Initialize TSTLSConfiguration
    public init(
        minimumTLSVersion: tls_protocol_version_t = .TLSv10,
        maximumTLSVersion: tls_protocol_version_t? = nil,
        trustRoots: [SecCertificate]? = nil,
        clientIdentity: SecIdentity? = nil,
        certificateVerification: TSCertificateVerification = .fullVerification
    ) {
        self.minimumTLSVersion = minimumTLSVersion
        self.maximumTLSVersion = maximumTLSVersion
        self.trustRoots = trustRoots
        self.clientIdentity = clientIdentity
        self.certificateVerification = certificateVerification
    }
    
}

extension TSTLSConfiguration {
    func getNWProtocolTLSOptions() throws -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()

        // minimum TLS protocol
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, self.minimumTLSVersion)
        } else {
            sec_protocol_options_set_tls_min_version(options.securityProtocolOptions, self.minimumTLSVersion.sslProtocol)
        }

        // maximum TLS protocol
        if let maximumTLSVersion = self.maximumTLSVersion {
            if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
                sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, maximumTLSVersion)
            } else {
                sec_protocol_options_set_tls_max_version(options.securityProtocolOptions, maximumTLSVersion.sslProtocol)
            }
        }
        
        if let clientIdentity = self.clientIdentity, let secClientIdentity = sec_identity_create(clientIdentity) {
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, secClientIdentity)
        }
        
        if certificateVerification != .fullVerification || trustRoots != nil {
            // add verify block to control certificate verification
            sec_protocol_options_set_verify_block(
                options.securityProtocolOptions,
                { sec_metadata, sec_trust, sec_protocol_verify_complete in
                    guard self.certificateVerification != .none else {
                        sec_protocol_verify_complete(true)
                        return
                    }

                    let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
                    if let trustRootCertificates = trustRoots {
                        SecTrustSetAnchorCertificates(trust, trustRootCertificates as CFArray)
                    }
                    if #available(macOS 10.15, iOS 13.0, *) {
                        SecTrustEvaluateAsyncWithError(trust, Self.tlsDispatchQueue) { (trust, result, error) in
                            if let error = error {
                                print("Trust failed: \(error.localizedDescription)")
                            }
                            sec_protocol_verify_complete(result)
                        }
                    } else {
                        SecTrustEvaluateAsync(trust, Self.tlsDispatchQueue) { (trust, result) in
                             switch result {
                             case .proceed, .unspecified:
                                sec_protocol_verify_complete(true)
                             default:
                                sec_protocol_verify_complete(false)
                             }
                        }
                    }
                }, Self.tlsDispatchQueue
            )
        }
        return options
    }

    /// Dispatch queue used by Network framework TLS to control certificate verification
    static var tlsDispatchQueue = DispatchQueue(label: "TSTLSConfiguration")
}
#endif
