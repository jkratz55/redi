import Foundation
import Security

/// Where to reach a Redis server.
public enum RedisEndpoint: Sendable, Hashable, CustomStringConvertible {
    case tcp(host: String, port: Int)
    /// Unix domain socket — used for local servers and for SSH tunnels forwarded to a socket file.
    case unix(path: String)

    public var description: String {
        switch self {
        case .tcp(let host, let port): host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        case .unix(let path): path
        }
    }
}

/// TLS settings for a connection.
public struct RedisTLSConfiguration: Sendable, Hashable {
    public enum Verification: Sendable, Hashable {
        /// Validate the server certificate against the system trust store.
        case system
        /// Validate against these DER-encoded CA certificates in addition to the system roots.
        case customRoots([Data])
        /// Accept any certificate. For development servers with self-signed certs only.
        case none
    }

    /// SNI and hostname-verification name. Defaults to the endpoint host. Set it explicitly when
    /// connecting through a tunnel, where the endpoint is a local socket.
    public var serverName: String?
    public var verification: Verification
    /// When false, the certificate chain is still verified but the hostname isn't. Common for
    /// servers addressed by IP whose certificates lack a matching SAN.
    public var verifiesHostname: Bool
    public var clientIdentity: TLSIdentity?

    public init(serverName: String? = nil,
                verification: Verification = .system,
                verifiesHostname: Bool = true,
                clientIdentity: TLSIdentity? = nil) {
        self.serverName = serverName
        self.verification = verification
        self.verifiesHostname = verifiesHostname
        self.clientIdentity = clientIdentity
    }
}

/// A client certificate and private key used for mutual TLS.
public struct TLSIdentity: @unchecked Sendable, Hashable {
    // SecIdentity is an immutable CF type and safe to share across threads.
    public let identity: SecIdentity

    public init(_ identity: SecIdentity) {
        self.identity = identity
    }

    public static func == (lhs: TLSIdentity, rhs: TLSIdentity) -> Bool { CFEqual(lhs.identity, rhs.identity) }
    public func hash(into hasher: inout Hasher) { hasher.combine(CFHash(identity)) }
}

/// Everything needed to open and authenticate one connection.
public struct RedisConnectionConfiguration: Sendable, Hashable {
    public enum ProtocolPreference: Sendable, Hashable {
        /// Try `HELLO 3`; fall back to RESP2 if the server or proxy doesn't support it.
        case resp3
        /// Always speak RESP2 (for proxies that mishandle `HELLO`).
        case resp2
    }

    public var endpoint: RedisEndpoint
    public var tls: RedisTLSConfiguration?
    public var username: String?
    public var password: String?
    public var database: Int
    public var clientName: String?
    public var protocolPreference: ProtocolPreference
    public var connectTimeout: Duration

    public init(endpoint: RedisEndpoint,
                tls: RedisTLSConfiguration? = nil,
                username: String? = nil,
                password: String? = nil,
                database: Int = 0,
                clientName: String? = "Redi",
                protocolPreference: ProtocolPreference = .resp3,
                connectTimeout: Duration = .seconds(10)) {
        self.endpoint = endpoint
        self.tls = tls
        self.username = username
        self.password = password
        self.database = database
        self.clientName = clientName
        self.protocolPreference = protocolPreference
        self.connectTimeout = connectTimeout
    }
}

/// Errors raised by the client (as opposed to error replies from the server, which are values).
public enum RedisClientError: Error, Sendable, Hashable, CustomStringConvertible {
    case connectTimeout(RedisEndpoint)
    case connectionFailed(String)
    case connectionClosed
    case authenticationFailed(String)
    case handshakeFailed(String)
    case protocolViolation(String)

    public var description: String {
        switch self {
        case .connectTimeout(let endpoint): "Timed out connecting to \(endpoint)"
        case .connectionFailed(let reason): "Connection failed: \(reason)"
        case .connectionClosed: "Connection closed"
        case .authenticationFailed(let reason): "Authentication failed: \(reason)"
        case .handshakeFailed(let reason): "Handshake failed: \(reason)"
        case .protocolViolation(let reason): "Protocol error: \(reason)"
        }
    }
}
