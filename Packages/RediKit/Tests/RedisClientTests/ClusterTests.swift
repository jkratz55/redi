import Foundation
import RedisWire
import Testing
@testable import RedisClient

@Suite("Cluster primitives")
struct ClusterPrimitiveTests {
    @Test("Hash slots match Redis' CRC16 reference values")
    func hashSlots() {
        // Reference values from the Redis Cluster specification / CLUSTER KEYSLOT.
        #expect(HashSlot.crc16(Array("123456789".utf8)[...]) == 0x31C3)
        #expect(HashSlot.slot(for: "foo") == 12182)
        #expect(HashSlot.slot(for: "bar") == 5061)
        #expect(HashSlot.slot(for: "{user1000}.following") == HashSlot.slot(for: "{user1000}.followers"))
        #expect(HashSlot.slot(for: "{user1000}.following") == HashSlot.slot(for: "user1000"))
        // Empty or unterminated hashtags hash the whole key.
        #expect(HashSlot.slot(for: "foo{}{bar}") == HashSlot.slot(for: Array("foo{}{bar}".utf8)))
        #expect(HashSlot.slot(for: "foo{bar") != HashSlot.slot(for: "bar"))
    }

    @Test("Parses MOVED and ASK redirections")
    func redirects() {
        let moved = ClusterRedirect(RedisServerError("MOVED 3999 127.0.0.1:6381"), defaultHost: "seed")
        #expect(moved == ClusterRedirect(kindForTest: .moved, slot: 3999, endpoint: .tcp(host: "127.0.0.1", port: 6381)))
        let ask = ClusterRedirect(RedisServerError("ASK 12 :7002"), defaultHost: "seed")
        #expect(ask?.kind == .ask)
        #expect(ask?.endpoint == .tcp(host: "seed", port: 7002))
        #expect(ClusterRedirect(RedisServerError("ERR nope"), defaultHost: "seed") == nil)
    }

    @Test("Builds slot ownership from CLUSTER SLOTS")
    func slotsTopology() throws {
        let reply: RESPValue = [
            [0, 5460, ["10.0.0.1", 7000, "a"], ["10.0.0.4", 7003, "d"]],
            [5461, 10922, ["10.0.0.2", 7001, "b"]],
            [10923, 16383, ["", 7002, "c"]],
        ]
        let topology = try #require(ClusterTopology.parse(slots: reply, seedHost: "seed"))
        #expect(topology.primaries.count == 3)
        #expect(topology.coversAllSlots)
        #expect(topology.primary(forSlot: 0)?.endpoint == .tcp(host: "10.0.0.1", port: 7000))
        #expect(topology.primary(forSlot: 16383)?.endpoint == .tcp(host: "seed", port: 7002))
        let first = try #require(topology.primaries.first)
        #expect(topology.replicas(of: first).map(\.id) == ["d"])

        var moved = topology
        moved.assign(slot: 0, to: .tcp(host: "10.0.0.2", port: 7001))
        #expect(moved.primary(forSlot: 0)?.id == "b")
    }
}

extension ClusterRedirect {
    init(kindForTest kind: Kind, slot: Int, endpoint: RedisEndpoint) {
        let verb = kind == .moved ? "MOVED" : "ASK"
        self.init(RedisServerError("\(verb) \(slot) \(endpoint)"), defaultHost: "")!
    }
}
