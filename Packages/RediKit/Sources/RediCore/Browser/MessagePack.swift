import Foundation

/// Read-only MessagePack support: validation and rendering as JSON-like text.
///
/// Values JSON can express render as JSON. The rest use readable extensions, so the text is never
/// ambiguous about what's stored:
/// - binary (`bin`): `b"\x01abc"`, escaped like redis-cli
/// - extension types: `ext(5, b"…")`; timestamps (type -1): `timestamp(2023-11-14T22:13:20.123Z)`
/// - map keys that aren't strings render as themselves: `{1: "one"}`
/// - non-finite floats: `NaN`, `Infinity`, `-Infinity`
/// - `str` payloads that aren't valid UTF-8 use `\xHH` escapes
///
/// Decoding is a single pass with no intermediate tree. Nesting depth is bounded and every length is
/// checked against the bytes that remain, so corrupt or hostile data fails fast instead of allocating.
public enum MessagePack {
    public struct DecodeError: Error, Sendable, Hashable, CustomStringConvertible {
        public enum Reason: Sendable, Hashable {
            /// There are no bytes at all.
            case empty
            /// The data ends before the value starting at `offset` is complete.
            case truncated
            /// 0xc1 is reserved and never appears in MessagePack.
            case reservedByte
            /// Containers nest deeper than `MessagePack.maximumDepth`.
            case tooDeep
            /// More bytes follow the value, when exactly one value was expected.
            case trailingBytes
        }

        public let reason: Reason
        /// Byte offset of the value that couldn't be decoded.
        public let offset: Int

        public var description: String {
            switch reason {
            case .empty: "Not valid MessagePack: the value is empty."
            case .truncated: "Not valid MessagePack: the data ends before the value at byte \(offset) is complete."
            case .reservedByte: "Not valid MessagePack: byte \(offset) is 0xc1, which MessagePack never uses."
            case .tooDeep: "Not valid MessagePack: values are nested more than \(MessagePack.maximumDepth) levels deep."
            case .trailingBytes: "Not valid MessagePack: unexpected bytes after the value, starting at byte \(offset)."
            }
        }
    }

    public enum Style: Sendable {
        /// Indented, one entry per line.
        case pretty
        /// A single line, for table cells.
        case compact
    }

    public static let maximumDepth = 512

    /// Whether `bytes` holds exactly one MessagePack value.
    public static func isSingleValue(_ bytes: some Collection<UInt8>) -> Bool {
        withBuffer(bytes) { buffer in
            var decoder = Decoder(input: buffer, emits: false, pretty: false, limit: .max)
            return (try? decoder.document(single: true)) != nil
        }
    }

    /// Whether `bytes` is exactly one MessagePack map or array: the shape of a serialized object,
    /// which (unlike a lone scalar) is unlikely to occur by chance in other binary data.
    public static func isDocument(_ bytes: some Collection<UInt8>) -> Bool {
        guard let first = bytes.first, isContainerMarker(first) else { return false }
        return isSingleValue(bytes)
    }

    /// Whether `byte` starts a map or an array.
    public static func isContainerMarker(_ byte: UInt8) -> Bool {
        (0x80...0x9F).contains(byte) || (0xDC...0xDF).contains(byte)
    }

    /// Renders `bytes` as text. Concatenated values (a MessagePack stream) render one after another,
    /// unless `single` requires exactly one.
    /// - Parameter limit: the most UTF-8 bytes of output to produce; longer output is cut and ends
    ///   in "…". Decoding stops there too, so a huge value is cheap to preview.
    public static func render(_ bytes: some Collection<UInt8>, style: Style = .pretty, single: Bool = false,
                              limit: Int = .max) throws(DecodeError) -> String {
        let result: Result<String, DecodeError> = withBuffer(bytes) { buffer in
            var decoder = Decoder(input: buffer, emits: true, pretty: style == .pretty, limit: limit)
            do throws(Stop) {
                try decoder.document(single: single)
            } catch {
                switch error {
                case .limit: return .success(decoder.truncatedOutput())
                case .invalid(let error): return .failure(error)
                }
            }
            return .success(String(decoding: decoder.output, as: UTF8.self))
        }
        return try result.get()
    }

    private static func withBuffer<R>(_ bytes: some Collection<UInt8>, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        if let result = bytes.withContiguousStorageIfAvailable(body) { return result }
        return Array(bytes).withUnsafeBufferPointer(body)
    }

    // MARK: - Decoder

    private enum Stop: Error {
        case invalid(DecodeError)
        /// The output reached its limit.
        case limit
    }

    private struct Frame {
        let isMap: Bool
        /// Items still to read; a map counts keys and values separately.
        var items: Int
        let start: Int
    }

    private struct Decoder {
        let input: UnsafeBufferPointer<UInt8>
        let emits: Bool
        let pretty: Bool
        let limit: Int
        var position = 0
        /// Containers still being read, innermost last.
        var frames: [Frame] = []
        /// Start of the scalar being read, for error offsets.
        var valueStart = 0
        var output: [UInt8] = []

        init(input: UnsafeBufferPointer<UInt8>, emits: Bool, pretty: Bool, limit: Int) {
            self.input = input
            self.emits = emits
            self.pretty = pretty
            self.limit = limit
            if emits { output.reserveCapacity(min(input.count * 2, limit == .max ? Int.max : limit + 64, 1 << 24)) }
        }

        var remaining: Int { input.count - position }

        mutating func document(single: Bool) throws(Stop) {
            guard !input.isEmpty else { throw invalid(.empty, at: 0) }
            var count = 0
            while position < input.count {
                if count > 0 {
                    guard !single else { throw invalid(.trailingBytes, at: position) }
                    emit(pretty ? 10 : 32)
                }
                try value()
                count += 1
            }
        }

        func invalid(_ reason: DecodeError.Reason, at offset: Int) -> Stop {
            .invalid(DecodeError(reason: reason, offset: offset))
        }

        // MARK: Reading

        mutating func byte() throws(Stop) -> UInt8 {
            guard position < input.count else { throw invalid(.truncated, at: valueStart) }
            defer { position += 1 }
            return input[position]
        }

        /// A big-endian unsigned integer of `size` bytes.
        mutating func integer(_ size: Int) throws(Stop) -> UInt64 {
            guard remaining >= size else { throw invalid(.truncated, at: valueStart) }
            var value: UInt64 = 0
            for offset in position..<(position + size) { value = value << 8 | UInt64(input[offset]) }
            position += size
            return value
        }

        mutating func length(_ size: Int) throws(Stop) -> Int {
            Int(try integer(size))
        }

        mutating func take(_ count: Int) throws(Stop) -> UnsafeBufferPointer<UInt8> {
            guard count <= remaining else { throw invalid(.truncated, at: valueStart) }
            defer { position += count }
            return UnsafeBufferPointer(rebasing: input[position..<(position + count)])
        }

        /// One complete value, nested containers included. Iterative, with the open containers on an
        /// explicit stack, so nesting depth never depends on the calling thread's stack size.
        mutating func value() throws(Stop) {
            while true {
                let start = position
                valueStart = start
                let marker = try byte()
                let isOpen: Bool
                switch marker {
                case 0x80...0x8F: isOpen = try open(isMap: true, count: Int(marker & 0x0F), start: start)
                case 0x90...0x9F: isOpen = try open(isMap: false, count: Int(marker & 0x0F), start: start)
                case 0xDC, 0xDD: isOpen = try open(isMap: false, count: try length(marker == 0xDC ? 2 : 4), start: start)
                case 0xDE, 0xDF: isOpen = try open(isMap: true, count: try length(marker == 0xDE ? 2 : 4), start: start)
                default:
                    try scalar(marker, start: start)
                    isOpen = false
                }
                try checkLimit()
                // A complete item: close every container it completes, then separate it from the next.
                while !isOpen, let top = frames.last {
                    frames[frames.count - 1].items -= 1
                    let items = top.items - 1
                    if items > 0 {
                        if top.isMap, !items.isMultiple(of: 2) {
                            emit(": ")
                        } else {
                            emit(pretty ? "," : ", ")
                            if pretty { newline() }
                        }
                        break
                    }
                    frames.removeLast()
                    if pretty { newline() }
                    emit(top.isMap ? UInt8(ascii: "}") : UInt8(ascii: "]"))
                    try checkLimit()
                }
                guard let top = frames.last else { return }
                guard position < input.count else { throw invalid(.truncated, at: top.start) }
            }
        }

        /// A map or array header. Returns whether it stays open on `frames`; empty ones are complete at once.
        mutating func open(isMap: Bool, count: Int, start: Int) throws(Stop) -> Bool {
            // Every array element takes at least one byte, every map entry at least two.
            guard count <= (isMap ? remaining / 2 : remaining) else { throw invalid(.truncated, at: start) }
            guard frames.count < MessagePack.maximumDepth else { throw invalid(.tooDeep, at: start) }
            guard count > 0 else {
                emit(isMap ? "{}" : "[]")
                return false
            }
            emit(isMap ? UInt8(ascii: "{") : UInt8(ascii: "["))
            frames.append(Frame(isMap: isMap, items: isMap ? count * 2 : count, start: start))
            if pretty { newline() }
            return true
        }

        mutating func scalar(_ marker: UInt8, start: Int) throws(Stop) {
            switch marker {
            case 0x00...0x7F: emit(unsigned: UInt64(marker))
            case 0xA0...0xBF: try string(try take(Int(marker & 0x1F)))
            case 0xC0: emit("null")
            case 0xC1: throw invalid(.reservedByte, at: start)
            case 0xC2: emit("false")
            case 0xC3: emit("true")
            case 0xC4...0xC6: try binary(try take(try length(1 << Int(marker - 0xC4))))
            case 0xC7...0xC9: try ext(length: try length(1 << Int(marker - 0xC7)))
            case 0xCA: emit(float: Float(bitPattern: UInt32(try integer(4))))
            case 0xCB: emit(double: Double(bitPattern: try integer(8)))
            case 0xCC...0xCF: emit(unsigned: try integer(1 << Int(marker - 0xCC)))
            case 0xD0...0xD3:
                let size = 1 << Int(marker - 0xD0)
                let shift = UInt64(64 - size * 8)
                emit(signed: Int64(bitPattern: try integer(size) << shift) >> shift)
            case 0xD4...0xD8: try ext(length: 1 << Int(marker - 0xD4))
            case 0xD9...0xDB: try string(try take(try length(1 << Int(marker - 0xD9))))
            default: emit(signed: Int64(Int8(bitPattern: marker))) // 0xe0...0xff: negative fixint
            }
        }

        mutating func newline() {
            guard emits else { return }
            output.append(10)
            for _ in 0..<frames.count { output.append(32); output.append(32) }
        }

        mutating func ext(length: Int) throws(Stop) {
            let type = Int8(bitPattern: try byte())
            let data = try take(length)
            guard emits else { return }
            if type == -1, let timestamp = Self.timestamp(data) {
                emit("timestamp(\(timestamp))")
            } else {
                emit("ext(\(type), ")
                try binary(data)
                emit(UInt8(ascii: ")"))
            }
        }

        // MARK: Writing

        mutating func checkLimit() throws(Stop) {
            if output.count > limit { throw .limit }
        }

        /// How many payload bytes are worth writing before the output limit: each payload byte
        /// produces at least one output byte.
        func budget(_ count: Int) -> Int {
            limit == .max ? count : min(count, max(0, limit - output.count + 1))
        }

        mutating func emit(_ byte: UInt8) {
            if emits { output.append(byte) }
        }

        mutating func emit(_ text: String) {
            if emits { output.append(contentsOf: text.utf8) }
        }

        mutating func emit(unsigned value: UInt64) { if emits { emit(String(value)) } }
        mutating func emit(signed value: Int64) { if emits { emit(String(value)) } }

        mutating func emit(double value: Double) {
            guard emits else { return }
            emit(value.isNaN ? "NaN" : value.isInfinite ? (value < 0 ? "-Infinity" : "Infinity") : value.description)
        }

        mutating func emit(float value: Float) {
            guard emits else { return }
            emit(value.isNaN ? "NaN" : value.isInfinite ? (value < 0 ? "-Infinity" : "Infinity") : value.description)
        }

        /// A `str`: JSON-escaped when it's valid UTF-8 (the spec requires it, but not every encoder
        /// complies), `\xHH`-escaped otherwise.
        mutating func string(_ payload: UnsafeBufferPointer<UInt8>) throws(Stop) {
            guard emits else { return }
            var count = budget(payload.count)
            // Don't split a UTF-8 sequence when cutting at the output limit.
            while count < payload.count, count > 0, payload[count] & 0xC0 == 0x80 { count -= 1 }
            let visible = UnsafeBufferPointer(rebasing: payload[..<count])
            guard visible.allSatisfy({ $0 < 0x80 }) || String(validating: visible, as: UTF8.self) != nil else {
                return try binary(payload, prefix: "")
            }
            output.append(UInt8(ascii: "\""))
            for byte in visible {
                switch byte {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"): escape(byte)
                case 10: escape(UInt8(ascii: "n"))
                case 13: escape(UInt8(ascii: "r"))
                case 9: escape(UInt8(ascii: "t"))
                case 8: escape(UInt8(ascii: "b"))
                case 12: escape(UInt8(ascii: "f"))
                case 0..<0x20, 0x7F: output.append(contentsOf: String(format: "\\u%04x", byte).utf8)
                default: output.append(byte)
                }
            }
            if visible.count < payload.count { throw .limit }
            try checkLimit()
            output.append(UInt8(ascii: "\""))
        }

        mutating func escape(_ byte: UInt8) {
            output.append(UInt8(ascii: "\\"))
            output.append(byte)
        }

        mutating func binary(_ payload: UnsafeBufferPointer<UInt8>, prefix: String = "b") throws(Stop) {
            guard emits else { return }
            let visible = UnsafeBufferPointer(rebasing: payload[..<budget(payload.count)])
            emit(prefix + "\"" + ValueFormatter.escaped(visible))
            if visible.count < payload.count { throw .limit }
            try checkLimit()
            emit(UInt8(ascii: "\""))
        }

        /// The output cut at `limit` on a character boundary, ending in "…".
        func truncatedOutput() -> String {
            var end = min(limit, output.count)
            while end > 0, end < output.count, output[end] & 0xC0 == 0x80 { end -= 1 }
            return String(decoding: output[..<end], as: UTF8.self) + "…"
        }

        /// Decodes the timestamp extension (type -1) as RFC 3339 in UTC, or `nil` when malformed.
        static func timestamp(_ data: UnsafeBufferPointer<UInt8>) -> String? {
            func bigEndian(_ range: Range<Int>) -> UInt64 { range.reduce(0) { $0 << 8 | UInt64(data[$1]) } }
            let seconds: Int64
            let nanoseconds: UInt64
            switch data.count {
            case 4:
                seconds = Int64(bigEndian(0..<4))
                nanoseconds = 0
            case 8:
                let packed = bigEndian(0..<8)
                nanoseconds = packed >> 34
                seconds = Int64(packed & 0x3_FFFF_FFFF)
            case 12:
                nanoseconds = bigEndian(0..<4)
                seconds = Int64(bitPattern: bigEndian(4..<12))
            default:
                return nil
            }
            guard nanoseconds < 1_000_000_000 else { return nil }
            return rfc3339(seconds: seconds, nanoseconds: Int(nanoseconds))
        }

        /// Proleptic Gregorian date for any `Int64` second count, without Foundation's `Date`
        /// (which would round nanoseconds and limit the range).
        static func rfc3339(seconds: Int64, nanoseconds: Int) -> String {
            var (days, secondOfDay) = seconds.quotientAndRemainder(dividingBy: 86_400)
            if secondOfDay < 0 { days -= 1; secondOfDay += 86_400 }
            // Howard Hinnant's civil_from_days.
            let z = days + 719_468
            let era = (z >= 0 ? z : z - 146_096) / 146_097
            let dayOfEra = z - era * 146_097
            let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
            let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
            let shiftedMonth = (5 * dayOfYear + 2) / 153
            let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
            let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
            let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)

            func padded(_ value: Int64, _ width: Int) -> String {
                let digits = String(value)
                return String(repeating: "0", count: max(0, width - digits.count)) + digits
            }
            var text = (year < 0 ? "-" + padded(-year, 4) : padded(year, 4))
            text += "-\(padded(month, 2))-\(padded(day, 2))T\(padded(secondOfDay / 3600, 2)):"
            text += "\(padded(secondOfDay / 60 % 60, 2)):\(padded(secondOfDay % 60, 2))"
            if nanoseconds > 0 {
                var fraction = padded(Int64(nanoseconds), 9)
                while fraction.last == "0" { fraction.removeLast() }
                text += "." + fraction
            }
            return text + "Z"
        }
    }
}
