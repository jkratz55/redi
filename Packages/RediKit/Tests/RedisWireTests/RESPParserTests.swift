import Foundation
import Testing
@testable import RedisWire

private func parseAll(_ bytes: [UInt8], limits: RESPParser.Limits = .init()) throws -> [RESPValue] {
    var parser = RESPParser(limits: limits)
    parser.append(bytes)
    var values: [RESPValue] = []
    while let value = try parser.next() { values.append(value) }
    return values
}

private func parseOne(_ text: String) throws -> RESPValue? {
    try parseAll(Array(text.utf8)).first
}

@Suite("RESP parser")
struct RESPParserTests {
    @Test("Parses RESP2 scalar types")
    func resp2Scalars() throws {
        #expect(try parseOne("+OK\r\n") == .simpleString("OK"))
        #expect(try parseOne("-ERR unknown command\r\n") == .error(RedisServerError("ERR unknown command")))
        #expect(try parseOne(":1000\r\n") == .integer(1000))
        #expect(try parseOne(":-42\r\n") == .integer(-42))
        #expect(try parseOne("$5\r\nhello\r\n") == .bulkString(Array("hello".utf8)))
        #expect(try parseOne("$0\r\n\r\n") == .bulkString([]))
        #expect(try parseOne("$-1\r\n") == .null)
        #expect(try parseOne("*-1\r\n") == .null)
        #expect(try parseOne("*0\r\n") == .array([]))
    }

    @Test("Parses RESP3 types")
    func resp3Types() throws {
        #expect(try parseOne("_\r\n") == .null)
        #expect(try parseOne("#t\r\n") == .boolean(true))
        #expect(try parseOne("#f\r\n") == .boolean(false))
        #expect(try parseOne(",3.25\r\n") == .double(3.25))
        #expect(try parseOne(",inf\r\n") == .double(.infinity))
        #expect(try parseOne(",-inf\r\n") == .double(-.infinity))
        #expect(try parseOne(",nan\r\n")?.double?.isNaN == true)
        #expect(try parseOne("(3492890328409238509324850943850943825024385\r\n") == .bigNumber("3492890328409238509324850943850943825024385"))
        #expect(try parseOne("!21\r\nSYNTAX invalid syntax\r\n") == .error(RedisServerError("SYNTAX invalid syntax")))
        #expect(try parseOne("=15\r\ntxt:Some string\r\n") == .verbatimString(format: "txt", Array("Some string".utf8)))
        #expect(try parseOne("%2\r\n+first\r\n:1\r\n+second\r\n:2\r\n") ==
            .map([RESPPair(.simpleString("first"), 1), RESPPair(.simpleString("second"), 2)]))
        #expect(try parseOne("~2\r\n+a\r\n+b\r\n") == .set([.simpleString("a"), .simpleString("b")]))
        #expect(try parseOne(">3\r\n$7\r\nmessage\r\n$2\r\nch\r\n$2\r\nhi\r\n") == .push(["message", "ch", "hi"]))
    }

    @Test("Attributes wrap the following reply")
    func attributes() throws {
        let value = try parseOne("|1\r\n+key-popularity\r\n%1\r\n$1\r\na\r\n,0.19\r\n*2\r\n:2039\r\n:9543\r\n")
        let expected = RESPValue.attributed(
            attributes: [RESPPair(.simpleString("key-popularity"), .map([RESPPair("a", .double(0.19))]))],
            value: [2039, 9543])
        #expect(value == expected)
        #expect(value?.unwrapped == [2039, 9543])
    }

    @Test("Nested aggregates")
    func nested() throws {
        let value = try parseOne("*3\r\n:1\r\n*2\r\n+a\r\n*0\r\n%1\r\n+k\r\n~1\r\n#t\r\n")
        #expect(value == .array([1, .array([.simpleString("a"), .array([])]),
                                 .map([RESPPair(.simpleString("k"), .set([.boolean(true)]))])]))
    }

    @Test("Bulk strings are binary-safe, including embedded CRLF")
    func binarySafety() throws {
        let payload: [UInt8] = [0, 13, 10, 255, 13, 10, 0x80]
        var bytes = Array("$\(payload.count)\r\n".utf8) + payload
        bytes += [13, 10]
        #expect(try parseAll(bytes) == [.bulkString(payload)])
    }

    @Test("Integer edge values")
    func integerEdges() throws {
        #expect(try parseOne(":9223372036854775807\r\n") == .integer(.max))
        #expect(try parseOne(":-9223372036854775808\r\n") == .integer(.min))
        #expect(throws: RESPParseError.self) { try parseOne(":9223372036854775808\r\n") }
        #expect(throws: RESPParseError.self) { try parseOne(":12a\r\n") }
        #expect(throws: RESPParseError.self) { try parseOne(":\r\n") }
    }

    @Test("Returns nil until a reply is complete and resumes without loss")
    func incomplete() throws {
        var parser = RESPParser()
        parser.append(Array("*2\r\n$3\r\nfo".utf8))
        #expect(try parser.next() == nil)
        parser.append(Array("o\r\n".utf8))
        #expect(try parser.next() == nil)
        parser.append(Array(":7\r\n+OK\r".utf8))
        #expect(try parser.next() == ["foo", 7])
        #expect(try parser.next() == nil)
        parser.append(Array("\n".utf8))
        #expect(try parser.next() == .simpleString("OK"))
        #expect(parser.isIdle)
    }

    @Test("Every split point yields the same values")
    func everySplitPoint() throws {
        let stream = Array("""
        +OK\r\n-ERR x\r\n:12\r\n$5\r\nhe\r\no\r\n_\r\n#t\r\n,1.5\r\n(123\r\n!3\r\nBAD\r\n=7\r\ntxt:abc\r\n\
        *2\r\n$1\r\na\r\n*1\r\n:1\r\n%1\r\n+k\r\n$1\r\nv\r\n~1\r\n+s\r\n>2\r\n+p\r\n:9\r\n|1\r\n+a\r\n:1\r\n+wrapped\r\n$-1\r\n*-1\r\n
        """.utf8)
        let expected = try parseAll(stream)
        #expect(expected.count == 17)

        for split in 1..<stream.count {
            var parser = RESPParser()
            var values: [RESPValue] = []
            parser.append(Array(stream[..<split]))
            while let value = try parser.next() { values.append(value) }
            parser.append(Array(stream[split...]))
            while let value = try parser.next() { values.append(value) }
            #expect(values == expected, "split at \(split)")
        }

        // Byte by byte.
        var parser = RESPParser()
        var values: [RESPValue] = []
        for byte in stream {
            parser.append([byte])
            while let value = try parser.next() { values.append(value) }
        }
        #expect(values == expected)
    }

    @Test("Rejects malformed input", arguments: [
        "?nope\r\n", "$3\r\nabcd\r\n", "#x\r\n", "_x\r\n", ",abc\r\n", "$?\r\n", "*?\r\n", "=2\r\nab\r\n", "$-2\r\n",
    ])
    func malformed(input: String) {
        #expect(throws: RESPParseError.self) { try parseAll(Array(input.utf8)) }
    }

    @Test("Enforces limits")
    func limits() {
        var limits = RESPParser.Limits()
        limits.maxDepth = 3
        #expect(throws: RESPParseError.self) { try parseAll(Array("*1\r\n*1\r\n*1\r\n*1\r\n:1\r\n".utf8), limits: limits) }
        limits = RESPParser.Limits()
        limits.maxBulkLength = 4
        #expect(throws: RESPParseError.self) { try parseAll(Array("$5\r\nhello\r\n".utf8), limits: limits) }
        limits = RESPParser.Limits()
        limits.maxAggregateLength = 10
        #expect(throws: RESPParseError.self) { try parseAll(Array("*11\r\n".utf8), limits: limits) }
    }

    @Test("Huge declared lengths don't allocate up front")
    func hostileLengths() throws {
        var parser = RESPParser()
        parser.append(Array("*2000000000\r\n:1\r\n".utf8))
        #expect(try parser.next() == nil)
    }

    @Test("Consumed bytes are released")
    func compaction() throws {
        var parser = RESPParser()
        let reply = Array("$1000\r\n".utf8) + [UInt8](repeating: 65, count: 1000) + [13, 10]
        for _ in 0..<500 {
            parser.append(reply)
            _ = try parser.next()
        }
        #expect(parser.bufferedByteCount == 0)
        #expect(parser.isIdle)
    }
}

@Suite("RESP encoder")
struct RESPEncoderTests {
    @Test("Encodes commands as arrays of bulk strings")
    func command() {
        var buffer: [UInt8] = []
        RESPEncoder.encode(RedisCommand("SET", "key", 12, [UInt8]([0, 1])), into: &buffer)
        let expected = Array("*4\r\n$3\r\nSET\r\n$3\r\nkey\r\n$2\r\n12\r\n$2\r\n".utf8) + [0, 1, 13, 10]
        #expect(buffer == expected)
    }

    @Test("Decimal encoding", arguments: [0, 7, 10, 99, 12345, -1, -987654, Int.max, Int.min])
    func decimals(value: Int) {
        var buffer: [UInt8] = []
        RESPEncoder.appendDecimal(value, into: &buffer)
        #expect(String(decoding: buffer, as: UTF8.self) == String(value))
    }

    @Test("Random values round-trip through encode and parse")
    func roundTrip() throws {
        var generator = SeededGenerator(seed: 42)
        for _ in 0..<2_000 {
            let value = RESPValue.random(depth: 0, using: &generator)
            var bytes: [UInt8] = []
            RESPEncoder.encode(value, into: &bytes)
            #expect(try parseAll(bytes) == [value])
        }
    }

    @Test("RESP2 encoding collapses RESP3-only types")
    func resp2() throws {
        var bytes: [UInt8] = []
        RESPEncoder.encodeRESP2(.map([RESPPair("a", .boolean(true))]), into: &bytes)
        #expect(try parseAll(bytes) == [["a", 1]])
        #expect(try parseAll(bytes).first?.pairs == [RESPPair("a", 1)])
    }
}

@Suite("RESP value accessors")
struct RESPValueTests {
    @Test func accessors() {
        #expect(RESPValue.bulkString(Array("42".utf8)).int == 42)
        #expect(RESPValue.simpleString("OK").string == "OK")
        #expect(RESPValue.error(RedisServerError("WRONGTYPE Operation")).serverError?.code == "WRONGTYPE")
        #expect(RESPValue.error(RedisServerError("something odd")).serverError?.code == "ERR")
        #expect(RESPValue.array(["a", "b", "c", "d"]).pairs?.count == 2)
        #expect(RESPValue.array(["a", "b", "c"]).pairs == nil)
        #expect(RESPValue.map([RESPPair("version", "7.2.0")])["version"]?.string == "7.2.0")
        #expect(throws: RedisServerError.self) { try RESPValue.error(RedisServerError("ERR x")).throwIfError() }
    }
}

@Suite("RESP performance")
struct RESPPerformanceTests {
    /// Budget: a 1M-element reply parses in under 200 ms in Release builds
    /// (`swift test -c release --filter RESPPerformance`).
    @Test("Parses a 1M-element array within budget")
    func millionElementArray() throws {
        var bytes = Array("*1000000\r\n".utf8)
        bytes.reserveCapacity(20_000_000)
        for index in 0..<1_000_000 {
            let key = Array("user:\(index)".utf8)
            bytes += Array("$\(key.count)\r\n".utf8)
            bytes += key
            bytes += [13, 10]
        }

        let clock = ContinuousClock()
        var parsed: RESPValue?
        let elapsed = try clock.measure {
            var parser = RESPParser()
            // Feed in 256 KB chunks, as the transport does.
            var offset = 0
            while offset < bytes.count {
                let end = min(bytes.count, offset + 256 * 1024)
                bytes[offset..<end].withUnsafeBytes { parser.append($0) }
                if let value = try parser.next() { parsed = value }
                offset = end
            }
        }
        #expect(parsed?.array?.count == 1_000_000)
        print("RESP: parsed 1M-element array (\(bytes.count / 1_048_576) MB) in \(elapsed)")
        #if !DEBUG
        #expect(elapsed < .milliseconds(200))
        #endif
    }
}

// MARK: - Random value generation

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

extension RESPValue {
    static func random(depth: Int, using generator: inout SeededGenerator) -> RESPValue {
        let line = { (generator: inout SeededGenerator) -> String in
            String((0..<Int.random(in: 0...12, using: &generator)).map { _ in
                "abcdefghijklmnopqrstuvwxyz0123456789 _-".randomElement(using: &generator)!
            })
        }
        let bytes = { (generator: inout SeededGenerator) -> [UInt8] in
            (0..<Int.random(in: 0...40, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
        }
        let maxKind = depth >= 3 ? 9 : 15
        switch Int.random(in: 0...maxKind, using: &generator) {
        case 0: return .simpleString(line(&generator))
        case 1: return .error(RedisServerError("ERR " + line(&generator)))
        case 2: return .integer(Int64.random(in: .min ... .max, using: &generator))
        case 3: return .bulkString(bytes(&generator))
        case 4: return .null
        case 5: return .boolean(Bool.random(using: &generator))
        case 6: return .double(Double(Int.random(in: -1_000_000...1_000_000, using: &generator)) / 64)
        case 7: return .bigNumber(String(UInt64.random(in: 0 ... .max, using: &generator)) + "000000")
        case 8: return .verbatimString(format: "txt", bytes(&generator))
        case 9: return .double([Double.infinity, -.infinity][Int.random(in: 0...1, using: &generator)])
        case 10, 11: return .array((0..<Int.random(in: 0...5, using: &generator)).map { _ in random(depth: depth + 1, using: &generator) })
        case 12: return .set((0..<Int.random(in: 0...4, using: &generator)).map { _ in random(depth: depth + 1, using: &generator) })
        case 13: return .push((0..<Int.random(in: 1...4, using: &generator)).map { _ in random(depth: depth + 1, using: &generator) })
        case 14: return .map((0..<Int.random(in: 0...4, using: &generator)).map { _ in
            RESPPair(random(depth: depth + 1, using: &generator), random(depth: depth + 1, using: &generator))
        })
        default: return .attributed(attributes: [RESPPair(.simpleString(line(&generator)), random(depth: depth + 1, using: &generator))],
                                    value: random(depth: depth + 1, using: &generator))
        }
    }
}
