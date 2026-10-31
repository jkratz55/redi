import Foundation
import RedisClient

/// Turns a profile plus its secrets into a configured `RedisSession`.
public enum SessionFactory {
    public enum Error: Swift.Error, Sendable, CustomStringConvertible {
        case missingSentinelMaster
        case invalidSentinelAddress(String)
        case tls(String)
        case missingSSHHost

        public var description: String {
            switch self {
            case .missingSentinelMaster: "Enter the name of the Sentinel master."
            case .invalidSentinelAddress(let text): "“\(text)” isn't a valid sentinel address (host:port)."
            case .tls(let reason): reason
            case .missingSSHHost: "Enter the SSH host."
            }
        }
    }

    public static func makeSession(profile: ConnectionProfile, secrets: ConnectionSecrets,
                                   transportFactory: @escaping RedisTransportFactory = RedisConnection.defaultTransportFactory) throws -> RedisSession {
        try RedisSession(configuration: configuration(profile: profile, secrets: secrets),
                         options: options(profile: profile, secrets: secrets),
                         transportFactory: transportFactory)
    }

    public static func configuration(profile: ConnectionProfile, secrets: ConnectionSecrets) throws -> RedisConnectionConfiguration {
        RedisConnectionConfiguration(
            endpoint: .tcp(host: profile.host, port: profile.port),
            tls: try tlsConfiguration(profile: profile, secrets: secrets),
            username: profile.username.isEmpty ? nil : profile.username,
            password: secrets.password,
            database: profile.mode == .cluster ? 0 : profile.database,
            clientName: "Redi",
            protocolPreference: profile.forcesRESP2 ? .resp2 : .resp3,
            connectTimeout: .seconds(max(1, profile.connectTimeoutSeconds)))
    }

    public static func options(profile: ConnectionProfile, secrets: ConnectionSecrets) throws -> RedisSession.Options {
        var options = RedisSession.Options(isReadOnly: profile.isReadOnly)
        switch profile.mode {
        case .standalone:
            options.mode = .standalone
        case .cluster:
            options.mode = .cluster
        case .sentinel:
            let name = profile.sentinel.masterName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw Error.missingSentinelMaster }
            var sentinels: [RedisEndpoint] = [.tcp(host: profile.host, port: profile.port)]
            for text in profile.sentinel.additionalSentinels where !text.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let endpoint = parseAddress(text, defaultPort: 26379) else { throw Error.invalidSentinelAddress(text) }
                sentinels.append(endpoint)
            }
            options.mode = .sentinel(.init(masterName: name, sentinels: sentinels,
                                           username: profile.sentinel.username.isEmpty ? nil : profile.sentinel.username,
                                           password: secrets.sentinelPassword))
        }
        if profile.ssh.isEnabled {
            guard !profile.ssh.host.trimmingCharacters(in: .whitespaces).isEmpty else { throw Error.missingSSHHost }
            let authentication: SSHTunnel.Authentication = switch profile.ssh.authentication {
            case .agent: .agent
            case .privateKey: .privateKey(path: profile.ssh.privateKeyPath)
            case .password: .password
            }
            options.tunnel = SSHTunnel.Configuration(
                host: profile.ssh.host, port: profile.ssh.port,
                username: profile.ssh.username.isEmpty ? nil : profile.ssh.username,
                authentication: authentication,
                secret: profile.ssh.authentication == .agent ? nil : secrets.sshSecret,
                connectTimeout: .seconds(max(5, profile.connectTimeoutSeconds)))
        }
        return options
    }

    static func tlsConfiguration(profile: ConnectionProfile, secrets: ConnectionSecrets) throws -> RedisTLSConfiguration? {
        let tls = profile.tls
        guard tls.isEnabled else { return nil }
        let verification: RedisTLSConfiguration.Verification
        if !tls.verifiesCertificate {
            verification = .none
        } else if let pem = tls.caCertificatePEM, !pem.isEmpty {
            do {
                verification = .customRoots(try CertificateLoader.certificateDER(from: Data(pem.utf8)))
            } catch {
                throw Error.tls("CA certificate: \(error)")
            }
        } else {
            verification = .system
        }
        var identity: TLSIdentity?
        if let certificate = tls.clientCertificatePEM, !certificate.isEmpty {
            guard let key = secrets.tlsClientKey, !key.isEmpty else {
                throw Error.tls("A client certificate needs its private key.")
            }
            do {
                identity = try CertificateLoader.identity(certificatePEM: certificate, privateKeyPEM: key)
            } catch {
                throw Error.tls("Client certificate: \(error)")
            }
        }
        let serverName = tls.serverName.trimmingCharacters(in: .whitespaces)
        return RedisTLSConfiguration(serverName: serverName.isEmpty ? nil : serverName,
                                     verification: verification,
                                     verifiesHostname: tls.verifiesHostname,
                                     clientIdentity: identity)
    }

    /// Parses `host:port`, `[v6]:port` or `host` (with `defaultPort`).
    public static func parseAddress(_ text: String, defaultPort: Int) -> RedisEndpoint? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : defaultPort
            return port.map { .tcp(host: host, port: $0) }
        }
        let parts = trimmed.split(separator: ":")
        switch parts.count {
        case 1: return .tcp(host: trimmed, port: defaultPort)
        case 2: return Int(parts[1]).map { .tcp(host: String(parts[0]), port: $0) }
        default: return .tcp(host: trimmed, port: defaultPort) // bare IPv6
        }
    }
}
