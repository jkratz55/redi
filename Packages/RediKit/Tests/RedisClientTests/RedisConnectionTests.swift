import Foundation
import RedisWire
import Synchronization
import Testing
@testable import RedisClient
@testable import RedisTestSupport

private func connect(_ transport: ScriptedTransport,
                     configure: (inout RedisConnectionConfiguration) -> Void = { _ in }) async throws -> RedisConnection {
    var configuration = RedisConnectionConfiguration(endpoint: .tcp(host: "scripted", port: 6379), connectTimeout: .seconds(2))
    configure(&configuration)
    return try await RedisConnection.connect(configuration, transportFactory: { _ in transport })
}

@Suite("Redis connection (scripted)")
struct RedisConnectionTests {
    @Test("RESP3 handshake reads server metadata from HELLO")
    func resp3Handshake() async throws {
        let transport = ScriptedTransport(handler: ScriptedTransport.minimalServer(version: "7.4.1"))
        let connection = try await connect(transport) { $0.password = "pw"; $0.username = "alice" }
        let hello = try #require(await connection.hello)
        #expect(hello.protocolVersion == 3)
        #expect(hello.version == ServerVersion(7, 4, 1))
        #expect(hello.mode == .standalone)
        #expect(hello.role == "master")
        #expect(transport.receivedCommands.first == ["HELLO", "3", "AUTH", "alice", "pw", "SETNAME", "Redi"])
        await connection.close()
    }

    @Test("Falls back to RESP2 when HELLO is unknown")
    func resp2Fallback() async throws {
        let transport = ScriptedTransport(encoding: .resp2, handler: ScriptedTransport.minimalServer(version: "5.0.14", supportsHello: false))
        let connection = try await connect(transport) { $0.password = "pw"; $0.database = 3 }
        let hello = try #require(await connection.hello)
        #expect(hello.protocolVersion == 2)
        #expect(hello.version == ServerVersion(5, 0, 14))
        #expect(transport.receivedCommands.map { $0.first ?? "" } == ["HELLO", "AUTH", "CLIENT", "INFO", "INFO", "SELECT"])
        #expect(transport.receivedCommands[1] == ["AUTH", "pw"])
        #expect(transport.receivedCommands.last == ["SELECT", "3"])
        await connection.close()
    }

    @Test("Authentication errors surface as authenticationFailed")
    func authenticationFailure() async throws {
        let transport = ScriptedTransport { arguments in
            arguments.first == "HELLO" ? .error(RedisServerError("WRONGPASS invalid username-password pair or user is disabled.")) : .simpleString("OK")
        }
        await #expect(throws: RedisClientError.authenticationFailed("Invalid username or password.")) {
            _ = try await connect(transport) { $0.password = "nope" }
        }
    }

    @Test("Handshake times out when the server never answers")
    func handshakeTimeout() async throws {
        let transport = ScriptedTransport { _ in nil }
        let started = ContinuousClock.now
        await #expect(throws: RedisClientError.self) {
            _ = try await connect(transport) { $0.connectTimeout = .milliseconds(200) }
        }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("Concurrent commands each get their own reply, even with tiny read chunks")
    func concurrentOrdering() async throws {
        let transport = ScriptedTransport(chunkSize: 7, handler: ScriptedTransport.minimalServer())
        let connection = try await connect(transport)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<500 {
                group.addTask {
                    let reply = try await connection.send(RedisCommand("ECHO", "value-\(index)"))
                    #expect(reply.string == "value-\(index)")
                }
            }
            try await group.waitForAll()
        }
        await connection.close()
    }

    @Test("Pipelines return replies in order, including errors as values")
    func pipelineOrder() async throws {
        let transport = ScriptedTransport(handler: ScriptedTransport.minimalServer())
        let connection = try await connect(transport)
        let replies = try await connection.pipeline([
            RedisCommand("SET", "k", "v"), RedisCommand("GET", "k"), RedisCommand("NOPE"), RedisCommand("GET", "missing"),
        ])
        #expect(replies.count == 4)
        #expect(replies[0] == .simpleString("OK"))
        #expect(replies[1].string == "v")
        #expect(replies[2].serverError?.code == "ERR")
        #expect(replies[3].isNull)
        await #expect(throws: RedisServerError.self) { try await connection.execute(RedisCommand("NOPE")) }
        await connection.close()
    }

    @Test("Push messages go to the push stream without disturbing replies")
    func pushes() async throws {
        let transport = ScriptedTransport(handler: ScriptedTransport.minimalServer())
        let connection = try await connect(transport)
        transport.inject(.push(["message", "news", "hello"]))
        #expect(try await connection.send(RedisCommand("PING")) == .simpleString("PONG"))

        var iterator = connection.pushes.makeAsyncIterator()
        #expect(await iterator.next() == .push(["message", "news", "hello"]))
        await connection.close()
        #expect(await iterator.next() == nil)
    }

    @Test("Closing fails commands that are still waiting")
    func closeFailsPending() async throws {
        let transport = ScriptedTransport { arguments in
            arguments.first == "BLPOP" ? nil : ScriptedTransport.minimalServer()(arguments)
        }
        let connection = try await connect(transport)
        let blocked = Task { try await connection.send(RedisCommand("BLPOP", "queue", 0)) }
        try await Task.sleep(for: .milliseconds(50))
        transport.close()
        await #expect(throws: RedisClientError.connectionClosed) { _ = try await blocked.value }
        #expect(await connection.isClosed)
        await #expect(throws: RedisClientError.connectionClosed) { _ = try await connection.send(RedisCommand("PING")) }
    }

    @Test("A cancelled command's late reply is discarded, not given to the next command")
    func cancellationKeepsReplyOrder() async throws {
        let transport = ScriptedTransport { arguments in
            arguments.first == "SLOW" ? nil : ScriptedTransport.minimalServer()(arguments)
        }
        let connection = try await connect(transport)
        let slow = Task { try await connection.send(RedisCommand("SLOW")) }
        try await Task.sleep(for: .milliseconds(50))
        slow.cancel()
        await #expect(throws: CancellationError.self) { _ = try await slow.value }

        // The server answers in order: SLOW's reply arrives first and must be swallowed.
        transport.inject(.simpleString("late reply for SLOW"))
        #expect(try await connection.send(RedisCommand("PING")) == .simpleString("PONG"))
        #expect(try await connection.send(RedisCommand("ECHO", "after")).string == "after")
        await connection.close()
    }
}

@Suite("Supporting types")
struct SupportingTypeTests {
    @Test func serverVersionOrdering() {
        #expect(ServerVersion("7.10.0") > ServerVersion("7.4.2"))
        #expect(ServerVersion("8.0") == ServerVersion(8, 0, 0))
        #expect(ServerVersion("6.2.14") < ServerVersion(7))
        #expect(ServerVersion("7.2.4-rc1").components == [7, 2, 4])
    }

    @Test func infoParsing() {
        let info = RedisInfo(parsing: "# Server\r\nredis_version:7.2.4\r\nredis_mode:standalone\r\n\r\n# Keyspace\r\ndb0:keys=10,expires=2,avg_ttl=0\r\n")
        #expect(info["redis_version"] == "7.2.4")
        #expect(info.sections.map(\.name) == ["Server", "Keyspace"])
        #expect(RedisInfo.parseList(info["db0"] ?? "") == ["keys": "10", "expires": "2", "avg_ttl": "0"])
    }

    @Test func pemParsing() throws {
        // A throwaway self-signed certificate (CN=redi-test).
        let pem = """
        -----BEGIN CERTIFICATE-----
        MIIBfDCCASGgAwIBAgIUVZtX1M8pDsoh9yYfF0wFf6k4C0QwCgYIKoZIzj0EAwIw
        FDESMBAGA1UEAwwJcmVkaS10ZXN0MB4XDTI0MDEwMTAwMDAwMFoXDTM0MDEwMTAw
        MDAwMFowFDESMBAGA1UEAwwJcmVkaS10ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0D
        AQcDQgAEN0JMKI5y0p9qkVZpJHT5IjpQSt4m1N5V9jl2mVZPq0k3bHgqXy7k2bUN
        oJZbJ5h6S1OhCrCwF9q4T5r6ZZ5hYqNTMFEwHQYDVR0OBBYEFF1Fw5CjnbJlJPpd
        E4m7wq4BqkM8MB8GA1UdIwQYMBaAFF1Fw5CjnbJlJPpdE4m7wq4BqkM8MA8GA1Ud
        EwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSQAwRgIhAJ8u3hY4S9fXGQ3l5c2R2v5k
        x2l0U6cJq6S0n3fJqQ0TAiEA0eZ9x5c8n2u7xq7mF3iQd2wH7N0p4G4s3a1d6m5o
        f1E=
        -----END CERTIFICATE-----
        """
        let blocks = CertificateLoader.pemBlocks(in: pem, label: "CERTIFICATE")
        #expect(blocks.count == 1)
        #expect(blocks[0].first == 0x30) // DER SEQUENCE
    }
}
