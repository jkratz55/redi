import Foundation
import RedisClient
import RedisWire
import Synchronization
import Testing
@testable import RediCore
@testable import RedisTestSupport

/// A scan cursor belongs to the nodes it came from. After a failover a scanner must refuse to go on
/// rather than keep reading the demoted (or offline) primary.
@Suite("Scanner after a topology change")
struct ScannerTopologyTests {
    @Test(.timeLimit(.minutes(1)))
    func scannerStopsAfterSentinelFailover() async throws {
        let transports = Mutex<[(RedisEndpoint, ScriptedTransport)]>([])
        let primary = Mutex("old-primary")
        let session = RedisSession(
            configuration: .init(endpoint: .tcp(host: "sentinel", port: 26379)),
            options: .init(mode: .sentinel(.init(masterName: "master", sentinels: [.tcp(host: "sentinel", port: 26379)]))),
            transportFactory: { config in
                let base = ScriptedTransport.minimalServer()
                let transport = ScriptedTransport { arguments in
                    if arguments.first == "SENTINEL" { return .array([.bulkString(Array(primary.withLock { $0 }.utf8)), "6379"]) }
                    if arguments.first == "SUBSCRIBE" { return .push(["subscribe", "+switch-master", 1]) }
                    if arguments.first == "SCAN" { return .array(["0", .array(["k"])]) }
                    if arguments.first == "DBSIZE" { return 1 }
                    return base(arguments)
                }
                transports.withLock { $0.append((config.endpoint, transport)) }
                return transport
            })
        try await session.open()
        let old = await KeyScanner(session: session)
        #expect(try await old.databaseSize() == 1)

        var watcher: ScriptedTransport?
        while watcher == nil {
            watcher = transports.withLock { $0.map(\.1).first { $0.receivedCommands.contains(["SUBSCRIBE", "+switch-master"]) } }
            try await Task.sleep(for: .milliseconds(5))
        }
        primary.withLock { $0 = "new-primary" }
        try #require(watcher).inject(.push(["message", "+switch-master", "master old-primary 6379 new-primary 6379"]))
        while await session.primaryEndpoint.host != "new-primary" { try await Task.sleep(for: .milliseconds(5)) }

        #expect(await !old.isCurrent())
        await #expect(throws: ScanError.topologyChanged) {
            _ = try await old.next(from: ScanCursor(), filter: ScanFilter(), count: 10, target: 10)
        }
        await #expect(throws: ScanError.topologyChanged) { _ = try await old.databaseSize() }
        let scansBeforeNewScanner = transports.withLock { $0.filter { $0.1.receivedCommands.contains { $0.first == "SCAN" } }.count }
        #expect(scansBeforeNewScanner == 0, "the old scanner sent nothing to the demoted primary")

        let new = await KeyScanner(session: session)
        let result = try await new.next(from: ScanCursor(), filter: ScanFilter(), count: 10, target: 10)
        #expect(result.keys == [Array("k".utf8)])
        let scanned = transports.withLock { $0.filter { $0.1.receivedCommands.contains { $0.first == "SCAN" } }.map(\.0) }
        #expect(scanned == [.tcp(host: "new-primary", port: 6379)])
        await session.close()
    }

    @Test func refusedDatabaseSizeThrowsInsteadOfCountingZero() async throws {
        let session = RedisSession(configuration: .init(endpoint: .tcp(host: "scripted", port: 6379)), transportFactory: { _ in
            let base = ScriptedTransport.minimalServer()
            return ScriptedTransport { arguments in
                if arguments.first == "DBSIZE" { return .error(RedisServerError("NOPERM User review has no permissions to run the 'dbsize' command")) }
                return base(arguments)
            }
        })
        try await session.open()
        let scanner = await KeyScanner(session: session)
        await #expect(throws: RedisServerError.self) { _ = try await scanner.databaseSize() }
        await session.close()
    }
}
