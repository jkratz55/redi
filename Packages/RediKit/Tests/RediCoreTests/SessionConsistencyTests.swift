import Foundation
import RedisClient
import RedisWire
import Synchronization
import Testing
@testable import RediCore
@testable import RedisTestSupport

/// Database switches and transactions: one session must never serve one role from one database
/// while another runs in a different one, and a transaction's commands must never run outside it.
@Suite("Session consistency")
struct SessionConsistencyTests {
    /// Hands out a scripted transport per connection; `handler(index)` builds each one's server.
    final class Pool: Sendable {
        let transports = Mutex<[ScriptedTransport]>([])
        let handler: @Sendable (Int) -> ScriptedTransport.Handler

        init(handler: @escaping @Sendable (Int) -> ScriptedTransport.Handler = { _ in ScriptedTransport.minimalServer() }) {
            self.handler = handler
        }

        var factory: RedisTransportFactory {
            { [self] _ in
                transports.withLock { transports in
                    let transport = ScriptedTransport(handler: handler(transports.count))
                    transports.append(transport)
                    return transport
                }
            }
        }

        var count: Int { transports.withLock { $0.count } }
        func transport(_ index: Int) -> ScriptedTransport { transports.withLock { $0[index] } }
        func received(_ command: [String]) -> Bool {
            transports.withLock { $0.contains { $0.receivedCommands.contains(command) } }
        }
    }

    private func makeSession(_ pool: Pool) -> RedisSession {
        RedisSession(configuration: RedisConnectionConfiguration(endpoint: .tcp(host: "scripted", port: 6379)),
                     transportFactory: pool.factory)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("Timed out waiting"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// `minimalServer` plus Redis-like MULTI/EXEC/DISCARD/WATCH on this one connection.
    static func transactionalServer() -> ScriptedTransport.Handler {
        let base = ScriptedTransport.minimalServer()
        let queue = Mutex<[[String]]?>(nil)
        return { arguments in
            switch arguments.first?.uppercased() {
            case "MULTI":
                return queue.withLock { queue in
                    guard queue == nil else { return .error(RedisServerError("ERR MULTI calls can not be nested")) }
                    queue = []
                    return .simpleString("OK")
                }
            case "EXEC":
                guard let queued = queue.withLock({ queue in defer { queue = nil }; return queue }) else {
                    return .error(RedisServerError("ERR EXEC without MULTI"))
                }
                return .array(queued.map { base($0) ?? .null })
            case "DISCARD":
                let wasQueued = queue.withLock { queue in defer { queue = nil }; return queue != nil }
                return wasQueued ? .simpleString("OK") : .error(RedisServerError("ERR DISCARD without MULTI"))
            case "WATCH", "UNWATCH":
                return .simpleString("OK")
            default:
                let queued = queue.withLock { queue in
                    guard queue != nil else { return false }
                    queue?.append(arguments)
                    return true
                }
                return queued ? .simpleString("QUEUED") : base(arguments)
            }
        }
    }

    private static let helloReply = ScriptedTransport.minimalServer()(["HELLO", "3"])!

    // MARK: - Database switches

    @Test("A command issued during a switch waits and runs in the new database")
    func commandDuringSwitch() async throws {
        // The command connection holds its SELECT reply until the test releases it.
        let pool = Pool { index in
            let base = ScriptedTransport.minimalServer()
            return { arguments in index == 0 && arguments.first == "SELECT" ? nil : base(arguments) }
        }
        let session = makeSession(pool)
        try await session.open()
        let select = Task { try await session.select(database: 1) }
        try await waitFor { pool.transport(0).receivedCommands.contains(["SELECT", "1"]) }

        let scan = Task { try await session.send(RedisCommand("PING"), role: .scan) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(pool.count == 1, "the scan connection waits for the switch instead of opening in db0")

        pool.transport(0).inject(.simpleString("OK"))
        try await select.value
        #expect(try await scan.value == .simpleString("PONG"))
        #expect(await session.database == 1)
        let commands = pool.transport(1).receivedCommands
        let selected = try #require(commands.firstIndex(of: ["SELECT", "1"]), "the scan connection is in db1")
        #expect(selected < commands.lastIndex(of: ["PING"])!)
        await session.close()
    }

    @Test("A connection that was opening during a switch catches up before its first command")
    func connectionOpeningDuringSwitch() async throws {
        // The scan connection's handshake is held, so it's mid-connect (configured for db0) during the switch.
        let pool = Pool { index in
            let base = ScriptedTransport.minimalServer()
            return { arguments in index == 1 && arguments.first == "HELLO" ? nil : base(arguments) }
        }
        let session = makeSession(pool)
        try await session.open()
        let scan = Task { try await session.send(RedisCommand("PING"), role: .scan) }
        try await waitFor { pool.count == 2 && pool.transport(1).receivedCommands.contains { $0.first == "HELLO" } }

        try await session.select(database: 1)
        pool.transport(1).inject(Self.helloReply)
        #expect(try await scan.value == .simpleString("PONG"))
        let commands = pool.transport(1).receivedCommands.filter { $0.first != "HELLO" }
        #expect(commands == [["SELECT", "1"], ["PING"]])
        await session.close()
    }

    @Test("An open connection of another role switches before its next command")
    func openRoleCatchesUp() async throws {
        let pool = Pool()
        let session = makeSession(pool)
        _ = try await session.send(RedisCommand("PING"), role: .scan)
        try await session.select(database: 5)
        #expect(pool.transport(0).receivedCommands.last == ["SELECT", "5"], "validated on the command connection")
        _ = try await session.send(RedisCommand("PING"), role: .scan)
        #expect(pool.transport(1).receivedCommands.suffix(2) == [["SELECT", "5"], ["PING"]])
        // Already in db5: no second SELECT.
        _ = try await session.send(RedisCommand("PING"), role: .scan)
        #expect(pool.transport(1).receivedCommands.filter { $0.first == "SELECT" }.count == 1)
        await session.close()
    }

    @Test("A refused switch changes nothing")
    func refusedSwitch() async throws {
        let pool = Pool { _ in
            let base = ScriptedTransport.minimalServer()
            return { arguments in
                arguments == ["SELECT", "99"] ? .error(RedisServerError("ERR DB index is out of range")) : base(arguments)
            }
        }
        let session = makeSession(pool)
        _ = try await session.send(RedisCommand("PING"), role: .scan)
        await #expect(throws: RedisServerError.self) { try await session.select(database: 99) }
        #expect(await session.database == 0)
        _ = try await session.send(RedisCommand("PING"), role: .scan)
        #expect(!pool.transport(1).receivedCommands.contains { $0.first == "SELECT" })
        await session.close()
    }

    @Test("Overlapping switches apply one at a time, in order")
    func overlappingSwitches() async throws {
        let pool = Pool { index in
            let base = ScriptedTransport.minimalServer()
            return { arguments in index == 0 && arguments.first == "SELECT" ? nil : base(arguments) }
        }
        let session = makeSession(pool)
        try await session.open()
        let first = Task { try await session.select(database: 1) }
        try await waitFor { pool.transport(0).receivedCommands.contains(["SELECT", "1"]) }
        let second = Task { try await session.select(database: 2) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!pool.transport(0).receivedCommands.contains(["SELECT", "2"]), "the second switch waits for the first")

        pool.transport(0).inject(.simpleString("OK"))
        try await first.value
        try await waitFor { pool.transport(0).receivedCommands.contains(["SELECT", "2"]) }
        pool.transport(0).inject(.simpleString("OK"))
        try await second.value
        #expect(await session.database == 2)
        _ = try await session.send(RedisCommand("PING"), role: .scan)
        #expect(pool.transport(1).receivedCommands.contains(["SELECT", "2"]))
        await session.close()
    }

    @Test("A connection inside MULTI switches only after EXEC")
    func switchWaitsForMulti() async throws {
        let pool = Pool { _ in Self.transactionalServer() }
        let session = makeSession(pool)
        try await session.open()
        #expect(try await session.send(RedisCommand("MULTI"), role: .cli) == .simpleString("OK"))
        try await session.select(database: 3)
        #expect(try await session.send(RedisCommand("SET", "k", "v"), role: .cli) == .simpleString("QUEUED"))
        let cli = pool.transport(1)
        #expect(!cli.receivedCommands.contains { $0.first == "SELECT" }, "SELECT inside MULTI would only be queued")
        #expect(try await session.send(RedisCommand("EXEC"), role: .cli).array?.count == 1)
        _ = try await session.send(RedisCommand("PING"), role: .cli)
        #expect(cli.receivedCommands.suffix(2) == [["SELECT", "3"], ["PING"]])
        await session.close()
    }

    // MARK: - Transactions

    @Test("A dropped connection fails the transaction instead of running commands outside it")
    func droppedMulti() async throws {
        let pool = Pool { _ in Self.transactionalServer() }
        let session = makeSession(pool)
        try await session.open()
        _ = try await session.send(RedisCommand("MULTI"), role: .cli)
        #expect(try await session.send(RedisCommand("SET", "a", "1"), role: .cli) == .simpleString("QUEUED"))
        pool.transport(1).close()
        try await Task.sleep(for: .milliseconds(50))

        await #expect(throws: RedisSession.SessionError.transactionLost) {
            _ = try await session.send(RedisCommand("SET", "b", "2"), role: .cli)
        }
        #expect(!pool.received(["SET", "b", "2"]), "nothing ran untransacted")
        // The failure is reported once; afterwards the role works normally again.
        #expect(try await session.send(RedisCommand("SET", "b", "2"), role: .cli) == .simpleString("OK"))
        await session.close()
    }

    @Test("A dropped WATCH is reported rather than silently losing the optimistic lock")
    func droppedWatch() async throws {
        let pool = Pool { _ in Self.transactionalServer() }
        let session = makeSession(pool)
        try await session.open()
        _ = try await session.send(RedisCommand("WATCH", "a"), role: .workbench)
        pool.transport(1).close()
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: RedisSession.SessionError.transactionLost) {
            _ = try await session.send(RedisCommand("MULTI"), role: .workbench)
        }
        await session.close()
    }

    @Test("Releasing a role deliberately starts it fresh")
    func releaseClearsTransaction() async throws {
        let pool = Pool { _ in Self.transactionalServer() }
        let session = makeSession(pool)
        try await session.open()
        _ = try await session.send(RedisCommand("MULTI"), role: .cli)
        await session.release(.cli)
        #expect(try await session.send(RedisCommand("SET", "a", "1"), role: .cli) == .simpleString("OK"))
        await session.close()
    }

    @Test("Transactions are tracked across pipelines and single commands")
    func pipelinedTransactions() async throws {
        let pool = Pool { _ in Self.transactionalServer() }
        let session = makeSession(pool)
        try await session.open()
        let complete = try await session.pipeline([RedisCommand("MULTI"), RedisCommand("SET", "a", "1"), RedisCommand("EXEC")], role: .workbench)
        #expect(complete == [.simpleString("OK"), .simpleString("QUEUED"), .array([.simpleString("OK")])])

        // Left open by one batch, finished by a single command on the same connection.
        let open = try await session.pipeline([RedisCommand("MULTI"), RedisCommand("SET", "b", "2")], role: .workbench)
        #expect(open == [.simpleString("OK"), .simpleString("QUEUED")])
        #expect(try await session.send(RedisCommand("EXEC"), role: .workbench) == .array([.simpleString("OK")]))
        #expect(pool.count == 2, "one workbench connection throughout")
        await session.close()
    }

    @Test("EXEC or DISCARD outside MULTI keeps a WATCH in place")
    func execWithoutMultiKeepsWatch() async throws {
        let pool = Pool { _ in Self.transactionalServer() }
        let session = makeSession(pool)
        try await session.open()
        _ = try await session.send(RedisCommand("WATCH", "a"), role: .cli)
        #expect(try await session.send(RedisCommand("EXEC"), role: .cli).serverError != nil)
        pool.transport(1).close()
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: RedisSession.SessionError.transactionLost, "the WATCH was still being tracked") {
            _ = try await session.send(RedisCommand("MULTI"), role: .cli)
        }
        await session.close()
    }
}
