/// A single RESP2 or RESP3 reply, preserved with full type fidelity.
///
/// Binary payloads (bulk strings, verbatim strings) are kept as raw bytes: Redis keys and values are
/// binary-safe, and decoding to `String` is deferred to presentation code.
public enum RESPValue: Sendable, Hashable {
    /// `+OK` — status reply. Never contains CR/LF; decoded as UTF-8 (lossy).
    case simpleString(String)
    /// `-ERR ...` or RESP3 blob error `!`.
    case error(RedisServerError)
    /// `:42`
    case integer(Int64)
    /// `$5\r\nhello` — binary-safe.
    case bulkString([UInt8])
    /// RESP2 null bulk/array (`$-1`, `*-1`) or RESP3 `_`.
    case null
    /// `*N` — ordered elements.
    case array([RESPValue])
    /// RESP3 `#t` / `#f`.
    case boolean(Bool)
    /// RESP3 `,3.14` (also `inf`, `-inf`, `nan`).
    case double(Double)
    /// RESP3 `(` — arbitrary-precision integer, kept textual.
    case bigNumber(String)
    /// RESP3 `=` — text with a 3-character format hint such as `txt` or `mkd`.
    case verbatimString(format: String, [UInt8])
    /// RESP3 `%` — ordered key/value pairs (order as sent by the server).
    case map([RESPPair])
    /// RESP3 `~` — unordered collection; kept in server order.
    case set([RESPValue])
    /// RESP3 `>` — out-of-band data (pub/sub messages, client-side caching invalidations).
    case push([RESPValue])
    /// RESP3 `|` — attribute map attached to the reply that follows it.
    indirect case attributed(attributes: [RESPPair], value: RESPValue)
}

/// One key/value pair of a RESP3 map or attribute.
public struct RESPPair: Sendable, Hashable {
    public var key: RESPValue
    public var value: RESPValue

    public init(_ key: RESPValue, _ value: RESPValue) {
        self.key = key
        self.value = value
    }
}

/// An error reply sent by the server, e.g. `WRONGTYPE Operation against a key holding the wrong kind of value`.
public struct RedisServerError: Error, Sendable, Hashable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    /// The leading uppercase error code (`ERR`, `WRONGTYPE`, `MOVED`, `NOAUTH`, ...), if present.
    public var code: String {
        let first = message.prefix { $0 != " " }
        return first.allSatisfy({ $0.isUppercase || $0 == "_" }) && !first.isEmpty ? String(first) : "ERR"
    }

    public var description: String { message }
}

// MARK: - Convenience accessors

extension RESPValue {
    /// Unwraps RESP3 attributes, returning the underlying reply.
    @inlinable public var unwrapped: RESPValue {
        if case .attributed(_, let value) = self { return value.unwrapped }
        return self
    }

    public var isNull: Bool {
        if case .null = unwrapped { return true }
        return false
    }

    public var serverError: RedisServerError? {
        if case .error(let error) = unwrapped { return error }
        return nil
    }

    /// Raw bytes of string-like replies.
    public var bytes: [UInt8]? {
        switch unwrapped {
        case .bulkString(let bytes), .verbatimString(_, let bytes): bytes
        case .simpleString(let string), .bigNumber(let string): Array(string.utf8)
        default: nil
        }
    }

    /// String-like replies decoded as UTF-8 (lossy), plus integers and doubles in textual form.
    public var string: String? {
        switch unwrapped {
        case .simpleString(let string), .bigNumber(let string): string
        case .bulkString(let bytes), .verbatimString(_, let bytes): String(decoding: bytes, as: UTF8.self)
        case .integer(let value): String(value)
        case .double(let value): String(value)
        default: nil
        }
    }

    /// Integer replies, or string replies that contain an integer (common in RESP2).
    public var int: Int64? {
        switch unwrapped {
        case .integer(let value): value
        case .bulkString(let bytes): Int64(String(decoding: bytes, as: UTF8.self))
        case .simpleString(let string): Int64(string)
        case .boolean(let value): value ? 1 : 0
        default: nil
        }
    }

    public var double: Double? {
        switch unwrapped {
        case .double(let value): value
        case .integer(let value): Double(value)
        case .bulkString(let bytes): Double(String(decoding: bytes, as: UTF8.self))
        case .simpleString(let string): Double(string)
        default: nil
        }
    }

    /// Elements of arrays, sets and pushes.
    public var array: [RESPValue]? {
        switch unwrapped {
        case .array(let values), .set(let values), .push(let values): values
        default: nil
        }
    }

    /// Key/value pairs of RESP3 maps, or of RESP2 flat arrays with an even number of elements
    /// (how RESP2 servers encode maps such as `HGETALL` or `CONFIG GET`).
    public var pairs: [RESPPair]? {
        switch unwrapped {
        case .map(let pairs): return pairs
        case .array(let values) where values.count.isMultiple(of: 2):
            var pairs: [RESPPair] = []
            pairs.reserveCapacity(values.count / 2)
            var index = 0
            while index < values.count {
                pairs.append(RESPPair(values[index], values[index + 1]))
                index += 2
            }
            return pairs
        default: return nil
        }
    }

    /// Looks up a value in a map reply by string key (linear; for small metadata maps like `HELLO`).
    public subscript(key: String) -> RESPValue? {
        pairs?.first { $0.key.string == key }?.value
    }

    /// Throws if this is an error reply; otherwise returns `self`.
    @discardableResult
    public func throwIfError() throws -> RESPValue {
        if let error = serverError { throw error }
        return self
    }
}

extension RESPValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .bulkString(Array(value.utf8)) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(arrayLiteral elements: RESPValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
}
