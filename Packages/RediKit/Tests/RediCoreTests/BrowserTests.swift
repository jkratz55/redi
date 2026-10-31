import Foundation
import RedisClient
import RedisWire
import Testing
@testable import RediCore
@testable import RedisTestSupport

@Suite("Key index and tree")
struct KeyTreeTests {
    @Test("Index locates keys across pages")
    func indexLookup() {
        var index = KeyIndex()
        index.append(KeyPage(keys: [Array("a".utf8), Array("b".utf8)]))
        index.append(KeyPage(keys: []))
        index.append(KeyPage(keys: [Array("c".utf8)], type: .hash))
        #expect(index.count == 3)
        #expect(Array(index.key(at: 0)) == Array("a".utf8))
        #expect(Array(index.key(at: 2)) == Array("c".utf8))
        #expect(index.knownType(at: 2) == .hash)
        #expect(index.knownType(at: 1) == nil)
    }

    @Test("Builds namespaces with counts")
    func namespaces() {
        var index = KeyIndex()
        index.append(KeyPage(keys: ["user:1", "user:2", "user:10:profile", "session:x", "plain", "a::b"].map { Array($0.utf8) }))
        let tree = KeyTree(delimiter: ":")
        tree.insert(from: index, range: 0..<index.count)
        #expect(tree.root.totalKeyCount == 6)
        #expect(tree.root.sortedChildren.map(\.name) == ["a", "session", "user"])
        let user = tree.root.sortedChildren[2]
        #expect(user.totalKeyCount == 3)
        #expect(user.keyIndices == [0, 1])
        #expect(user.prefix == Array("user:".utf8))
        #expect(user.sortedChildren.map(\.name) == ["10"])
        #expect(tree.root.keyIndices == [4])
        // An empty segment between doubled delimiters is its own namespace.
        #expect(tree.root.sortedChildren[0].sortedChildren.map(\.name) == [""])
    }

    @Test("Multi-character delimiters")
    func multiCharacterDelimiter() {
        var index = KeyIndex()
        index.append(KeyPage(keys: ["app::cache::1", "app:x"].map { Array($0.utf8) }))
        let tree = KeyTree(delimiter: "::")
        tree.insert(from: index, range: 0..<2)
        #expect(tree.root.sortedChildren.map(\.name) == ["app"])
        #expect(tree.root.keyIndices == [1])
        #expect(tree.root.sortedChildren[0].sortedChildren.map(\.name) == ["cache"])
    }

    @Test("Deduplicates repeated SCAN results")
    func dedupe() {
        var seen = KeyDeduplicator()
        let first = seen.insert(Array("k".utf8))
        let repeated = seen.insert(Array("k".utf8))
        let other = seen.insert(Array("j".utf8))
        #expect(first && !repeated && other)
    }

    /// Budget: 1M keys indexed and grouped in well under a second in Release
    /// (`swift test -c release --filter KeyTreePerformance`).
    @Test("1M keys: index + tree within budget")
    func millionKeys() {
        let clock = ContinuousClock()
        var index = KeyIndex()
        let tree = KeyTree(delimiter: ":")
        let regions = ["us", "eu", "apac", "latam"]
        let elapsed = clock.measure {
            var page: [[UInt8]] = []
            page.reserveCapacity(1000)
            for i in 0..<1_000_000 {
                page.append(Array("tenant:\(i % 50):\(regions[i % 4]):user:\(i)".utf8))
                if page.count == 1000 {
                    let start = index.count
                    index.append(KeyPage(keys: page))
                    tree.insert(from: index, range: start..<index.count)
                    page.removeAll(keepingCapacity: true)
                }
            }
        }
        #expect(index.count == 1_000_000)
        #expect(tree.root.totalKeyCount == 1_000_000)
        #expect(tree.root.sortedChildren.first?.childCount == 50)
        print("Browser: indexed + grouped 1M keys in \(elapsed)")
        #if !DEBUG
        #expect(elapsed < .seconds(1))
        #endif
    }
}

@Suite("Value formatting")
struct ValueFormatterTests {
    @Test func detection() {
        #expect(ValueFormatter.detect(Array(#"{"a": [1, 2]}"#.utf8)) == .json)
        #expect(ValueFormatter.detect(Array("hello world".utf8)) == .text)
        #expect(ValueFormatter.detect([0, 159, 146, 150]) == .hex)
        #expect(ValueFormatter.detect([UInt8]()) == .text)
    }

    @Test func prettyJSONKeepsOrder() {
        let pretty = ValueFormatter.prettyJSON(#"{"z":1,"a":{"b":[1,2,{}],"c":"x, \"y\""},"e":[]}"#)
        #expect(pretty == """
        {
          "z": 1,
          "a": {
            "b": [
              1,
              2,
              {}
            ],
            "c": "x, \\"y\\""
          },
          "e": []
        }
        """)
        #expect(ValueFormatter.prettyJSON("not json") == "not json")
    }

    @Test func escapingRoundTrips() throws {
        let bytes: [UInt8] = [0, 1, 10, 13, 9, 34, 92, 65, 255]
        let text = ValueFormatter.escaped(bytes)
        #expect(text == #"\x00\x01\n\r\t\"\\A\xff"#)
        #expect(try ValueFormatter.unescape(text) == bytes)
        #expect(throws: ValueFormatter.ParseError.self) { try ValueFormatter.unescape(#"\q"#) }
    }

    @Test func hexRoundTrips() throws {
        let bytes = (0..<40).map { UInt8($0 * 7 % 256) }
        let dump = ValueFormatter.render(bytes, as: .hex)
        #expect(dump.hasPrefix("00000000: 00 07 0e 15"))
        #expect(try ValueFormatter.parse(dump, as: .hex) == bytes)
        #expect(try ValueFormatter.parse("de ad BE EF", as: .hex) == [0xDE, 0xAD, 0xBE, 0xEF])
        #expect(throws: ValueFormatter.ParseError.self) { try ValueFormatter.parse("abc", as: .hex) }
    }

    @Test func vectors() {
        var bytes: [UInt8] = []
        for value: Float in [1, -0.5] { withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes += $0 } }
        #expect(ValueFormatter.render(bytes, as: .float32Vector) == "[1.0, -0.5]")
    }

    @Test func ttlText() {
        #expect(Int64(350).ttlDescription == "350ms")
        #expect(Int64(45_000).ttlDescription == "45s")
        #expect(Int64(3_723_000).ttlDescription == "1h 2m")
        #expect(Int64(2 * 86_400_000 + 3 * 3_600_000).ttlDescription == "2d 3h")
    }

    @Test func scanFilters() {
        #expect(ScanFilter(pattern: "user:").matchPattern == "user:*")
        #expect(ScanFilter(pattern: "user:*:x").matchPattern == "user:*:x")
        #expect(ScanFilter(pattern: "a[b").matchPattern == "a[b")
        #expect(ScanFilter(pattern: "user:1").exactKey == "user:1")
        #expect(ScanFilter(pattern: "  ").matchPattern == nil)
    }
}

@Suite("Browser against a live server", .enabled(if: RedisServerFixture.isAvailable), .serialized)
struct BrowserLiveTests {
    private func seeded() async throws -> (RedisServerFixture, RedisSession) {
        let server = try await RedisServerFixture()
        let session = RedisSession(configuration: server.configuration())
        var commands: [RedisCommand] = []
        for i in 0..<1500 { commands.append(RedisCommand("SET", "user:\(i):name", "User \(i)")) }
        commands.append(RedisCommand("HSET", "h", "a", "1", "b", "2", "c", "3"))
        commands.append(RedisCommand("RPUSH", "l", "x", "y", "z"))
        commands.append(RedisCommand("SADD", "s", "m1", "m2"))
        commands.append(RedisCommand("ZADD", "z", 1, "one", 2, "two", 3, "three"))
        commands.append(RedisCommand("XADD", "x", "1-1", "f", "v1"))
        commands.append(RedisCommand("XADD", "x", "2-1", "f", "v2"))
        commands.append(RedisCommand("SET", "ttl", "v", "EX", 100))
        _ = try await session.pipeline(commands)
        return (server, session)
    }

    @Test("Scans everything, a prefix, and a type")
    func scanning() async throws {
        let (server, session) = try await seeded()
        defer { server.stop() }
        let scanner = await KeyScanner(session: session)
        #expect(try await scanner.databaseSize() == 1506)

        var all = ScanCursor()
        var keys = KeyDeduplicator()
        while !all.isComplete {
            let result = try await scanner.next(from: all, filter: ScanFilter(), count: 500, target: 500)
            for key in result.keys { _ = keys.insert(key) }
            all = result.cursor
        }
        #expect(keys.count == 1506)

        let hashes = try await scanner.next(from: ScanCursor(), filter: ScanFilter(type: .hash), count: 2000, target: 10)
        #expect(hashes.keys == [Array("h".utf8)])
        #expect(try await scanner.lookup(exactKey: "user:7:name", type: nil) == .string)
        #expect(try await scanner.lookup(exactKey: "user:7:name", type: .hash) == nil)
        #expect(try await scanner.lookup(exactKey: "missing", type: nil) == nil)

        let metadata = try await KeyMetadata.load([Array("h".utf8), Array("ttl".utf8), Array("missing".utf8)], session: session)
        #expect(metadata[0].type == .hash && metadata[0].ttl == nil && (metadata[0].memory ?? 0) > 0)
        #expect(metadata[1].ttl.map { $0 > 90_000 } == true)
        #expect(metadata[2].isMissing)
        await session.close()
    }

    @Test("Reads and edits every value type")
    func values() async throws {
        let (server, session) = try await seeded()
        defer { server.stop() }
        let ops = KeyOperations(session: session)

        let details = try await ops.details(Array("h".utf8))
        #expect(details.type == .hash && details.length == 3 && details.encoding == "listpack")

        let hash = try await ops.hashPage(Array("h".utf8), cursor: "0", match: nil, count: 100, withFieldTTL: true)
        #expect(Set(hash.elements.map { String(decoding: $0.field, as: UTF8.self) }) == ["a", "b", "c"])
        try await ops.setHashField(Array("h".utf8), field: Array("d".utf8), value: Array("4".utf8))
        try await ops.deleteHashFields(Array("h".utf8), fields: [Array("a".utf8)])
        try await ops.setHashFieldTTL(Array("h".utf8), field: Array("b".utf8), seconds: 60)
        let withTTL = try await ops.hashPage(Array("h".utf8), cursor: "0", match: "b", count: 100, withFieldTTL: true)
        #expect(withTTL.elements.first?.ttl.map { $0 > 50 } == true)

        try await ops.removeListElement(Array("l".utf8), index: 1)
        try await ops.pushList(Array("l".utf8), values: [Array("w".utf8)], atHead: true)
        #expect(try await ops.listRange(Array("l".utf8), start: 0, count: 10).map { String(decoding: $0.value, as: UTF8.self) } == ["w", "x", "z"])

        let members = try await ops.setPage(Array("s".utf8), cursor: "0", match: nil, count: 10)
        #expect(members.elements.count == 2 && members.next == nil)

        let top = try await ops.sortedSetRange(Array("z".utf8), start: 0, count: 2, descending: true)
        #expect(top.map(\.score) == [3, 2])
        let found = try await ops.sortedSetPage(Array("z".utf8), cursor: "0", match: "t*", count: 10)
        #expect(Set(found.elements.map(\.score)) == [2, 3])

        let stream = try await ops.streamPage(Array("x".utf8), before: nil, count: 1)
        #expect(stream.elements.map(\.id) == ["2-1"] && stream.next == "2-1")
        let older = try await ops.streamPage(Array("x".utf8), before: "2-1", count: 1)
        #expect(older.elements.map(\.id) == ["1-1"])
        try await ops.createStreamGroup(Array("x".utf8), name: "g", startID: "0")
        #expect(try await ops.streamGroups(Array("x".utf8)).map(\.name) == ["g"])

        let (value, truncated) = try await ops.string(Array("user:1:name".utf8), limit: 4)
        #expect(String(decoding: value, as: UTF8.self) == "User" && truncated)
        try await ops.setString(Array("ttl".utf8), value: Array("new".utf8))
        #expect(try await ops.details(Array("ttl".utf8)).ttl != nil) // KEEPTTL preserved expiry

        try await ops.rename(Array("s".utf8), to: Array("s2".utf8))
        await #expect(throws: RedisServerError.self) { try await ops.rename(Array("s2".utf8), to: Array("h".utf8)) }
        await #expect(throws: RedisServerError.self) { try await ops.create(Array("h".utf8), value: .string([]), ttlSeconds: nil) }
        try await ops.create(Array("new:json-ish".utf8), value: .sortedSet(member: Array("m".utf8), score: 5), ttlSeconds: 30)
        #expect(try await ops.details(Array("new:json-ish".utf8)).ttl != nil)
        await session.close()
    }

    @Test("Deletes with undo and in bulk")
    func deletion() async throws {
        let (server, session) = try await seeded()
        defer { server.stop() }
        let ops = KeyOperations(session: session)
        let snapshot = try #require(try await ops.snapshot(Array("ttl".utf8)))
        #expect(try await ops.delete([Array("ttl".utf8)]) == 1)
        try await ops.restore(snapshot)
        #expect(try await ops.details(Array("ttl".utf8)).ttl.map { $0 > 90_000 } == true)

        var last = 0
        for try await deleted in ops.bulkDelete(filter: ScanFilter(pattern: "user:"), batchSize: 200) { last = deleted }
        #expect(last == 1500)
        #expect(try await KeyScanner(session: session).databaseSize() == 6)
        await session.close()
    }
}
