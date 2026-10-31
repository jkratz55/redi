import Foundation
import RedisClient
import RedisWire
import Synchronization
import Testing
@testable import RediCore
@testable import RedisTestSupport

@Suite("Redis session")
struct RedisSessionTests {
    /// Hands out a fresh scripted transport per connection and records them.
    final class TransportPool: Sendable {
        let transports = Mutex<[ScriptedTransport]>([])
        var factory: RedisTransportFactory {
            { [self] _ in
                let transport = ScriptedTransport(handler: ScriptedTransport.minimalServer())
                transports.withLock { $0.append(transport) }
                return transport
            }
        }
        var count: Int { transports.withLock { $0.count } }
        func transport(_ index: Int) -> ScriptedTransport { transports.withLock { $0[index] } }
    }

    private func makeSession(_ pool: TransportPool) -> RedisSession {
        RedisSession(configuration: RedisConnectionConfiguration(endpoint: .tcp(host: "scripted", port: 6379)),
                     transportFactory: pool.factory)
    }

    @Test("Opens one connection per role, lazily")
    func lazyRoles() async throws {
        let pool = TransportPool()
        let session = makeSession(pool)
        #expect(pool.count == 0)
        let hello = try await session.open()
        #expect(hello.version == ServerVersion(7, 2, 4))
        #expect(pool.count == 1)
        _ = try await session.send(RedisCommand("PING"))
        #expect(pool.count == 1)
        _ = try await session.send(RedisCommand("PING"), role: .scan)
        #expect(pool.count == 2)
        await session.close()
    }

    @Test("Concurrent first use of a role shares one connection attempt")
    func sharedConnect() async throws {
        let pool = TransportPool()
        let session = makeSession(pool)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try await session.send(RedisCommand("PING")) } }
            try await group.waitForAll()
        }
        #expect(pool.count == 1)
        await session.close()
    }

    @Test("A dropped connection is replaced on next use")
    func reconnects() async throws {
        let pool = TransportPool()
        let session = makeSession(pool)
        _ = try await session.send(RedisCommand("PING"))
        pool.transport(0).close()
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await session.send(RedisCommand("PING")) == .simpleString("PONG"))
        #expect(pool.count == 2)
        await session.close()
    }

    @Test("SELECT applies to open data connections and future ones")
    func selectDatabase() async throws {
        let pool = TransportPool()
        let session = makeSession(pool)
        _ = try await session.send(RedisCommand("PING"))
        try await session.select(database: 5)
        #expect(pool.transport(0).receivedCommands.last == ["SELECT", "5"])
        _ = try await session.send(RedisCommand("PING"), role: .scan)
        #expect(pool.transport(1).receivedCommands.contains(["SELECT", "5"]))
        await session.close()
    }

    @Test("A closed session rejects further use")
    func closed() async throws {
        let pool = TransportPool()
        let session = makeSession(pool)
        _ = try await session.open()
        await session.close()
        await #expect(throws: RedisClientError.connectionClosed) { _ = try await session.send(RedisCommand("PING")) }
    }
}
