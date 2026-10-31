import Foundation
import RedisWire
import Testing
@testable import RedisClient
@testable import RedisTestSupport

/// Integration tests against a real `redis-server` launched per test. Skipped when no binary is found.
@Suite("Live redis-server", .enabled(if: RedisServerFixture.isAvailable), .serialized)
struct LiveServerTests {
    @Test("Connects with RESP3 and round-trips binary data")
    func resp3RoundTrip() async throws {
        let server = try await RedisServerFixture()
        let connection = try await RedisConnection.connect(server.configuration())
        let hello = try #require(await connection.hello)
        #expect(hello.protocolVersion == 3)
        #expect(hello.version >= ServerVersion(6))

        let payload: [UInt8] = (0...255).map(UInt8.init) + [13, 10, 13, 10]
        try await connection.execute(RedisCommand("SET", "bin", payload))
        #expect(try await connection.send(RedisCommand("GET", "bin")).bytes == payload)
        #expect(try await connection.send(RedisCommand("HSET", "h", "a", 1, "b", 2)) == .integer(2))
        // RESP3 returns a real map for HGETALL.
        let hash = try await connection.send(RedisCommand("HGETALL", "h"))
        guard case .map(let pairs) = hash else { Issue.record("expected map, got \(hash)"); return }
        #expect(pairs.count == 2)
        await connection.close()
    }

    @Test("Falls back to RESP2 when HELLO is disabled on the server")
    func resp2Fallback() async throws {
        let server = try await RedisServerFixture(arguments: ["--rename-command", "HELLO", ""])
        let connection = try await RedisConnection.connect(server.configuration(database: 2))
        let hello = try #require(await connection.hello)
        #expect(hello.protocolVersion == 2)
        #expect(hello.version >= ServerVersion(6))
        #expect(try await connection.send(RedisCommand("CLIENT", "GETNAME")).string == "Redi")
        try await connection.execute(RedisCommand("SET", "k", "v"))
        // Confirms SELECT 2 ran: key is in db 2 per INFO keyspace.
        let keyspace = RedisInfo(parsing: try await connection.send(RedisCommand("INFO", "keyspace")).string ?? "")
        #expect(keyspace["db2"]?.hasPrefix("keys=1") == true)
        await connection.close()
    }

    @Test("Password and ACL authentication")
    func authentication() async throws {
        let server = try await RedisServerFixture(arguments: ["--requirepass", "s3cret", "--user", "alice", "on", ">wonderland", "~*", "+@all"])
        await #expect(throws: RedisClientError.authenticationFailed("The server requires a password.")) {
            _ = try await RedisConnection.connect(server.configuration())
        }
        await #expect(throws: RedisClientError.authenticationFailed("Invalid username or password.")) {
            _ = try await RedisConnection.connect(server.configuration(password: "wrong"))
        }
        let viaDefault = try await RedisConnection.connect(server.configuration(password: "s3cret"))
        #expect(try await viaDefault.send(RedisCommand("ACL", "WHOAMI")).string == "default")
        let viaACL = try await RedisConnection.connect(server.configuration(username: "alice", password: "wonderland"))
        #expect(try await viaACL.send(RedisCommand("ACL", "WHOAMI")).string == "alice")
        await viaDefault.close()
        await viaACL.close()
    }

    @Test("Pipelines 10k commands and reads multi-MB values")
    func throughput() async throws {
        let server = try await RedisServerFixture()
        let connection = try await RedisConnection.connect(server.configuration())
        let sets = (0..<10_000).map { RedisCommand("SET", "key:\($0)", "value:\($0)") }
        let replies = try await connection.pipeline(sets)
        #expect(replies.allSatisfy { $0 == .simpleString("OK") })
        let values = try await connection.send(RedisCommand("MGET", (0..<10_000).map { "key:\($0)" }))
        #expect(values.array?.count == 10_000)
        #expect(values.array?[9_999].string == "value:9999")

        let big = [UInt8](repeating: 0x5A, count: 8 * 1024 * 1024)
        try await connection.execute(RedisCommand("SET", "big", big))
        #expect(try await connection.send(RedisCommand("GET", "big")).bytes?.count == big.count)
        await connection.close()
    }

    @Test("RESP3 pub/sub messages arrive as pushes")
    func pubSubPushes() async throws {
        let server = try await RedisServerFixture()
        let subscriber = try await RedisConnection.connect(server.configuration())
        let publisher = try await RedisConnection.connect(server.configuration())
        var pushes = subscriber.pushes.makeAsyncIterator()
        try await subscriber.sendWithoutReply(RedisCommand("SUBSCRIBE", "news"))
        #expect(await pushes.next()?.array?.first?.string == "subscribe")
        #expect(try await publisher.send(RedisCommand("PUBLISH", "news", "hello")) == .integer(1))
        let message = await pushes.next()
        #expect(message?.array?.map { $0.string ?? "" } == ["message", "news", "hello"])
        await subscriber.close()
        await publisher.close()
    }

    @Test("Detects a server-side disconnect")
    func serverDisconnect() async throws {
        let server = try await RedisServerFixture()
        let victim = try await RedisConnection.connect(server.configuration())
        let admin = try await RedisConnection.connect(server.configuration())
        let id = try #require(await victim.hello?.connectionID)
        #expect(try await admin.send(RedisCommand("CLIENT", "KILL", "ID", id)) == .integer(1))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await victim.isClosed)
        await admin.close()
    }

    @Test("Connection refused fails fast")
    func refused() async throws {
        let server = try await RedisServerFixture()
        let configuration = server.configuration()
        server.stop()
        let started = ContinuousClock.now
        await #expect(throws: RedisClientError.self) { _ = try await RedisConnection.connect(configuration) }
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}
