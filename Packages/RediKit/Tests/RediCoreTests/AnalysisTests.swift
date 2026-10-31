import Foundation
import RedisClient
import RedisWire
import Testing
@testable import RediCore
@testable import RedisTestSupport

@Suite("Analysis")
struct AnalysisTests {
    @Test("INFO snapshots compute rates from deltas")
    func snapshots() {
        let first = InfoSnapshot(info: RedisInfo(parsing: """
        # Stats\r\ninstantaneous_ops_per_sec:120\r\nkeyspace_hits:90\r\nkeyspace_misses:10\r\n# CPU\r\nused_cpu_sys:1.0\r\nused_cpu_user:1.0\r\n\
        # Memory\r\nused_memory:1048576\r\n# Keyspace\r\ndb0:keys=10,expires=2,avg_ttl=0\r\ndb3:keys=5,expires=0,avg_ttl=0\r\n
        """), previous: nil, date: Date(timeIntervalSince1970: 0))
        #expect(first.totalKeys == 15 && first.expiringKeys == 2)
        #expect(first.keyspace.map(\.database) == [0, 3])
        #expect(first.hitRatio == 0.9)
        let second = InfoSnapshot(info: RedisInfo(parsing: """
        # Stats\r\nkeyspace_hits:140\r\nkeyspace_misses:60\r\n# CPU\r\nused_cpu_sys:1.5\r\nused_cpu_user:1.0\r\n
        """), previous: first, date: Date(timeIntervalSince1970: 5))
        #expect(second.hitRatio == 0.5)
        #expect(abs((second.cpuPercent ?? 0) - 10) < 0.001)
        let combined = InfoSnapshot.combine([first, first])
        #expect(combined?.totalKeys == 30 && combined?.usedMemory == 2_097_152)
    }

    @Test("Slow log entries parse")
    func slowLog() {
        let reply: RESPValue = [[14, 1_700_000_000, 15_000, ["KEYS", "*"], "127.0.0.1:5000", "app"]]
        let entries = SlowLogEntry.parse(reply, node: "n1")
        #expect(entries.count == 1)
        #expect(entries[0].command == "KEYS *" && entries[0].durationMicroseconds == 15_000 && entries[0].clientName == "app")
    }

    @Test("Memory analysis aggregates a live keyspace", .enabled(if: RedisServerFixture.isAvailable))
    func memoryAnalysis() async throws {
        let server = try await RedisServerFixture()
        let session = RedisSession(configuration: server.configuration())
        var commands: [RedisCommand] = []
        for i in 0..<300 { commands.append(RedisCommand("SET", "cache:\(i)", String(repeating: "x", count: 50), "EX", 600)) }
        for i in 0..<50 { commands.append(RedisCommand("HSET", "user:\(i)", "name", "n", "email", "e")) }
        let items: [String] = ["queue"] + (0..<6000).map { "item\($0)" }
        commands.append(RedisCommand("RPUSH", items))
        _ = try await session.pipeline(commands)

        let analyzer = MemoryAnalyzer(session: session, delimiter: ":", sampleLimit: nil)
        let report = try await analyzer.run { _ in }
        #expect(report.scannedKeys == 351 && report.totalKeys == 351 && !report.isSample)
        #expect(Set(report.byType.map(\.type)) == ["String", "Hash", "List"])
        #expect(report.namespaces.first { $0.prefix == "cache:*" }?.keys == 300)
        #expect(report.topByLength.first?.key == "queue" && report.topByLength.first?.length == 6000)
        #expect(report.topByMemory.first?.key == "queue")
        #expect(report.ttlBuckets[1].keys == 300) // < 1 hour
        #expect(report.recommendations.contains { $0.title == "Big collections" })

        let sample = try await MemoryAnalyzer(session: session, delimiter: ":", sampleLimit: 100).run { _ in }
        #expect(sample.scannedKeys == 100 && sample.isSample)
        await session.close()
    }
}
