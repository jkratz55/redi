import Foundation
import RedisClient
import RedisWire
import Testing
@testable import RediCore

/// Against the compose bastion (`docker compose -f Scripts/docker-compose.yml up -d ssh-bastion redis-private`):
/// SSH on 127.0.0.1:2222 (redi/redi) reaching `redis-private:6379` (password "tunnel"), which
/// isn't published to the host.
@Suite("Live SSH tunnel", .enabled(if: LivePorts.isListening(2222)), .serialized)
struct SSHLiveTests {
    private let knownHosts = FileManager.default.temporaryDirectory.appending(path: "redi-known-hosts-\(UUID().uuidString)").path

    private func tunnelConfiguration(password: String = "redi") -> SSHTunnel.Configuration {
        SSHTunnel.Configuration(host: "127.0.0.1", port: 2222, username: "redi", authentication: .password,
                                secret: password, connectTimeout: .seconds(10), knownHostsFile: knownHosts)
    }

    @Test("Forwards to a server only reachable from the bastion")
    func forward() async throws {
        let tunnel = try await SSHTunnel.open(tunnelConfiguration())
        defer { tunnel.close() }
        let endpoint = try await tunnel.forward(to: "redis-private", port: 6379)
        guard case .unix = endpoint else { Issue.record("expected a unix socket endpoint"); return }
        // Forwards are cached per target.
        #expect(try await tunnel.forward(to: "redis-private", port: 6379) == endpoint)

        let connection = try await RedisConnection.connect(RedisConnectionConfiguration(endpoint: endpoint, password: "tunnel"))
        #expect(try await connection.send(RedisCommand("PING")) == .simpleString("PONG"))
        await connection.close()
    }

    @Test("Wrong SSH password fails with ssh's message")
    func wrongPassword() async throws {
        do {
            _ = try await SSHTunnel.open(tunnelConfiguration(password: "nope"))
            Issue.record("expected failure")
        } catch let error as SSHTunnel.Error {
            guard case .connectionFailed(let message) = error else { Issue.record("unexpected \(error)"); return }
            #expect(message.localizedCaseInsensitiveContains("permission denied"))
        }
    }

    @Test("A session routes every role through the tunnel and closes it")
    func session() async throws {
        var options = RedisSession.Options()
        options.tunnel = tunnelConfiguration()
        let session = RedisSession(configuration: RedisConnectionConfiguration(endpoint: .tcp(host: "redis-private", port: 6379), password: "tunnel"),
                                   options: options)
        let hello = try await session.open()
        #expect(hello.version >= ServerVersion(7))
        try await session.execute(RedisCommand("SET", "redi:ssh", "ok"))
        #expect(try await session.send(RedisCommand("GET", "redi:ssh"), role: .scan).string == "ok")
        await session.close()
    }
}
