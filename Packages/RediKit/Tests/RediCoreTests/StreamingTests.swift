import Foundation
import RedisClient
import RedisWire
import Testing
@testable import RediCore
@testable import RedisTestSupport

@Suite("Streaming primitives")
struct StreamingPrimitiveTests {
    @Test func ringBuffer() {
        var buffer = RingBuffer<Int>(capacity: 3)
        buffer.append(contentsOf: [1, 2])
        #expect(buffer.elements == [1, 2])
        let evictedFirst = buffer.append(3)
        let evictedSecond = buffer.append(4)
        #expect(!evictedFirst && evictedSecond)
        #expect(buffer.elements == [2, 3, 4])
        #expect(buffer[0] == 2 && buffer.count == 3)
        buffer.removeAll()
        #expect(buffer.isEmpty)
    }

    @Test func pubSubFrames() {
        let message = PubSubMessage.parse(.push(["message", "news", "hi"]))
        #expect(message?.kind == .message && message?.payload == Array("hi".utf8))
        let pattern = PubSubMessage.parse(["pmessage", "n*", "news", "hi"])
        #expect(pattern?.kind == .pattern && pattern?.pattern == Array("n*".utf8))
        #expect(PubSubMessage.parse(.push(["subscribe", "news", 1])) == nil)
    }

    @Test func monitorLines() throws {
        let entry = try #require(MonitorEntry.parse(#"1698765432.123456 [3 127.0.0.1:52345] "set" "key" "va\"lue""#))
        #expect(entry.database == 3)
        #expect(entry.client == "127.0.0.1:52345")
        #expect(entry.command == "SET")
        #expect(entry.arguments == #""key" "va\"lue""#)
        #expect(abs(entry.timestamp - 1698765432.123456) < 0.000001)
        let lua = try #require(MonitorEntry.parse(#"1.5 [0 lua] "get" "k""#))
        #expect(lua.client == "lua")
    }
}

@Suite("Streaming against a live server", .enabled(if: RedisServerFixture.isAvailable), .serialized)
struct StreamingLiveTests {
    @Test("Subscribes, receives channel and pattern messages, and resubscribes after a drop")
    func pubSub() async throws {
        let server = try await RedisServerFixture()
        let session = RedisSession(configuration: server.configuration())
        let listener = PubSubListener(session: session)
        var events = listener.events.makeAsyncIterator()
        try await listener.subscribe(channels: ["news"], patterns: ["alerts.*"])
        var subscribed = 0
        while subscribed < 2, let event = await events.next() {
            if case .subscribed(let count) = event { subscribed = count }
        }
        #expect(try await listener.publish(channel: "news", message: Array("one".utf8)) == 1)
        #expect(try await listener.publish(channel: "alerts.disk", message: Array("two".utf8)) == 1)
        var received: [PubSubMessage] = []
        while received.count < 2, let event = await events.next() {
            if case .messages(let batch) = event { received += batch }
        }
        #expect(received.map(\.kind) == [.message, .pattern])
        #expect(received.map { String(decoding: $0.payload, as: UTF8.self) } == ["one", "two"])

        // Kill the subscriber connection server-side; the listener must come back by itself.
        let admin = try await RedisConnection.connect(server.configuration())
        try await admin.execute(RedisCommand("CLIENT", "KILL", "TYPE", "pubsub"))
        var recovered = false
        while !recovered, let event = await events.next() {
            if case .resubscribed = event { recovered = true }
        }
        #expect(recovered)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await admin.send(RedisCommand("PUBLISH", "news", "three")) == .integer(1))
        await listener.stop()
        await admin.close()
        await session.close()
    }

    @Test("MONITOR streams parsed commands")
    func monitor() async throws {
        let server = try await RedisServerFixture()
        let session = RedisSession(configuration: server.configuration())
        let monitor = MonitorListener(session: session)
        try await monitor.start()
        try await session.execute(RedisCommand("SET", "monitored", "value"))
        var seen: [MonitorEntry] = []
        for await batch in monitor.entries {
            seen += batch
            if seen.contains(where: { $0.command == "SET" }) { break }
        }
        let set = try #require(seen.first { $0.command == "SET" })
        #expect(set.arguments == #""monitored" "value""#)
        await monitor.stop()
        await session.close()
    }
}
