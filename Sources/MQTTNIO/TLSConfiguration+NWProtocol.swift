#if canImport(Network)

import Foundation
import Network
import NIOSSL
import NIOTransportServices

extension TLSVersion {
    /// return Network framework TLS protocol version
    var nwTLSProtocolVersion: tls_protocol_version_t {
        switch self {
        case .tlsv1:
            return .TLSv10
        case .tlsv11:
            return .TLSv11
        case .tlsv12:
            return .TLSv12
        case .tlsv13:
            return .TLSv13
        }
    }
}

extension TLSVersion {
    /// return as SSL protocol
    var sslProtocol: SSLProtocol {
        switch self {
        case .tlsv1:
            return .tlsProtocol1
        case .tlsv11:
            return .tlsProtocol11
        case .tlsv12:
            return .tlsProtocol12
        case .tlsv13:
            return .tlsProtocol13
        }
    }
}

@available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension TLSConfiguration {
    /// Dispatch queue used by Network framework TLS to control certificate verification
    static var tlsDispatchQueue = DispatchQueue(label: "TLSDispatch")

    func supportedByTransportServices() -> Bool {
        guard
            certificateChain.count == 0,
            privateKey == nil,
            keyLogCallback == nil else {
            return false
        }
        return true
    }
    
    /// create NWProtocolTLS.Options for use with NIOTransportServices from the NIOSSL TLSConfiguration
    ///
    /// - Parameter queue: Dispatch queue to run `sec_protocol_options_set_verify_block` on.
    /// - Returns: Equivalent NWProtocolTLS Options
    func getNWProtocolTLSOptions() throws -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        var requiresVerifyBlock = false

        // minimum TLS protocol
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, self.minimumTLSVersion.nwTLSProtocolVersion)
        } else {
            sec_protocol_options_set_tls_min_version(options.securityProtocolOptions, self.minimumTLSVersion.sslProtocol)
        }

        // maximum TLS protocol
        if let maximumTLSVersion = self.maximumTLSVersion {
            if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
                sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, maximumTLSVersion.nwTLSProtocolVersion)
            } else {
                sec_protocol_options_set_tls_max_version(options.securityProtocolOptions, maximumTLSVersion.sslProtocol)
            }
        }

        // application protocols
        for applicationProtocol in self.applicationProtocols {
            applicationProtocol.withCString { buffer in
                sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, buffer)
            }
        }

        // the certificate chain
        if self.certificateChain.count > 0 {
            preconditionFailure("TLSConfiguration.certificateChain is not supported")
        }

        // cipher suites
        if self.cipherSuites.count > 0 {
            // TODO: Requires NIOSSL to provide list of cipher values before we can continue
            // https://github.com/apple/swift-nio-ssl/issues/207
        }

        // key log callback
        if self.keyLogCallback != nil {
            preconditionFailure("TLSConfiguration.keyLogCallback is not supported")
        }

        // private key
        if self.privateKey != nil {
            preconditionFailure("TLSConfiguration.privateKey is not supported")
        }

        // renegotiation support key is unsupported

        // trust roots
        var trustRootCertificates: [SecCertificate]?
        if let trustRoots = self.trustRoots {
            switch trustRoots {
            case .certificates(let certificates):
                try trustRootCertificates = certificates.compactMap { SecCertificateCreateWithData(nil, Data(try $0.toDERBytes()) as CFData)}
                requiresVerifyBlock = true
                break
            case .file(let file):
                let data = try Data(contentsOf: URL(fileURLWithPath: file))
                trustRootCertificates = SecCertificateCreateWithData(nil, data as CFData).map { [$0] }
                requiresVerifyBlock = true
                break
            case .default:
                break
            }
        }

        switch self.certificateVerification {
        case .none:
            requiresVerifyBlock = true

        case .noHostnameVerification:
            precondition(self.certificateVerification != .noHostnameVerification, "TLSConfiguration.certificateVerification = .noHostnameVerification is not supported")

        case .fullVerification:
            break
        }

        if requiresVerifyBlock {
            // add verify block to control certificate verification
            sec_protocol_options_set_verify_block(
                options.securityProtocolOptions,
                { sec_metadata, sec_trust, sec_protocol_verify_complete in
                    guard self.certificateVerification != .none else {
                        sec_protocol_verify_complete(true)
                        return
                    }

                    let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
                    if let trustRootCertificates = trustRootCertificates {
                        SecTrustSetAnchorCertificates(trust, trustRootCertificates as CFArray)
                    }
                    if #available(macOS 10.15, iOS 13.0, *) {
                        SecTrustEvaluateAsyncWithError(trust, TLSConfiguration.tlsDispatchQueue) { (trust, result, error) in
                            if let error = error {
                                print("Trust failed: \(error.localizedDescription)")
                            }
                            sec_protocol_verify_complete(result)
                        }
                    } else {
                        SecTrustEvaluateAsync(trust, TLSConfiguration.tlsDispatchQueue) { (trust, result) in
                             switch result {
                             case .proceed, .unspecified:
                                sec_protocol_verify_complete(true)
                             default:
                                sec_protocol_verify_complete(false)
                             }
                        }
                    }
                }, TLSConfiguration.tlsDispatchQueue
            )
        }
        return options
    }
}

#endif
