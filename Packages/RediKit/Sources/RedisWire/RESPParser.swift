#if canImport(Darwin)
import Darwin
#endif

/// A malformed or unsupported byte sequence in the RESP stream. The stream can't be resynchronised
/// after this; the connection must be closed.
public struct RESPParseError: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable {
        case invalidTypeByte(UInt8)
        case invalidInteger
        case invalidLength
        case invalidDouble
        case invalidBoolean
        case invalidNull
        case invalidVerbatimString
        case missingTerminator
        case bulkTooLarge(Int)
        case aggregateTooLarge(Int)
        case nestingTooDeep
        case unsupportedStreamedType
    }

    public let kind: Kind
    /// Offset within the parser's buffer where the problem was found (diagnostics only).
    public let offset: Int

    public var description: String { "RESP protocol error: \(kind) at offset \(offset)" }
}

/// An incremental, resumable RESP2/RESP3 parser.
///
/// Feed bytes with `append(_:)` as they arrive, then call `next()` until it returns `nil` (more input
/// needed). Partially received aggregates keep their completed children between calls, so a
/// 1M-element reply arriving in many chunks is parsed in linear time. Only the element currently being
/// read is re-examined when more data arrives.
public struct RESPParser: Sendable {
    public struct Limits: Sendable {
        /// Redis' default `proto-max-bulk-len`.
        public var maxBulkLength = 512 * 1024 * 1024
        public var maxAggregateLength = Int(Int32.max)
        public var maxDepth = 512

        public init() {}
    }

    public let limits: Limits

    private var buffer: [UInt8] = []
    private var index = 0
    private var stack: [Frame] = []

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Bytes received but not yet consumed by a completed element.
    public var bufferedByteCount: Int { buffer.count - index }

    /// True when no partial reply is pending.
    public var isIdle: Bool { stack.isEmpty && index == buffer.count }

    public mutating func append(_ bytes: UnsafeRawBufferPointer) {
        compact()
        buffer.append(contentsOf: bytes)
    }

    public mutating func append(_ bytes: [UInt8]) {
        compact()
        buffer.append(contentsOf: bytes)
    }

    public mutating func append(_ bytes: some Sequence<UInt8>) {
        compact()
        buffer.append(contentsOf: bytes)
    }

    /// Returns the next complete reply, or `nil` when more input is required.
    public mutating func next() throws(RESPParseError) -> RESPValue? {
        outer: while true {
            guard let element = try parseElement() else { return nil }

            var value: RESPValue
            switch element {
            case .value(let parsed):
                value = parsed
            case .aggregate(let kind, let count):
                if count == 0 {
                    value = Frame(kind: kind, remaining: 0).build()
                } else {
                    guard stack.count < limits.maxDepth else {
                        throw RESPParseError(kind: .nestingTooDeep, offset: index)
                    }
                    stack.append(Frame(kind: kind, remaining: count))
                    continue outer
                }
            }

            // Fold the completed value into enclosing aggregates, closing every one it completes.
            while let top = stack.indices.last {
                stack[top].elements.append(value)
                stack[top].remaining -= 1
                if stack[top].remaining > 0 { continue outer }
                value = stack.removeLast().build()
            }
            return value
        }
    }

    // MARK: - Element parsing

    private enum Element {
        case value(RESPValue)
        case aggregate(AggregateKind, elementCount: Int)
    }

    private enum AggregateKind {
        case array, set, push, map, attribute
    }

    private struct Frame {
        let kind: AggregateKind
        var remaining: Int
        var elements: [RESPValue] = []

        init(kind: AggregateKind, remaining: Int) {
            self.kind = kind
            self.remaining = remaining
            // Cap the up-front reservation so a hostile length header can't force a huge allocation.
            elements.reserveCapacity(min(remaining, 1 << 14))
        }

        func build() -> RESPValue {
            switch kind {
            case .array: return .array(elements)
            case .set: return .set(elements)
            case .push: return .push(elements)
            case .map: return .map(Self.pairs(elements[...]))
            case .attribute:
                // Attributes carry 2n map elements followed by the reply they annotate.
                return .attributed(attributes: Self.pairs(elements.dropLast()), value: elements.last ?? .null)
            }
        }

        private static func pairs(_ flat: ArraySlice<RESPValue>) -> [RESPPair] {
            var pairs: [RESPPair] = []
            pairs.reserveCapacity(flat.count / 2)
            var i = flat.startIndex
            while i + 1 < flat.endIndex {
                pairs.append(RESPPair(flat[i], flat[i + 1]))
                i += 2
            }
            return pairs
        }
    }

    /// Parses one element starting at `index`. Advances `index` only when the element is complete.
    private mutating func parseElement() throws(RESPParseError) -> Element? {
        guard index < buffer.count else { return nil }
        let start = index
        let type = buffer[start]
        let lineStart = start + 1
        guard let lineEnd = findCRLF(from: lineStart) else {
            if buffer.count - start > limits.maxBulkLength {
                throw RESPParseError(kind: .missingTerminator, offset: start)
            }
            return nil
        }
        let afterLine = lineEnd + 2

        switch type {
        case UInt8(ascii: "+"):
            index = afterLine
            return .value(.simpleString(decode(lineStart, lineEnd)))

        case UInt8(ascii: "-"):
            index = afterLine
            return .value(.error(RedisServerError(decode(lineStart, lineEnd))))

        case UInt8(ascii: ":"):
            let value = try parseInteger(lineStart, lineEnd)
            index = afterLine
            return .value(.integer(value))

        case UInt8(ascii: "$"), UInt8(ascii: "!"), UInt8(ascii: "="):
            try rejectStreamed(lineStart, lineEnd)
            let length = try parseInteger(lineStart, lineEnd)
            if length == -1 && type == UInt8(ascii: "$") {
                index = afterLine
                return .value(.null)
            }
            guard length >= 0 else { throw RESPParseError(kind: .invalidLength, offset: start) }
            guard length <= limits.maxBulkLength else {
                throw RESPParseError(kind: .bulkTooLarge(Int(length)), offset: start)
            }
            let payloadEnd = afterLine + Int(length)
            guard buffer.count >= payloadEnd + 2 else { return nil }
            guard buffer[payloadEnd] == 13, buffer[payloadEnd + 1] == 10 else {
                throw RESPParseError(kind: .missingTerminator, offset: payloadEnd)
            }
            let value: RESPValue
            switch type {
            case UInt8(ascii: "$"):
                value = .bulkString(Array(buffer[afterLine..<payloadEnd]))
            case UInt8(ascii: "!"):
                value = .error(RedisServerError(decode(afterLine, payloadEnd)))
            default:
                // Verbatim: "fmt:" prefix followed by the text.
                guard length >= 4, buffer[afterLine + 3] == UInt8(ascii: ":") else {
                    throw RESPParseError(kind: .invalidVerbatimString, offset: afterLine)
                }
                value = .verbatimString(format: decode(afterLine, afterLine + 3),
                                        Array(buffer[(afterLine + 4)..<payloadEnd]))
            }
            index = payloadEnd + 2
            return .value(value)

        case UInt8(ascii: "*"), UInt8(ascii: "~"), UInt8(ascii: ">"), UInt8(ascii: "%"), UInt8(ascii: "|"):
            try rejectStreamed(lineStart, lineEnd)
            let count = try parseInteger(lineStart, lineEnd)
            if count == -1 && type == UInt8(ascii: "*") {
                index = afterLine
                return .value(.null)
            }
            guard count >= 0 else { throw RESPParseError(kind: .invalidLength, offset: start) }
            let isPairs = type == UInt8(ascii: "%") || type == UInt8(ascii: "|")
            guard count <= limits.maxAggregateLength / (isPairs ? 2 : 1) else {
                throw RESPParseError(kind: .aggregateTooLarge(Int(count)), offset: start)
            }
            let kind: AggregateKind
            var elements = Int(count)
            switch type {
            case UInt8(ascii: "*"): kind = .array
            case UInt8(ascii: "~"): kind = .set
            case UInt8(ascii: ">"): kind = .push
            case UInt8(ascii: "%"): kind = .map; elements *= 2
            default: kind = .attribute; elements = elements * 2 + 1
            }
            index = afterLine
            return .aggregate(kind, elementCount: elements)

        case UInt8(ascii: "_"):
            guard lineEnd == lineStart else { throw RESPParseError(kind: .invalidNull, offset: start) }
            index = afterLine
            return .value(.null)

        case UInt8(ascii: "#"):
            guard lineEnd == lineStart + 1 else { throw RESPParseError(kind: .invalidBoolean, offset: start) }
            let value: Bool
            switch buffer[lineStart] {
            case UInt8(ascii: "t"): value = true
            case UInt8(ascii: "f"): value = false
            default: throw RESPParseError(kind: .invalidBoolean, offset: start)
            }
            index = afterLine
            return .value(.boolean(value))

        case UInt8(ascii: ","):
            guard let value = Double(decode(lineStart, lineEnd)) else {
                throw RESPParseError(kind: .invalidDouble, offset: start)
            }
            index = afterLine
            return .value(.double(value))

        case UInt8(ascii: "("):
            index = afterLine
            return .value(.bigNumber(decode(lineStart, lineEnd)))

        default:
            throw RESPParseError(kind: .invalidTypeByte(type), offset: start)
        }
    }

    // MARK: - Helpers

    /// Drops consumed bytes. Releases the backing storage after unusually large replies so a single
    /// big value doesn't pin memory for the lifetime of the connection.
    private mutating func compact() {
        guard index > 0 else { return }
        if index == buffer.count {
            buffer.removeAll(keepingCapacity: buffer.capacity <= 1 << 20)
            index = 0
        } else if index >= 1 << 16, index * 2 >= buffer.count {
            buffer.removeSubrange(0..<index)
            index = 0
        }
    }

    /// Index of the CR in the next CRLF at or after `position`.
    private func findCRLF(from position: Int) -> Int? {
        buffer.withUnsafeBufferPointer { pointer -> Int? in
            guard let base = pointer.baseAddress else { return nil }
            var from = position
            while from < pointer.count {
                guard let hit = memchr(base + from, 13, pointer.count - from) else { return nil }
                let offset = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                guard offset + 1 < pointer.count else { return nil }
                if pointer[offset + 1] == 10 { return offset }
                from = offset + 1
            }
            return nil
        }
    }

    private func decode(_ start: Int, _ end: Int) -> String {
        String(decoding: buffer[start..<end], as: UTF8.self)
    }

    private func rejectStreamed(_ start: Int, _ end: Int) throws(RESPParseError) {
        if end == start + 1, buffer[start] == UInt8(ascii: "?") {
            throw RESPParseError(kind: .unsupportedStreamedType, offset: start)
        }
    }

    /// Parses a signed decimal. Accumulates negatively so `Int64.min` round-trips.
    private func parseInteger(_ start: Int, _ end: Int) throws(RESPParseError) -> Int64 {
        var i = start
        var negative = false
        if i < end, buffer[i] == UInt8(ascii: "-") {
            negative = true
            i += 1
        } else if i < end, buffer[i] == UInt8(ascii: "+") {
            i += 1
        }
        guard i < end else { throw RESPParseError(kind: .invalidInteger, offset: start) }

        var result: Int64 = 0
        while i < end {
            let digit = buffer[i] &- UInt8(ascii: "0")
            guard digit < 10 else { throw RESPParseError(kind: .invalidInteger, offset: i) }
            let (shifted, o1) = result.multipliedReportingOverflow(by: 10)
            let (next, o2) = shifted.subtractingReportingOverflow(Int64(digit))
            guard !o1, !o2 else { throw RESPParseError(kind: .invalidInteger, offset: start) }
            result = next
            i += 1
        }
        if negative { return result }
        guard result != .min else { throw RESPParseError(kind: .invalidInteger, offset: start) }
        return -result
    }
}
