import Foundation
import RedisClient
import RedisWire
import Testing
@testable import RediCore

/// Transactions against `Scripts/dev-redis.sh cluster start`. A transaction's commands must all run
/// on one connection, or DISCARD stops being able to undo them. Skipped when the cluster isn't running.
@Suite("Live cluster transactions", .enabled(if: LivePorts.isListening(30001)), .serialized)
struct ClusterTransactionLiveTests {
    private struct Fixture {
        let session: RedisSession
        let defaultNode: RedisEndpoint
        let topology: ClusterTopology

        /// A key owned by `node`, or by any node other than `excluding`.
        func key(_ label: String, on node: RedisEndpoint? = nil, excluding: RedisEndpoint? = nil) throws -> String {
            try #require((0..<500).map { "redi:test:tx:\(label):\($0)" }.first { key in
                let owner = topology.primary(forSlot: HashSlot.slot(for: key))?.endpoint
                return (node == nil || owner == node) && (excluding == nil || owner != excluding)
            })
        }

        func owner(_ key: String) -> RedisEndpoint? { topology.primary(forSlot: HashSlot.slot(for: key))?.endpoint }

        func get(_ key: String) async throws -> String? { try await session.send(RedisCommand("GET", key)).string }
    }

    private func fixture() async throws -> Fixture {
        let session = RedisSession(configuration: RedisConnectionConfiguration(endpoint: .tcp(host: "127.0.0.1", port: 30001)),
                                   options: RedisSession.Options(mode: .cluster))
        try await session.open()
        let topology = try #require(await session.topology)
        let defaultNode = try #require(topology.primaries.first?.endpoint)
        return Fixture(session: session, defaultNode: defaultNode, topology: topology)
    }

    @Test("DISCARD in a pipeline applies nothing, whichever node owns the key")
    func pipelinedDiscard() async throws {
        let f = try await fixture()
        let key = try f.key("pdiscard", excluding: f.defaultNode)
        try await f.session.execute(RedisCommand("SET", key, "original"))
        let replies = try await f.session.pipeline([RedisCommand("MULTI"), RedisCommand("SET", key, "changed"), RedisCommand("DISCARD")],
                                                   role: .workbench)
        #expect(replies[1] == .simpleString("QUEUED"))
        #expect(try await f.get(key) == "original")
        try await f.session.execute(RedisCommand("DEL", key))
        await f.session.close()
    }

    @Test("A typed MULTI moves to the node owning the first key, and DISCARD applies nothing")
    func sequentialDiscard() async throws {
        let f = try await fixture()
        let key = try f.key("sdiscard", excluding: f.defaultNode)
        try await f.session.execute(RedisCommand("SET", key, "original"))
        #expect(try await f.session.send(RedisCommand("MULTI"), role: .cli) == .simpleString("OK"))
        #expect(try await f.session.send(RedisCommand("SET", key, "changed"), role: .cli) == .simpleString("QUEUED"))
        #expect(try await f.session.send(RedisCommand("DISCARD"), role: .cli) == .simpleString("OK"))
        #expect(try await f.get(key) == "original")
        try await f.session.execute(RedisCommand("DEL", key))
        await f.session.close()
    }

    @Test("A typed transaction on another node's key commits with EXEC")
    func sequentialExec() async throws {
        let f = try await fixture()
        let key = try f.key("sexec", excluding: f.defaultNode)
        _ = try await f.session.send(RedisCommand("MULTI"), role: .cli)
        #expect(try await f.session.send(RedisCommand("SET", key, "committed"), role: .cli) == .simpleString("QUEUED"))
        #expect(try await f.session.send(RedisCommand("GET", key), role: .cli) == .simpleString("QUEUED"))
        let committed = try await f.session.send(RedisCommand("EXEC"), role: .cli)
        #expect(committed.array == [.simpleString("OK"), .bulkString(Array("committed".utf8))])
        #expect(try await f.get(key) == "committed")
        try await f.session.execute(RedisCommand("DEL", key))
        await f.session.close()
    }

    @Test("A key on a second node fails the whole transaction instead of running elsewhere")
    func secondNodeFailsTransaction() async throws {
        let f = try await fixture()
        let first = try f.key("first", excluding: f.defaultNode)
        let firstOwner: RedisEndpoint = try #require(f.owner(first))
        let second = try f.key("second", excluding: firstOwner)
        try await f.session.execute(RedisCommand("SET", first, "original"))
        try await f.session.execute(RedisCommand("SET", second, "original"))

        _ = try await f.session.send(RedisCommand("MULTI"), role: .cli)
        #expect(try await f.session.send(RedisCommand("SET", first, "changed"), role: .cli) == .simpleString("QUEUED"))
        let moved = try await f.session.send(RedisCommand("SET", second, "changed"), role: .cli)
        #expect(moved.serverError?.code == "MOVED", "redirects aren't followed inside a transaction")
        let exec = try await f.session.send(RedisCommand("EXEC"), role: .cli)
        #expect(exec.serverError?.code == "EXECABORT")
        #expect(try await f.get(first) == "original")
        #expect(try await f.get(second) == "original")
        try await f.session.execute(RedisCommand("DEL", first))
        try await f.session.execute(RedisCommand("DEL", second))
        await f.session.close()
    }

    @Test("A pipelined transaction across nodes is refused before anything is sent")
    func crossNodePipelineRefused() async throws {
        let f = try await fixture()
        let first = try f.key("pfirst")
        let firstOwner: RedisEndpoint = try #require(f.owner(first))
        let second = try f.key("psecond", excluding: firstOwner)
        // Cleared first, so a key left by an earlier failed run can't masquerade as a write.
        try await f.session.execute(RedisCommand("DEL", first))
        try await f.session.execute(RedisCommand("DEL", second))
        await #expect(throws: RedisSession.SessionError.crossNodeTransaction) {
            _ = try await f.session.pipeline([RedisCommand("MULTI"), RedisCommand("SET", first, "x"),
                                              RedisCommand("SET", second, "x"), RedisCommand("EXEC")], role: .workbench)
        }
        #expect(try await f.get(first) == nil)
        #expect(try await f.get(second) == nil)
        // Nothing is left open: the role works normally afterwards.
        #expect(try await f.session.send(RedisCommand("SET", first, "after"), role: .workbench) == .simpleString("OK"))
        try await f.session.execute(RedisCommand("DEL", first))
        await f.session.close()
    }

    @Test("WATCH on keys from different nodes is refused")
    func crossNodeWatchRefused() async throws {
        let f = try await fixture()
        let first = try f.key("wfirst")
        let firstOwner: RedisEndpoint = try #require(f.owner(first))
        let second = try f.key("wsecond", excluding: firstOwner)
        await #expect(throws: RedisSession.SessionError.crossNodeTransaction) {
            _ = try await f.session.send(RedisCommand("WATCH", first, second), role: .cli)
        }
        await f.session.close()
    }

    @Test("All Primaries can't start a transaction or fan out during one")
    func allPrimariesRefusedInTransactions() async throws {
        let f = try await fixture()
        await #expect(throws: RedisSession.SessionError.crossNodeTransaction) {
            _ = try await f.session.send(RedisCommand("MULTI"), role: .cli, target: .allPrimaries)
        }
        _ = try await f.session.send(RedisCommand("MULTI"), role: .cli)
        await #expect(throws: RedisSession.SessionError.crossNodeTransaction) {
            _ = try await f.session.send(RedisCommand("DBSIZE"), role: .cli, target: .allPrimaries)
        }
        #expect(try await f.session.send(RedisCommand("DISCARD"), role: .cli) == .simpleString("OK"))
        // Once the transaction ends, fan-out works again.
        #expect(try await f.session.send(RedisCommand("DBSIZE"), role: .cli, target: .allPrimaries).pairs?.count == 3)
        await f.session.close()
    }

    @Test("WATCH pins the transaction to the watched key's node, so a concurrent change aborts it")
    func watchAborts() async throws {
        let f = try await fixture()
        let key = try f.key("watch", excluding: f.defaultNode)
        try await f.session.execute(RedisCommand("SET", key, "original"))
        #expect(try await f.session.send(RedisCommand("WATCH", key), role: .cli) == .simpleString("OK"))
        try await f.session.execute(RedisCommand("SET", key, "someone else"))
        _ = try await f.session.send(RedisCommand("MULTI"), role: .cli)
        #expect(try await f.session.send(RedisCommand("SET", key, "mine"), role: .cli) == .simpleString("QUEUED"))
        let exec = try await f.session.send(RedisCommand("EXEC"), role: .cli)
        #expect(exec == .null, "the watched key changed, so EXEC aborts")
        #expect(try await f.get(key) == "someone else")
        try await f.session.execute(RedisCommand("DEL", key))
        await f.session.close()
    }
}
