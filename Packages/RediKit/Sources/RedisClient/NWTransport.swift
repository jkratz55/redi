import Foundation
import Network
import Security
import Synchronization

/// `RedisTransport` backed by `NWConnection`.
///
/// `NWConnection` is used rather than the newer `NetworkConnection` API because it has an explicit
/// `cancel()`, full `sec_protocol_options` access (SNI, verify block, client identity), and a
/// synchronous, order-preserving `send`.
public final class NWTransport: RedisTransport {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let endpoint: RedisEndpoint

    /// Largest single read. Large enough for bulk throughput, small enough to keep chunks cache-friendly.
    private static let maximumReadLength = 256 * 1024

    public init(configuration: RedisConnectionConfiguration) {
        endpoint = configuration.endpoint
        let queue = DispatchQueue(label: "com.github.jkratz55.Redi.transport", qos: .userInitiated)
        self.queue = queue

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        tcp.keepaliveInterval = 15
        tcp.keepaliveCount = 4
        tcp.connectionTimeout = max(1, Int(configuration.connectTimeout.components.seconds))

        let tls = configuration.tls.map { tls in
            var defaultServerName: String?
            if case .tcp(let host, _) = configuration.endpoint { defaultServerName = host }
            return Self.makeTLSOptions(tls, defaultServerName: defaultServerName, queue: queue)
        }
        let parameters = NWParameters(tls: tls, tcp: tcp)

        let nwEndpoint: NWEndpoint = switch configuration.endpoint {
        case .tcp(let host, let port):
            .hostPort(host: NWEndpoint.Host(host),
                      port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 6379)
        case .unix(let path):
            .unix(path: path)
        }
        connection = NWConnection(to: nwEndpoint, using: parameters)
    }

    public func start(timeout: Duration) async throws {
        let gate = ResumeGate()
        let connection = self.connection
        let endpoint = self.endpoint
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                gate.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.resume(with: .success(()))
                    case .waiting(let error):
                        // NWConnection would otherwise wait for a better network path. For a
                        // database client an immediate failure (refused, unreachable, DNS) is better.
                        if gate.resume(with: .failure(RedisClientError.connectionFailed(Self.describe(error)))) {
                            connection.cancel()
                        }
                    case .failed(let error):
                        gate.resume(with: .failure(RedisClientError.connectionFailed(Self.describe(error))))
                    case .cancelled:
                        gate.resume(with: .failure(RedisClientError.connectionClosed))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                    if gate.resume(with: .failure(RedisClientError.connectTimeout(endpoint))) {
                        connection.cancel()
                    }
                }
            }
        } onCancel: {
            if gate.resume(with: .failure(CancellationError())) { connection.cancel() }
        }
    }

    public func write(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .contentProcessed { _ in
            // Send failures also fail the connection, which surfaces through `read()`.
        })
    }

    public func read() async throws -> Data? {
        let connection = self.connection
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumReadLength) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    if case .posix(let code) = error, code == .ECANCELED {
                        continuation.resume(throwing: RedisClientError.connectionClosed)
                    } else {
                        continuation.resume(throwing: RedisClientError.connectionFailed(Self.describe(error)))
                    }
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    public func close() {
        connection.cancel()
    }

    deinit {
        connection.cancel()
    }

    // MARK: - TLS

    private static func makeTLSOptions(_ tls: RedisTLSConfiguration,
                                       defaultServerName: String?,
                                       queue: DispatchQueue) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)

        if let serverName = tls.serverName ?? defaultServerName, !serverName.isIPAddress {
            sec_protocol_options_set_tls_server_name(security, serverName)
        }

        if let identity = tls.clientIdentity, let secIdentity = sec_identity_create(identity.identity) {
            sec_protocol_options_set_local_identity(security, secIdentity)
        }

        let roots: CertificateList
        switch tls.verification {
        case .customRoots(let der):
            roots = CertificateList(der.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) })
        case .system, .none:
            roots = CertificateList([])
        }
        let acceptsAnything = tls.verification == .none
        let verifiesHostname = tls.verifiesHostname
        guard acceptsAnything || !roots.certificates.isEmpty || !verifiesHostname else { return options }

        sec_protocol_options_set_verify_block(security, { _, trustRef, complete in
            if acceptsAnything {
                complete(true)
                return
            }
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            if !verifiesHostname {
                SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, nil))
            }
            if !roots.certificates.isEmpty {
                SecTrustSetAnchorCertificates(trust, roots.certificates as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, false)
            }
            SecTrustEvaluateAsyncWithError(trust, queue) { _, trusted, _ in
                complete(trusted)
            }
        }, queue)
        return options
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code): String(cString: strerror(code.rawValue))
        case .dns(let code): "DNS lookup failed (\(code))"
        case .tls(let status): SecCopyErrorMessageString(status, nil) as String? ?? "TLS error \(status)"
        default: error.localizedDescription
        }
    }
}

/// Immutable list of certificates captured by the TLS verify block.
private struct CertificateList: @unchecked Sendable {
    // SecCertificate is an immutable CF type.
    let certificates: [SecCertificate]
    init(_ certificates: [SecCertificate]) { self.certificates = certificates }
}

/// Resumes a continuation exactly once, whichever of ready / failure / timeout / cancel happens first.
final class ResumeGate: Sendable {
    private enum State {
        case initial
        case installed(CheckedContinuation<Void, any Error>)
        /// Resolved (e.g. cancelled) before the continuation was installed.
        case resolvedEarly(Result<Void, any Error>)
        case done
    }

    private let state = Mutex<State>(.initial)

    func install(_ continuation: CheckedContinuation<Void, any Error>) {
        state.withLock { state in
            switch state {
            case .initial:
                state = .installed(continuation)
            case .resolvedEarly(let result):
                state = .done
                continuation.resume(with: result)
            case .installed, .done:
                preconditionFailure("ResumeGate continuation installed twice")
            }
        }
    }

    /// Returns true if this call resolved the gate (i.e. it was first).
    @discardableResult
    func resume(with result: Result<Void, any Error>) -> Bool {
        state.withLock { state in
            switch state {
            case .initial:
                state = .resolvedEarly(result)
                return true
            case .installed(let continuation):
                state = .done
                continuation.resume(with: result)
                return true
            case .resolvedEarly, .done:
                return false
            }
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

extension String {
    var isIPAddress: Bool {
        IPv4Address(self) != nil || IPv6Address(self) != nil
    }
}
