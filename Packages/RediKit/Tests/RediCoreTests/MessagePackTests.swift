import Foundation
import Testing
@testable import RediCore

/// Fixtures were encoded by github.com/vmihailenco/msgpack v4 (Go, compact encoding), so the decoder
/// is checked against a real encoder rather than only against my reading of the spec.
private enum Fixture {
    /// A Go struct: string, int, bool, float64, float32, []string, empty map, nil pointer,
    /// time.Time (timestamp extension), []byte (bin8) and a string with escapes and non-ASCII.
    static let user = bytes("8ba46e616d65a3416461a361676524a561646d696ec3a573636f7265cb4058a00000000000a5726174696fca3e800000a47461677392a46d617468a4636f6465a46d65746180a76d616e61676572c0a763726561746564d7ff1d5353006553f100a3726177c404deadbeefa46e6f7465b76c696e65310a6c696e6532202271756f7465642220c3a9")
    static let intsCompact = bytes("9cffd0dfd1ff7fd2ffff7fffd3ffffffff7fffffff7fcc80cd0100ce00010000cf0000000100000000cfffffffffffffffffd38000000000000000")
    static let intsWide = bytes("94d30000000000000001cf0000000000000002d2fffffffdcc04")
    static let floats = bytes("96ca3fc00000cb3fb999999999999acb3ff0000000000000cb7ff0000000000000cb7ff8000000000001ca00000000")
    static let str8 = bytes("d9286162636465666768696a6b6c6d6e6f707172737475767778797a6162636465666768696a6b6c6d6e")
    static let array16 = bytes("dc0014000102030405060708090a0b0c0d0e0f10111213")
    static let timeSeconds = bytes("d6ff6553f100")
    static let timeNanoseconds = bytes("d7ff000000146553f100")
    static let timeBeforeEpoch = bytes("c70cff3b9ac9ffffffffffffffffff")
    static let timeFarFuture = bytes("c70cff000000000000000800000000")
    static let intKeys = bytes("8101a36f6e65")

    static func bytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }
}

private func render(_ bytes: [UInt8], _ style: MessagePack.Style = .compact, single: Bool = false, limit: Int = .max) throws -> String {
    try MessagePack.render(bytes, style: style, single: single, limit: limit)
}

private func failure(_ bytes: [UInt8], single: Bool = false) -> MessagePack.DecodeError? {
    do {
        _ = try MessagePack.render(bytes, single: single)
        return nil
    } catch {
        return error
    }
}

/// A 96-bit timestamp extension.
private func timestamp(seconds: Int64, nanoseconds: UInt32 = 0) -> [UInt8] {
    var bytes: [UInt8] = [0xC7, 12, 0xFF]
    withUnsafeBytes(of: nanoseconds.bigEndian) { bytes += $0 }
    withUnsafeBytes(of: seconds.bigEndian) { bytes += $0 }
    return bytes
}

@Suite("MessagePack")
struct MessagePackTests {
    @Test("Renders a Go struct as indented JSON with typed extensions")
    func prettyDocument() throws {
        #expect(try render(Fixture.user, .pretty) == #"""
        {
          "name": "Ada",
          "age": 36,
          "admin": true,
          "score": 98.5,
          "ratio": 0.25,
          "tags": [
            "math",
            "code"
          ],
          "meta": {},
          "manager": null,
          "created": timestamp(2023-11-14T22:13:20.123Z),
          "raw": b"\xde\xad\xbe\xef",
          "note": "line1\nline2 \"quoted\" é"
        }
        """#)
    }

    @Test("Compact style is one line")
    func compactDocument() throws {
        let text = try render(Fixture.user)
        #expect(!text.contains("\n"))
        #expect(text.hasPrefix(#"{"name": "Ada", "age": 36, "admin": true, "score": 98.5, "ratio": 0.25, "tags": ["math", "code"], "meta": {}"#))
    }

    @Test("Integers of every width and sign")
    func integers() throws {
        #expect(try render(Fixture.intsCompact) ==
            "[-1, -33, -129, -32769, -2147483649, 127, 128, 256, 65536, 4294967296, 18446744073709551615, -9223372036854775808]")
        #expect(try render(Fixture.intsWide) == "[1, 2, -3, 4]")
        #expect(try render([0xE0]) == "-32")
    }

    @Test("Floats keep their type; non-finite values are named")
    func floats() throws {
        #expect(try render(Fixture.floats) == "[1.5, 0.1, 1.0, Infinity, NaN, 0.0]")
        #expect(try render([0xCA, 0xFF, 0x80, 0, 0]) == "-Infinity")
    }

    @Test("Strings, binary and containers in every size class")
    func sizeClasses() throws {
        #expect(try render(Fixture.str8) == #""abcdefghijklmnopqrstuvwxyzabcdefghijklmn""#)
        #expect(try render([0xDA, 0, 2, 0x68, 0x69]) == #""hi""#)
        #expect(try render([0xDB, 0, 0, 0, 2, 0x68, 0x69]) == #""hi""#)
        #expect(try render([0xC5, 0, 3, 1, 2, 3]) == #"b"\x01\x02\x03""#)
        #expect(try render([0xC6, 0, 0, 0, 1, 0x41]) == #"b"A""#)
        #expect(try render(Fixture.array16) == "[" + (0..<20).map(String.init).joined(separator: ", ") + "]")
        #expect(try render([0xDD, 0, 0, 0, 1, 0xC0]) == "[null]")
        #expect(try render([0xDE, 0, 1, 0xA1, 0x61, 0x01]) == #"{"a": 1}"#)
        #expect(try render([0xDF, 0, 0, 0, 1, 0xA1, 0x61, 0xC2]) == #"{"a": false}"#)
        #expect(try render([0x80]) == "{}")
        #expect(try render([0x90], .pretty) == "[]")
    }

    @Test("Strings are JSON-escaped; invalid UTF-8 falls back to byte escapes")
    func stringEscaping() throws {
        #expect(try render([0xA3, 0x01, 0x09, 0x7F]) == #""\u0001\t\u007f""#)
        #expect(try render([0xA2, 0xFF, 0xFE]) == #""\xff\xfe""#)
    }

    @Test("Map keys that aren't strings render as themselves")
    func nonStringKeys() throws {
        #expect(try render(Fixture.intKeys) == #"{1: "one"}"#)
    }

    @Test("Extension types, and timestamps in all three layouts")
    func extensions() throws {
        #expect(try render([0xD4, 0x05, 0x41]) == #"ext(5, b"A")"#)
        #expect(try render([0xC7, 3, 0x7F, 1, 2, 3]) == #"ext(127, b"\x01\x02\x03")"#)
        #expect(try render(Fixture.timeSeconds) == "timestamp(2023-11-14T22:13:20Z)")
        #expect(try render(Fixture.timeNanoseconds) == "timestamp(2023-11-14T22:13:20.000000005Z)")
        #expect(try render(Fixture.timeBeforeEpoch) == "timestamp(1969-12-31T23:59:59.999999999Z)")
        #expect(try render(Fixture.timeFarFuture) == "timestamp(3058-10-26T03:46:08Z)")
        // Expected values from Go's time.Format(time.RFC3339Nano).
        #expect(try render(timestamp(seconds: -62_135_596_800)) == "timestamp(0001-01-01T00:00:00Z)")
        #expect(try render(timestamp(seconds: -62_135_596_801)) == "timestamp(0000-12-31T23:59:59Z)")
        #expect(try render(timestamp(seconds: 253_402_300_800)) == "timestamp(10000-01-01T00:00:00Z)")
        // Extreme second counts must not trap.
        #expect(try render(timestamp(seconds: .min)).hasPrefix("timestamp(-"))
        #expect(try render(timestamp(seconds: .max)).hasPrefix("timestamp("))
        // Nanoseconds out of range: shown as a plain extension instead.
        #expect(try render(timestamp(seconds: 0, nanoseconds: 1_000_000_000)).hasPrefix("ext(-1, "))
    }

    @Test("Concatenated values render as a stream unless one value is required")
    func streams() throws {
        #expect(try render([0x01, 0x02], .pretty) == "1\n2")
        #expect(try render([0x01, 0x02]) == "1 2")
        #expect(failure([0x80, 0x01], single: true) == .init(reason: .trailingBytes, offset: 1))
        #expect(MessagePack.isSingleValue([0x80]))
        #expect(!MessagePack.isSingleValue([0x80, 0x01]))
    }

    @Test("Every truncation of a document is rejected")
    func truncation() {
        for length in 0..<Fixture.user.count {
            let prefix = Array(Fixture.user.prefix(length))
            #expect(!MessagePack.isSingleValue(prefix), "prefix of \(length) bytes")
            #expect(failure(prefix) != nil, "prefix of \(length) bytes")
        }
        #expect(failure([]) == .init(reason: .empty, offset: 0))
        // The error points at the value that's cut off.
        #expect(failure([0x92, 0x01, 0xA3, 0x61]) == .init(reason: .truncated, offset: 2))
        #expect(failure([0x92, 0x01]) == .init(reason: .truncated, offset: 0))
    }

    @Test("Hostile input fails fast")
    func hostileInput() {
        #expect(failure([0xC1]) == .init(reason: .reservedByte, offset: 0))
        #expect(failure([0x91, 0xC1]) == .init(reason: .reservedByte, offset: 1))
        // Lengths far beyond the data are rejected before any work.
        #expect(failure([0xDD, 0xFF, 0xFF, 0xFF, 0xFF]) == .init(reason: .truncated, offset: 0))
        #expect(failure([0xDF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]) == .init(reason: .truncated, offset: 0))
        #expect(failure([0xC6, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]) == .init(reason: .truncated, offset: 0))
        // Deep nesting stops at the limit instead of overflowing the stack.
        let deep = [UInt8](repeating: 0x91, count: 100_000) + [0xC0]
        #expect(failure(deep)?.reason == .tooDeep)
        #expect(!MessagePack.isSingleValue(deep))
        let deepest = [UInt8](repeating: 0x91, count: MessagePack.maximumDepth) + [0xC0]
        #expect(MessagePack.isSingleValue(deepest))
    }

    @Test("Output limit cuts on a character boundary")
    func outputLimit() throws {
        let long = [0xDA, 0x01, 0x2C] + (0..<300).map { UInt8(ascii: "a") + UInt8($0 % 26) }
        #expect(try render(long, limit: 20) == #""abcdefghijklmnopqrs…"#)
        #expect(try render([0xA6, 0xC3, 0xA9, 0xC3, 0xA9, 0xC3, 0xA9], limit: 4) == #""é…"#)
        // A cut binary or collection value isn't closed as if it were complete.
        #expect(try render([0xC4, 10] + [UInt8](repeating: 0, count: 10), limit: 8) == #"b"\x00\x…"#)
        #expect(try render(Fixture.array16, limit: 10) == "[0, 1, 2, …")
        #expect(try render(Fixture.user, limit: 1_000) == (try render(Fixture.user)))
    }

    @Test("Documents are recognized; scalars, text and other binary formats aren't")
    func documentDetection() {
        #expect(MessagePack.isDocument(Fixture.user))
        #expect(MessagePack.isDocument(Fixture.array16))
        #expect(!MessagePack.isDocument([0x01]))
        #expect(!MessagePack.isDocument(Array("{}".utf8)))
        #expect(!MessagePack.isDocument([UInt8]()))
        // Python pickle (protocol 4) starts with 0x80, an empty fixmap, but has more bytes after it.
        #expect(!MessagePack.isDocument([0x80, 0x04, 0x95, 0x05, 0x00]))
    }
}

@Suite("MessagePack formatting")
struct MessagePackFormatTests {
    @Test func detectsStringValues() {
        #expect(ValueFormatter.detect(Fixture.user) == .messagePack)
        #expect(ValueFormatter.detect(Array("hello".utf8)) == .text)
        #expect(ValueFormatter.detect([0xFF, 0x00]) == .hex)
        #expect(ValueFormatter.render(Fixture.user, as: .messagePack).hasPrefix("{\n  \"name\": \"Ada\""))
        #expect(ValueFormatter.render([0xC1], as: .messagePack).hasPrefix("Not valid MessagePack"))
        #expect(!ValueFormat.messagePack.isEditable)
    }

    @Test func detectsCollectionValues() {
        let text = Array("plain".utf8)
        #expect(ValueFormatter.detect(elements: [text, Fixture.user]) == .messagePack)
        #expect(ValueFormatter.detect(elements: [text, text]) == .text)
        #expect(ValueFormatter.detect(elements: [Fixture.user, [0xFF, 0x00]]) == .text)
        // A lone MessagePack scalar is too weak a signal on its own.
        #expect(ValueFormatter.detect(elements: [[0xCD, 0x01, 0x02]]) == .text)
        #expect(ValueFormatter.detect(elements: [[UInt8]]()) == .text)
    }

    @Test func cellsAndCopiedText() {
        #expect(ValueFormatter.cellText(Fixture.user, as: .messagePack).hasPrefix(#"{"name": "Ada", "age": 36"#))
        // Text and data that isn't MessagePack stay as they are.
        #expect(ValueFormatter.cellText(Array("5".utf8), as: .messagePack) == "5")
        #expect(ValueFormatter.cellText([0xFF, 0x00], as: .messagePack) == #"\xff\x00"#)
        #expect(ValueFormatter.cellText(Fixture.user, as: .text) == ValueFormatter.preview(Fixture.user, limit: 4096))
        #expect(ValueFormatter.cellText([0xDE, 0xAD, 0xBE, 0xEF], as: .hex) == "de ad be ef")
        #expect(ValueFormatter.elementText(Fixture.user, as: .messagePack) == (try? MessagePack.render(Fixture.user)))
        #expect(ValueFormatter.elementText(Array("hi".utf8), as: .messagePack) == "hi")
    }
}

@Suite("MessagePack performance")
struct MessagePackPerformanceTests {
    /// Budget: a ~1 MB document (the string preview limit) renders in well under a frame budget
    /// for Release builds (`swift test -c release -Xswiftc -enable-testing --filter MessagePackPerformance`).
    @Test("Renders a 1 MB document within budget")
    func megabyteDocument() throws {
        var bytes: [UInt8] = [0xDD]
        let count = 16_000
        withUnsafeBytes(of: UInt32(count).bigEndian) { bytes += $0 }
        for index in 0..<count {
            // {"id": index, "name": "user <index>", "tags": ["alpha", "beta"], "score": 1.5, "active": true}
            bytes.append(0x85)
            str("id", into: &bytes); bytes.append(0xCE); withUnsafeBytes(of: UInt32(index).bigEndian) { bytes += $0 }
            str("name", into: &bytes); str("user \(index)", into: &bytes)
            str("tags", into: &bytes); bytes.append(0x92); str("alpha", into: &bytes); str("beta", into: &bytes)
            str("score", into: &bytes); bytes.append(0xCB); withUnsafeBytes(of: (1.5).bitPattern.bigEndian) { bytes += $0 }
            str("active", into: &bytes); bytes.append(0xC3)
        }
        #expect(bytes.count > 1_000_000)

        let clock = ContinuousClock()
        var text = ""
        let elapsed = try clock.measure { text = try MessagePack.render(bytes) }
        let detection = clock.measure { #expect(ValueFormatter.detect(bytes) == .messagePack) }
        #expect(text.hasSuffix("}\n]"))
        print("MessagePack: rendered \(bytes.count / 1024) KB into \(text.utf8.count / 1024) KB in \(elapsed); detected in \(detection)")
        #if !DEBUG
        #expect(elapsed < .milliseconds(100))
        #expect(detection < .milliseconds(20))
        #endif
    }

    private func str(_ text: String, into bytes: inout [UInt8]) {
        bytes.append(0xA0 | UInt8(text.utf8.count))
        bytes += text.utf8
    }
}
