import Foundation
import RedisClient
import Testing
@testable import RediCore

@Suite("Connection profiles")
struct ConnectionProfileTests {
    @Test("Parses Redis URLs", arguments: [
        ("redis://localhost", "localhost", 6379, "", nil as String?, 0, false),
        ("rediss://alice:s3cr%40t@cache.example.com:6380/2", "cache.example.com", 6380, "alice", "s3cr@t", 2, true),
        ("redis://:pw@10.0.0.5:7000", "10.0.0.5", 7000, "", "pw", 0, false),
        ("redis://onlypassword@host", "host", 6379, "", "onlypassword", 0, false),
        ("redis://[::1]:6390/3", "::1", 6390, "", nil, 3, false),
        ("example.org:6400", "example.org", 6400, "", nil, 0, false),
        ("redis://h?db=4", "h", 6379, "", nil, 4, false),
    ])
    func parseURL(text: String, host: String, port: Int, user: String, password: String?, db: Int, tls: Bool) throws {
        let (profile, parsedPassword) = try ConnectionProfile.parse(url: text)
        #expect(profile.host == host)
        #expect(profile.port == port)
        #expect(profile.username == user)
        #expect(parsedPassword == password)
        #expect(profile.database == db)
        #expect(profile.tls.isEnabled == tls)
    }

    @Test("Rejects non-Redis URLs")
    func badURLs() {
        #expect(throws: ConnectionProfile.URLError.self) { try ConnectionProfile.parse(url: "http://example.com") }
        #expect(throws: ConnectionProfile.URLError.self) { try ConnectionProfile.parse(url: "  ") }
    }

    @Test("Shareable URL omits secrets")
    func shareableURL() {
        var profile = ConnectionProfile(host: "cache.example.com", port: 6380)
        profile.username = "alice"
        profile.database = 2
        profile.tls.isEnabled = true
        #expect(profile.url == "rediss://alice@cache.example.com:6380/2")
    }

    @Test("Decoding tolerates missing fields from older versions")
    func tolerantDecoding() throws {
        let json = #"{"profiles":[{"id":"5D4E2A35-5E5C-4E0B-9C2B-7B1F9A39B111","name":"Old","host":"h","port":1}],"version":1}"#
        let url = FileManager.default.temporaryDirectory.appending(path: "redi-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let profiles = try ProfileRepository(fileURL: url).load()
        #expect(profiles.count == 1)
        #expect(profiles[0].name == "Old")
        #expect(profiles[0].tls.verifiesCertificate)
        #expect(profiles[0].ssh.port == 22)
        #expect(profiles[0].connectTimeoutSeconds == 10)
    }

    @Test("Repository round-trips profiles atomically")
    func repositoryRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "redi-\(UUID().uuidString)/connections.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var profile = ConnectionProfile(name: "Prod", host: "prod", port: 6379)
        profile.mode = .sentinel
        profile.sentinel.masterName = "mymaster"
        profile.ssh.isEnabled = true
        profile.ssh.host = "bastion"
        profile.isProduction = true
        let repository = ProfileRepository(fileURL: url)
        try repository.save([profile])
        #expect(try repository.load() == [profile])
    }

    @Test("Imports a Redis Insight export")
    func redisInsightImport() throws {
        let json = """
        [{"host":"redis.internal","port":6380,"name":"Staging","username":"app","password":"pw","db":1,
          "connectionType":"STANDALONE","tls":true,"tlsServername":"redis.internal","verifyServerCert":false,
          "caCert":{"name":"ca.pem","certificate":"-----BEGIN CERTIFICATE-----\\nAAAA\\n-----END CERTIFICATE-----"},
          "ssh":true,"sshOptions":{"host":"bastion","port":2222,"username":"ops","password":"sshpw"}},
         {"host":"sentinel-1","port":26379,"name":"HA","connectionType":"SENTINEL","password":"sentinelpw",
          "sentinelMaster":{"name":"mymaster","password":"masterpw"}}]
        """
        let imported = try RedisInsightImport.parse(Data(json.utf8))
        #expect(imported.count == 2)
        let staging = imported[0]
        #expect(staging.profile.name == "Staging")
        #expect(staging.profile.port == 6380)
        #expect(staging.profile.database == 1)
        #expect(staging.profile.tls.isEnabled)
        #expect(staging.profile.tls.verifiesCertificate == false)
        #expect(staging.profile.tls.caCertificateName == "ca.pem")
        #expect(staging.profile.ssh.isEnabled && staging.profile.ssh.authentication == .password)
        #expect(staging.secrets.password == "pw")
        #expect(staging.secrets.sshSecret == "sshpw")
        let ha = imported[1]
        #expect(ha.profile.mode == .sentinel)
        #expect(ha.profile.sentinel.masterName == "mymaster")
        #expect(ha.secrets.password == "masterpw")
        #expect(ha.secrets.sentinelPassword == "sentinelpw")
        #expect(throws: (any Error).self) { try RedisInsightImport.parse(Data(#"{"foo":1}"#.utf8)) }
    }

    @Test("Builds session options for sentinel and SSH")
    func sessionOptions() throws {
        var profile = ConnectionProfile(host: "s1", port: 26379)
        profile.mode = .sentinel
        profile.sentinel.masterName = "mymaster"
        profile.sentinel.additionalSentinels = ["s2:26380", "s3"]
        profile.ssh.isEnabled = true
        profile.ssh.host = "bastion"
        profile.ssh.authentication = .password
        let options = try SessionFactory.options(profile: profile, secrets: ConnectionSecrets(sentinelPassword: "sp", sshSecret: "pw"))
        guard case .sentinel(let sentinel) = options.mode else { Issue.record("expected sentinel"); return }
        #expect(sentinel.sentinels == [.tcp(host: "s1", port: 26379), .tcp(host: "s2", port: 26380), .tcp(host: "s3", port: 26379)])
        #expect(sentinel.password == "sp")
        #expect(options.tunnel?.host == "bastion")
        #expect(options.tunnel?.authentication == .password)
        #expect(options.tunnel?.secret == "pw")

        profile.sentinel.masterName = ""
        #expect(throws: SessionFactory.Error.self) { try SessionFactory.options(profile: profile, secrets: .init()) }
    }

    @Test("Address parsing", arguments: [
        ("h:1", RedisEndpoint.tcp(host: "h", port: 1)), ("h", .tcp(host: "h", port: 26379)),
        ("[::1]:5", .tcp(host: "::1", port: 5)), ("::1", .tcp(host: "::1", port: 26379)),
    ])
    func addresses(text: String, endpoint: RedisEndpoint) {
        #expect(SessionFactory.parseAddress(text, defaultPort: 26379) == endpoint)
    }

    @Test("Builds a TLS client identity from PEM files", .enabled(if: DevTLS.isAvailable))
    func pemIdentity() throws {
        var profile = ConnectionProfile(host: "127.0.0.1", port: 6380)
        profile.tls.isEnabled = true
        profile.tls.caCertificatePEM = try DevTLS.read("ca.crt")
        profile.tls.clientCertificatePEM = try DevTLS.read("client.crt")
        let tls = try #require(try SessionFactory.tlsConfiguration(profile: profile, secrets: ConnectionSecrets(tlsClientKey: DevTLS.read("client.key"))))
        #expect(tls.clientIdentity != nil)
        guard case .customRoots(let roots) = tls.verification else { Issue.record("expected custom roots"); return }
        #expect(roots.count == 1)

        // A key that doesn't belong to the certificate is rejected.
        #expect(throws: SessionFactory.Error.self) {
            try SessionFactory.tlsConfiguration(profile: profile, secrets: ConnectionSecrets(tlsClientKey: DevTLS.read("server.key")))
        }
    }
}

enum DevTLS {
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: ".dev-redis/tls")
    }
    static var isAvailable: Bool { FileManager.default.fileExists(atPath: directory.appending(path: "client.key").path) }
    static func read(_ name: String) throws -> String { try String(contentsOf: directory.appending(path: name), encoding: .utf8) }
}
