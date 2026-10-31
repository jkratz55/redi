import Foundation
import RedisClient

/// A saved Redis deployment. Secrets (passwords, passphrases, TLS private keys) aren't stored
/// here. They live in a `SecretStore`, keyed by the profile's `id`.
///
/// Decoding tolerates missing keys, so profiles saved by older versions keep loading as fields are added.
public struct ConnectionProfile: Identifiable, Hashable, Codable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case standalone, cluster, sentinel
    }

    public enum ColorTag: String, Codable, CaseIterable, Sendable {
        case none, red, orange, yellow, green, blue, purple, gray
    }

    public struct TLS: Hashable, Codable, Sendable {
        public var isEnabled = false
        /// SNI / hostname-verification override. Empty uses the host.
        public var serverName = ""
        public var caCertificatePEM: String?
        public var caCertificateName: String?
        public var clientCertificatePEM: String?
        public var clientCertificateName: String?
        /// File name of the client key; its contents are a secret (`.tlsClientKey`).
        public var clientKeyName: String?
        public var verifiesCertificate = true
        public var verifiesHostname = true

        public init() {}

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
            serverName = try c.decodeIfPresent(String.self, forKey: .serverName) ?? ""
            caCertificatePEM = try c.decodeIfPresent(String.self, forKey: .caCertificatePEM)
            caCertificateName = try c.decodeIfPresent(String.self, forKey: .caCertificateName)
            clientCertificatePEM = try c.decodeIfPresent(String.self, forKey: .clientCertificatePEM)
            clientCertificateName = try c.decodeIfPresent(String.self, forKey: .clientCertificateName)
            clientKeyName = try c.decodeIfPresent(String.self, forKey: .clientKeyName)
            verifiesCertificate = try c.decodeIfPresent(Bool.self, forKey: .verifiesCertificate) ?? true
            verifiesHostname = try c.decodeIfPresent(Bool.self, forKey: .verifiesHostname) ?? true
        }
    }

    public struct SSH: Hashable, Codable, Sendable {
        public enum Authentication: String, Codable, CaseIterable, Sendable {
            case agent, privateKey, password
        }

        public var isEnabled = false
        public var host = ""
        public var port = 22
        public var username = ""
        public var authentication: Authentication = .agent
        public var privateKeyPath = ""

        public init() {}

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
            host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
            port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
            username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
            authentication = try c.decodeIfPresent(Authentication.self, forKey: .authentication) ?? .agent
            privateKeyPath = try c.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
        }
    }

    public struct Sentinel: Hashable, Codable, Sendable {
        public var masterName = ""
        /// Extra sentinels as `host:port`, tried after the profile's host/port.
        public var additionalSentinels: [String] = []
        /// Credentials for the sentinels themselves (the password is the `.sentinelPassword` secret).
        public var username = ""

        public init() {}

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            masterName = try c.decodeIfPresent(String.self, forKey: .masterName) ?? ""
            additionalSentinels = try c.decodeIfPresent([String].self, forKey: .additionalSentinels) ?? []
            username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        }
    }

    public var id = UUID()
    public var name = ""
    public var colorTag: ColorTag = .none
    public var mode: Mode = .standalone
    public var host = "127.0.0.1"
    public var port = 6379
    public var username = ""
    public var database = 0
    public var tls = TLS()
    public var ssh = SSH()
    public var sentinel = Sentinel()
    public var connectTimeoutSeconds = 10
    public var forcesRESP2 = false
    public var isReadOnly = false
    public var isProduction = false
    /// Namespace delimiter for the tree view; `nil` uses the app setting.
    public var keyDelimiter: String?
    public var createdAt = Date()
    public var lastConnectedAt: Date?

    public init(name: String = "", host: String = "127.0.0.1", port: Int = 6379) {
        self.name = name
        self.host = host
        self.port = port
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        colorTag = try c.decodeIfPresent(ColorTag.self, forKey: .colorTag) ?? .none
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .standalone
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 6379
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        database = try c.decodeIfPresent(Int.self, forKey: .database) ?? 0
        tls = try c.decodeIfPresent(TLS.self, forKey: .tls) ?? TLS()
        ssh = try c.decodeIfPresent(SSH.self, forKey: .ssh) ?? SSH()
        sentinel = try c.decodeIfPresent(Sentinel.self, forKey: .sentinel) ?? Sentinel()
        connectTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .connectTimeoutSeconds) ?? 10
        forcesRESP2 = try c.decodeIfPresent(Bool.self, forKey: .forcesRESP2) ?? false
        isReadOnly = try c.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
        isProduction = try c.decodeIfPresent(Bool.self, forKey: .isProduction) ?? false
        keyDelimiter = try c.decodeIfPresent(String.self, forKey: .keyDelimiter)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastConnectedAt = try c.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }

    /// `host:port`, bracketing IPv6.
    public var address: String { RedisEndpoint.tcp(host: host, port: port).description }

    /// Display name, falling back to the address.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? address : trimmed
    }

    /// A shareable URL without secrets, e.g. `rediss://alice@cache.example.com:6380/2`.
    public var url: String {
        var components = URLComponents()
        components.scheme = tls.isEnabled ? "rediss" : "redis"
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port
        if !username.isEmpty { components.user = username }
        if database != 0 { components.path = "/\(database)" }
        return components.string ?? "\(components.scheme ?? "redis")://\(address)"
    }
}

// MARK: - URL parsing

extension ConnectionProfile {
    public enum URLError: Error, Sendable, Hashable, CustomStringConvertible {
        case invalid(String)
        case unsupportedScheme(String)

        public var description: String {
            switch self {
            case .invalid(let text): "“\(text)” isn't a Redis URL."
            case .unsupportedScheme(let scheme): "Unsupported URL scheme “\(scheme)”. Use redis:// or rediss://."
            }
        }
    }

    /// Parses `redis://[user[:password]@]host[:port][/db]`, `rediss://…` (TLS), or a bare `host[:port]`.
    /// Returns the profile and the password (which belongs in the secret store).
    public static func parse(url text: String) throws(URLError) -> (profile: ConnectionProfile, password: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalid(text) }
        let withScheme = trimmed.contains("://") ? trimmed : "redis://\(trimmed)"
        guard let components = URLComponents(string: withScheme), let host = components.host, !host.isEmpty else {
            throw .invalid(text)
        }
        var profile = ConnectionProfile()
        switch components.scheme?.lowercased() {
        case "redis": break
        case "rediss": profile.tls.isEnabled = true
        case let other: throw .unsupportedScheme(other ?? "")
        }
        profile.host = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        profile.port = components.port ?? 6379
        var password = components.password?.removingPercentEncoding
        if let user = components.user?.removingPercentEncoding, !user.isEmpty {
            // `redis://:password@host` has an empty user; `redis://password@host` is ambiguous and
            // treated as a password, as redis-cli does.
            if password == nil {
                password = user
            } else {
                profile.username = user
            }
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let database = Int(path) { profile.database = database }
        if let db = components.queryItems?.first(where: { $0.name == "db" })?.value.flatMap(Int.init) { profile.database = db }
        profile.name = profile.address
        return (profile, password?.isEmpty == true ? nil : password)
    }
}
