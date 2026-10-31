import Foundation
import RedisWire
import Testing
@testable import RedisClient

/// TLS against the dev server from `Scripts/gen-tls-certs.sh` + `Scripts/dev-redis.sh tls start`
/// (TLS-only on 127.0.0.1:6380, CA-signed cert with SAN localhost/127.0.0.1). Skipped otherwise.
@Suite("Live TLS server", .enabled(if: TLSFixture.isAvailable), .serialized)
struct TLSLiveTests {
    @Test("Verifies the server against a custom CA")
    func customCA() async throws {
        let connection = try await RedisConnection.connect(TLSFixture.configuration(.customRoots(try TLSFixture.caDER())))
        #expect(try await connection.send(RedisCommand("PING")) == .simpleString("PONG"))
        #expect(await connection.hello?.protocolVersion == 3)
        await connection.close()
    }

    @Test("Rejects an untrusted certificate with system verification")
    func untrusted() async throws {
        await #expect(throws: RedisClientError.self) {
            _ = try await RedisConnection.connect(TLSFixture.configuration(.system))
        }
    }

    @Test("Skipping verification accepts the self-signed chain")
    func noVerification() async throws {
        let connection = try await RedisConnection.connect(TLSFixture.configuration(.none))
        #expect(try await connection.send(RedisCommand("PING")) == .simpleString("PONG"))
        await connection.close()
    }

    @Test("Hostname mismatch fails unless hostname verification is off")
    func hostname() async throws {
        let ca = try TLSFixture.caDER()
        var mismatched = TLSFixture.configuration(.customRoots(ca))
        mismatched.tls?.serverName = "wrong.example.com"
        await #expect(throws: RedisClientError.self) { _ = try await RedisConnection.connect(mismatched) }

        mismatched.tls?.verifiesHostname = false
        let connection = try await RedisConnection.connect(mismatched)
        #expect(try await connection.send(RedisCommand("PING")) == .simpleString("PONG"))
        await connection.close()
    }

    @Test("Presents a client identity imported from PKCS#12")
    func clientIdentity() async throws {
        let p12 = try Data(contentsOf: TLSFixture.directory.appending(path: "client.p12"))
        let identity = try CertificateLoader.identity(pkcs12: p12, password: "redi")
        var configuration = TLSFixture.configuration(.customRoots(try TLSFixture.caDER()))
        configuration.tls?.clientIdentity = identity
        let connection = try await RedisConnection.connect(configuration)
        #expect(try await connection.send(RedisCommand("PING")) == .simpleString("PONG"))
        await connection.close()
    }

    @Test("A plain connection to a TLS port fails instead of hanging")
    func plaintextToTLSPort() async throws {
        var configuration = TLSFixture.configuration(.none)
        configuration.tls = nil
        configuration.connectTimeout = .seconds(2)
        let started = ContinuousClock.now
        await #expect(throws: RedisClientError.self) { _ = try await RedisConnection.connect(configuration) }
        #expect(ContinuousClock.now - started < .seconds(3))
    }
}

enum TLSFixture {
    static let port = 6380

    static var directory: URL {
        // Tests/RedisClientTests/TLSLiveTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: ".dev-redis/tls")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: "ca.crt").path) && isListening
    }

    static func caDER() throws -> [Data] {
        try CertificateLoader.certificateDER(from: Data(contentsOf: directory.appending(path: "ca.crt")))
    }

    static func configuration(_ verification: RedisTLSConfiguration.Verification) -> RedisConnectionConfiguration {
        RedisConnectionConfiguration(endpoint: .tcp(host: "127.0.0.1", port: port),
                                     tls: RedisTLSConfiguration(verification: verification),
                                     connectTimeout: .seconds(3))
    }

    private static var isListening: Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
