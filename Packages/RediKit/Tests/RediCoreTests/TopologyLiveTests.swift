import Foundation
import RedisClient
import RedisWire
import Testing
@testable import RediCore

/// Against `Scripts/dev-redis.sh cluster start` (127.0.0.1:30001-30006). Skipped when not running.
@Suite("Live cluster", .enabled(if: LivePorts.isListening(30001)), .serialized)
struct ClusterLiveTests {
    private func session(mode: RedisSession.Mode = .cluster) -> RedisSession {
        RedisSession(configuration: RedisConnectionConfiguration(endpoint: .tcp(host: "127.0.0.1", port: 30001)),
                     options: RedisSession.Options(mode: mode))
    }

    @Test("Discovers the topology and routes keys to their owners")
    func routing() async throws {
        let session = session()
        let hello = try await session.open()
        #expect(hello.mode == .cluster)
        let topology = try #require(await session.topology)
        #expect(topology.primaries.count == 3)
        #expect(topology.coversAllSlots)

        // Keys spread over all three primaries; each SET must land on its owner or it'd get MOVED.
        let keys = (0..<200).map { "redi:test:route:\($0)" }
        let sets = keys.map { RedisCommand("SET", $0, "v-\($0)") }
        let replies = try await session.pipeline(sets)
        #expect(replies.allSatisfy { $0 == .simpleString("OK") })
        for key in keys.prefix(20) {
            #expect(try await session.send(RedisCommand("GET", key)).string == "v-\(key)")
        }
        let gets = try await session.pipeline(keys.map { RedisCommand("GET", $0) })
        #expect(gets.map { $0.string ?? "" } == keys.map { "v-\($0)" })
        _ = try await session.pipeline(keys.map { RedisCommand("DEL", $0) })
        await session.close()
    }

    @Test("Follows MOVED when sent to the wrong node")
    func followsMoved() async throws {
        let session = session()
        try await session.open()
        let topology = try #require(await session.topology)
        let key = "redi:test:moved"
        let owner = try #require(topology.primary(forSlot: HashSlot.slot(for: key)))
        let wrong = try #require(topology.primaries.first { $0.id != owner.id })
        try await session.execute(RedisCommand("SET", key, "here"))
        #expect(try await session.send(RedisCommand("GET", key), target: .node(wrong.endpoint)).string == "here")
        try await session.execute(RedisCommand("DEL", key))
        await session.close()
    }

    @Test("Movable-key commands route via COMMAND GETKEYS")
    func movableKeys() async throws {
        let session = session()
        try await session.open()
        let reply = try await session.send(RedisCommand("EVAL", "return redis.call('SET', KEYS[1], ARGV[1])", 1, "redi:test:eval", "x"))
        #expect(reply == .simpleString("OK"))
        try await session.execute(RedisCommand("DEL", "redi:test:eval"))
        await session.close()
    }

    @Test("Fans out keyless commands to every primary")
    func fanOut() async throws {
        let session = session()
        try await session.open()
        let replies = try await session.fanOut(RedisCommand("PING"))
        #expect(replies.count == 3)
        #expect(replies.allSatisfy { $0.reply == .simpleString("PONG") })
        let map = try await session.send(RedisCommand("DBSIZE"), target: .allPrimaries)
        #expect(map.pairs?.count == 3)
        await session.close()
    }

    @Test("A standalone profile pointed at a cluster switches to cluster routing")
    func autodetect() async throws {
        let session = session(mode: .standalone)
        try await session.open()
        #expect(await session.isCluster)
        await session.close()
    }
}

/// Against `Scripts/dev-redis.sh sentinel start` (sentinels 26379-26381, master "redi-primary").
@Suite("Live sentinel", .enabled(if: LivePorts.isListening(26379)), .serialized)
struct SentinelLiveTests {
    private func sentinelSession() -> RedisSession {
        RedisSession(configuration: RedisConnectionConfiguration(endpoint: .tcp(host: "127.0.0.1", port: 26379)),
                     options: RedisSession.Options(mode: .sentinel(.init(masterName: "redi-primary", sentinels: [
                         .tcp(host: "127.0.0.1", port: 26379), .tcp(host: "127.0.0.1", port: 26380), .tcp(host: "127.0.0.1", port: 26381),
                     ]))))
    }

    @Test("Lists masters and resolves the primary")
    func resolve() async throws {
        let masters = try await Sentinel.masters(sentinel: RedisConnectionConfiguration(endpoint: .tcp(host: "127.0.0.1", port: 26379)))
        #expect(masters.contains { $0.name == "redi-primary" })

        let session = sentinelSession()
        let hello = try await session.open()
        #expect(hello.role == "master")
        let primary = await session.primaryEndpoint
        #expect([6390, 6391].contains(primary.port ?? 0))
        try await session.execute(RedisCommand("SET", "redi:test:sentinel", "1"))
        #expect(try await session.send(RedisCommand("GET", "redi:test:sentinel")).string == "1")
        await session.close()
    }

    @Test("Follows a failover to the new primary", .timeLimit(.minutes(1)))
    func failover() async throws {
        let session = sentinelSession()
        try await session.open()
        let before = await session.primaryEndpoint
        // Watchers subscribe asynchronously; give the subscription a moment.
        try await Task.sleep(for: .milliseconds(500))
        var events = session.events.makeAsyncIterator()

        let sentinel = try await RedisConnection.connect(RedisConnectionConfiguration(endpoint: .tcp(host: "127.0.0.1", port: 26379)))
        try await sentinel.execute(RedisCommand("SENTINEL", "FAILOVER", "redi-primary"))
        await sentinel.close()

        var moved: RedisEndpoint?
        while let event = await events.next() {
            if case .failover(let endpoint) = event { moved = endpoint; break }
        }
        #expect(moved != nil && moved != before)
        #expect(await session.primaryEndpoint == moved)
        // The new primary needs a moment to accept writes after promotion.
        var wrote = false
        for _ in 0..<40 where !wrote {
            if (try? await session.execute(RedisCommand("SET", "redi:test:failover", "ok"))) != nil { wrote = true } else {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        #expect(wrote)
        await session.close()
    }
}

enum LivePorts {
    static func isListening(_ port: Int) -> Bool {
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
