import Foundation

/// Imports the JSON produced by Redis Insight's "Export" of database connections.
///
/// The format has changed across Redis Insight versions, so every field is optional and unknown
/// fields are ignored.
public enum RedisInsightImport {
    public struct Imported: Sendable {
        public var profile: ConnectionProfile
        public var secrets: ConnectionSecrets
        /// SSH private key text that must be written to a file (ssh needs a path).
        public var sshPrivateKey: String?
    }

    public enum Error: Swift.Error, Sendable, CustomStringConvertible {
        case notRedisInsightExport

        public var description: String { "The file isn't a Redis Insight connection export." }
    }

    private struct Entry: Decodable {
        struct Certificate: Decodable { var name: String?; var certificate: String?; var key: String? }
        struct SSHOptions: Decodable {
            var host: String?; var port: Int?; var username: String?
            var password: String?; var privateKey: String?; var passphrase: String?
        }
        struct SentinelMaster: Decodable { var name: String?; var username: String?; var password: String? }

        var name: String?
        var host: String?
        var port: Int?
        var username: String?
        var password: String?
        var db: Int?
        var connectionType: String?
        var tls: Bool?
        var tlsServername: String?
        var verifyServerCert: Bool?
        var caCert: Certificate?
        var clientCert: Certificate?
        var ssh: Bool?
        var sshOptions: SSHOptions?
        var sentinelMaster: SentinelMaster?
    }

    public static func parse(_ data: Data) throws -> [Imported] {
        let entries: [Entry]
        if let array = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = array
        } else if let single = try? JSONDecoder().decode(Entry.self, from: data), single.host != nil {
            entries = [single]
        } else {
            throw Error.notRedisInsightExport
        }
        let valid = entries.filter { $0.host != nil }
        guard !valid.isEmpty else { throw Error.notRedisInsightExport }
        return valid.map(convert)
    }

    private static func convert(_ entry: Entry) -> Imported {
        var profile = ConnectionProfile(name: entry.name ?? "", host: entry.host ?? "127.0.0.1", port: entry.port ?? 6379)
        var secrets = ConnectionSecrets()
        profile.username = entry.username ?? ""
        profile.database = entry.db ?? 0
        secrets.password = entry.password

        switch entry.connectionType?.uppercased() {
        case "CLUSTER": profile.mode = .cluster
        case "SENTINEL": profile.mode = .sentinel
        default: profile.mode = .standalone
        }
        if let master = entry.sentinelMaster {
            profile.sentinel.masterName = master.name ?? ""
            profile.sentinel.username = master.username ?? ""
            // Redis Insight stores the *master's* credentials under sentinelMaster and the
            // sentinel's under the top-level fields; Redi's model is the reverse.
            secrets.sentinelPassword = entry.password
            secrets.password = master.password
            let topUser = profile.username
            profile.username = master.username ?? ""
            profile.sentinel.username = topUser
        }

        if entry.tls == true {
            profile.tls.isEnabled = true
            profile.tls.serverName = entry.tlsServername ?? ""
            profile.tls.verifiesCertificate = entry.verifyServerCert ?? true
            if let ca = entry.caCert?.certificate {
                profile.tls.caCertificatePEM = ca
                profile.tls.caCertificateName = entry.caCert?.name ?? "CA certificate"
            }
            if let client = entry.clientCert, let certificate = client.certificate {
                profile.tls.clientCertificatePEM = certificate
                profile.tls.clientCertificateName = client.name ?? "Client certificate"
                profile.tls.clientKeyName = client.key == nil ? nil : (client.name ?? "Client key")
                secrets.tlsClientKey = client.key
            }
        }

        var sshKey: String?
        if entry.ssh == true, let ssh = entry.sshOptions {
            profile.ssh.isEnabled = true
            profile.ssh.host = ssh.host ?? ""
            profile.ssh.port = ssh.port ?? 22
            profile.ssh.username = ssh.username ?? ""
            if let key = ssh.privateKey, !key.isEmpty {
                profile.ssh.authentication = .privateKey
                sshKey = key
                secrets.sshSecret = ssh.passphrase
            } else if let password = ssh.password, !password.isEmpty {
                profile.ssh.authentication = .password
                secrets.sshSecret = password
            }
        }
        if profile.name.isEmpty { profile.name = profile.address }
        return Imported(profile: profile, secrets: secrets, sshPrivateKey: sshKey)
    }

    /// Writes an imported SSH key to `Application Support/Redi/SSH Keys/<id>` (mode 0600) and
    /// returns its path.
    public static func storePrivateKey(_ key: String, for profileID: UUID) throws -> String {
        let directory = RediDirectories.applicationSupport.appending(path: "SSH Keys", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: profileID.uuidString)
        var text = key
        if !text.hasSuffix("\n") { text += "\n" }
        try Data(text.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url.path
    }
}
