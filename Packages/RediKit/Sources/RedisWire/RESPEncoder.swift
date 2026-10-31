/// Serialises commands (and, for tests and tooling, arbitrary replies) into RESP wire format.
public enum RESPEncoder {
    /// Appends `command` as a RESP array of bulk strings — the only form Redis accepts from clients.
    @inlinable
    public static func encode(_ command: RedisCommand, into buffer: inout [UInt8]) {
        encode(arguments: command.arguments, into: &buffer)
    }

    public static func encode(arguments: [[UInt8]], into buffer: inout [UInt8]) {
        var size = 16
        for argument in arguments { size += argument.count + 16 }
        buffer.reserveCapacity(buffer.count + size)

        buffer.append(UInt8(ascii: "*"))
        appendDecimal(arguments.count, into: &buffer)
        appendCRLF(into: &buffer)
        for argument in arguments {
            buffer.append(UInt8(ascii: "$"))
            appendDecimal(argument.count, into: &buffer)
            appendCRLF(into: &buffer)
            buffer.append(contentsOf: argument)
            appendCRLF(into: &buffer)
        }
    }

    /// Encodes a reply value in RESP3 form. Used by mock servers, fixtures and the seed tool.
    public static func encode(_ value: RESPValue, into buffer: inout [UInt8]) {
        switch value {
        case .simpleString(let string):
            buffer.append(UInt8(ascii: "+"))
            buffer.append(contentsOf: string.utf8)
            appendCRLF(into: &buffer)
        case .error(let error):
            buffer.append(UInt8(ascii: "-"))
            buffer.append(contentsOf: error.message.utf8)
            appendCRLF(into: &buffer)
        case .integer(let value):
            buffer.append(UInt8(ascii: ":"))
            appendDecimal(value, into: &buffer)
            appendCRLF(into: &buffer)
        case .bulkString(let bytes):
            appendBlob(type: "$", bytes, into: &buffer)
        case .null:
            buffer.append(UInt8(ascii: "_"))
            appendCRLF(into: &buffer)
        case .array(let values):
            appendAggregate(type: "*", values, into: &buffer)
        case .set(let values):
            appendAggregate(type: "~", values, into: &buffer)
        case .push(let values):
            appendAggregate(type: ">", values, into: &buffer)
        case .boolean(let value):
            buffer.append(UInt8(ascii: "#"))
            buffer.append(value ? UInt8(ascii: "t") : UInt8(ascii: "f"))
            appendCRLF(into: &buffer)
        case .double(let value):
            buffer.append(UInt8(ascii: ","))
            let text: String
            if value.isNaN { text = "nan" }
            else if value == .infinity { text = "inf" }
            else if value == -.infinity { text = "-inf" }
            else { text = String(value) }
            buffer.append(contentsOf: text.utf8)
            appendCRLF(into: &buffer)
        case .bigNumber(let string):
            buffer.append(UInt8(ascii: "("))
            buffer.append(contentsOf: string.utf8)
            appendCRLF(into: &buffer)
        case .verbatimString(let format, let bytes):
            var payload = Array(format.utf8.prefix(3))
            while payload.count < 3 { payload.append(UInt8(ascii: " ")) }
            payload.append(UInt8(ascii: ":"))
            payload.append(contentsOf: bytes)
            appendBlob(type: "=", payload, into: &buffer)
        case .map(let pairs):
            appendPairs(type: "%", pairs, into: &buffer)
        case .attributed(let attributes, let value):
            appendPairs(type: "|", attributes, into: &buffer)
            encode(value, into: &buffer)
        }
    }

    /// Encodes a reply value in RESP2 form, collapsing RESP3-only types the way a RESP2 server would.
    public static func encodeRESP2(_ value: RESPValue, into buffer: inout [UInt8]) {
        switch value {
        case .null:
            buffer.append(contentsOf: Array("$-1\r\n".utf8))
        case .array(let values), .set(let values), .push(let values):
            buffer.append(UInt8(ascii: "*"))
            appendDecimal(values.count, into: &buffer)
            appendCRLF(into: &buffer)
            for element in values { encodeRESP2(element, into: &buffer) }
        case .map(let pairs):
            buffer.append(UInt8(ascii: "*"))
            appendDecimal(pairs.count * 2, into: &buffer)
            appendCRLF(into: &buffer)
            for pair in pairs {
                encodeRESP2(pair.key, into: &buffer)
                encodeRESP2(pair.value, into: &buffer)
            }
        case .boolean(let value):
            encode(.integer(value ? 1 : 0), into: &buffer)
        case .double, .bigNumber:
            encode(.bulkString(value.bytes ?? Array((value.string ?? "").utf8)), into: &buffer)
        case .verbatimString(_, let bytes):
            encode(.bulkString(bytes), into: &buffer)
        case .attributed(_, let inner):
            encodeRESP2(inner, into: &buffer)
        case .simpleString, .error, .integer, .bulkString:
            encode(value, into: &buffer)
        }
    }

    // MARK: - Primitives

    @inlinable
    static func appendCRLF(into buffer: inout [UInt8]) {
        buffer.append(13)
        buffer.append(10)
    }

    @usableFromInline
    static func appendDecimal(_ value: some BinaryInteger, into buffer: inout [UInt8]) {
        if value >= 0 && value < 10 {
            buffer.append(UInt8(ascii: "0") + UInt8(value))
            return
        }
        if value < 0 { buffer.append(UInt8(ascii: "-")) }
        var magnitude = UInt64(value.magnitude)
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { digits in
            var position = 20
            repeat {
                position -= 1
                digits[position] = UInt8(ascii: "0") + UInt8(magnitude % 10)
                magnitude /= 10
            } while magnitude > 0
            buffer.append(contentsOf: UnsafeBufferPointer(rebasing: digits[position..<20]))
        }
    }

    private static func appendBlob(type: Unicode.Scalar, _ bytes: [UInt8], into buffer: inout [UInt8]) {
        buffer.append(UInt8(ascii: type))
        appendDecimal(bytes.count, into: &buffer)
        appendCRLF(into: &buffer)
        buffer.append(contentsOf: bytes)
        appendCRLF(into: &buffer)
    }

    private static func appendAggregate(type: Unicode.Scalar, _ values: [RESPValue], into buffer: inout [UInt8]) {
        buffer.append(UInt8(ascii: type))
        appendDecimal(values.count, into: &buffer)
        appendCRLF(into: &buffer)
        for element in values { encode(element, into: &buffer) }
    }

    private static func appendPairs(type: Unicode.Scalar, _ pairs: [RESPPair], into buffer: inout [UInt8]) {
        buffer.append(UInt8(ascii: type))
        appendDecimal(pairs.count, into: &buffer)
        appendCRLF(into: &buffer)
        for pair in pairs {
            encode(pair.key, into: &buffer)
            encode(pair.value, into: &buffer)
        }
    }
}
