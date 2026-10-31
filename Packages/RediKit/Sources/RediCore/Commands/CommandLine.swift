import RedisWire

/// Splits a command line into arguments with `redis-cli` (sdssplitargs) quoting rules:
/// - `"double quotes"` support `\n \r \t \b \a \\ \" \xHH` escapes
/// - `'single quotes'` support only `\'`
/// - a closing quote must be followed by whitespace or the end of the line
public enum CommandLineParser {
    public enum Error: Swift.Error, Sendable, Hashable, CustomStringConvertible {
        case unbalancedQuotes
        case invalidQuoteTermination

        public var description: String {
            switch self {
            case .unbalancedQuotes: "Invalid argument(s): unbalanced quotes"
            case .invalidQuoteTermination: "Invalid argument(s): a closing quote must be followed by a space"
            }
        }
    }

    public static func split(_ line: String) throws(Error) -> [[UInt8]] {
        let bytes = Array(line.utf8)
        var arguments: [[UInt8]] = []
        var i = 0
        func isSpace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 11 || byte == 12 }
        func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 97...102: byte - 87
            case 65...70: byte - 55
            default: nil
            }
        }

        while true {
            while i < bytes.count, isSpace(bytes[i]) { i += 1 }
            guard i < bytes.count else { return arguments }
            var current: [UInt8] = []
            var inDouble = false
            var inSingle = false
            var done = false
            while !done {
                if inDouble {
                    guard i < bytes.count else { throw .unbalancedQuotes }
                    let byte = bytes[i]
                    if byte == UInt8(ascii: "\\"), i + 3 < bytes.count, bytes[i + 1] == UInt8(ascii: "x"),
                       let high = hexValue(bytes[i + 2]), let low = hexValue(bytes[i + 3]) {
                        current.append(high << 4 | low)
                        i += 3
                    } else if byte == UInt8(ascii: "\\"), i + 1 < bytes.count {
                        i += 1
                        switch bytes[i] {
                        case UInt8(ascii: "n"): current.append(10)
                        case UInt8(ascii: "r"): current.append(13)
                        case UInt8(ascii: "t"): current.append(9)
                        case UInt8(ascii: "b"): current.append(8)
                        case UInt8(ascii: "a"): current.append(7)
                        default: current.append(bytes[i])
                        }
                    } else if byte == UInt8(ascii: "\"") {
                        if i + 1 < bytes.count, !isSpace(bytes[i + 1]) { throw .invalidQuoteTermination }
                        done = true
                    } else {
                        current.append(byte)
                    }
                } else if inSingle {
                    guard i < bytes.count else { throw .unbalancedQuotes }
                    let byte = bytes[i]
                    if byte == UInt8(ascii: "\\"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "'") {
                        i += 1
                        current.append(UInt8(ascii: "'"))
                    } else if byte == UInt8(ascii: "'") {
                        if i + 1 < bytes.count, !isSpace(bytes[i + 1]) { throw .invalidQuoteTermination }
                        done = true
                    } else {
                        current.append(byte)
                    }
                } else {
                    if i >= bytes.count { break }
                    let byte = bytes[i]
                    if isSpace(byte) {
                        done = true
                    } else if byte == UInt8(ascii: "\"") {
                        inDouble = true
                    } else if byte == UInt8(ascii: "'") {
                        inSingle = true
                    } else {
                        current.append(byte)
                    }
                }
                if i < bytes.count { i += 1 }
                if done { break }
            }
            arguments.append(current)
        }
    }

    /// Quotes an argument so `split` returns it unchanged (used when re-displaying commands).
    public static func quote(_ argument: [UInt8]) -> String {
        let needsQuotes = argument.isEmpty || argument.contains { $0 <= 32 || $0 >= 127 || $0 == 34 || $0 == 39 || $0 == 92 }
        guard needsQuotes else { return String(decoding: argument, as: UTF8.self) }
        return "\"" + ReplyFormatter.repr(argument) + "\""
    }
}

/// Renders replies the way `redis-cli` does in a terminal.
public enum ReplyFormatter {
    public static func cliText(_ value: RESPValue) -> String {
        var output = ""
        render(value, indent: 0, into: &output)
        return output
    }

    private static func render(_ value: RESPValue, indent: Int, into output: inout String) {
        switch value {
        case .simpleString(let text): output += text
        case .error(let error): output += "(error) " + error.message
        case .integer(let number): output += "(integer) \(number)"
        case .double(let number): output += "(double) \(formatDouble(number))"
        case .bigNumber(let text): output += "(big number) \(text)"
        case .boolean(let flag): output += flag ? "(true)" : "(false)"
        case .null: output += "(nil)"
        case .bulkString(let bytes): output += "\"" + repr(bytes) + "\""
        case .verbatimString(_, let bytes): output += String(decoding: bytes, as: UTF8.self)
        case .attributed(_, let inner): render(inner, indent: indent, into: &output)
        case .array(let values): renderList(values, marker: ")", empty: "(empty array)", indent: indent, into: &output)
        case .set(let values): renderList(values, marker: "~", empty: "(empty set)", indent: indent, into: &output)
        case .push(let values): renderList(values, marker: ")", empty: "(empty push)", indent: indent, into: &output)
        case .map(let pairs):
            guard !pairs.isEmpty else {
                output += "(empty hash)"
                return
            }
            let width = String(pairs.count).count
            for (index, pair) in pairs.enumerated() {
                if index > 0 { output += "\n" + String(repeating: " ", count: indent) }
                let label = String(index + 1)
                let prefix = String(repeating: " ", count: width - label.count) + label + "# "
                output += prefix
                render(pair.key, indent: indent + prefix.count, into: &output)
                output += " => "
                render(pair.value, indent: indent + prefix.count, into: &output)
            }
        }
    }

    private static func renderList(_ values: [RESPValue], marker: String, empty: String, indent: Int, into output: inout String) {
        guard !values.isEmpty else {
            output += empty
            return
        }
        let width = String(values.count).count
        for (index, element) in values.enumerated() {
            if index > 0 { output += "\n" + String(repeating: " ", count: indent) }
            let label = String(index + 1)
            let prefix = String(repeating: " ", count: width - label.count) + label + marker + " "
            output += prefix
            render(element, indent: indent + prefix.count, into: &output)
        }
    }

    /// `sdscatrepr`-style escaping without the surrounding quotes.
    public static func repr(_ bytes: some Collection<UInt8>) -> String {
        var result = ""
        result.reserveCapacity(bytes.count)
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "\\"): result += "\\\\"
            case UInt8(ascii: "\""): result += "\\\""
            case 10: result += "\\n"
            case 13: result += "\\r"
            case 9: result += "\\t"
            case 7: result += "\\a"
            case 8: result += "\\b"
            case 0x20...0x7E: result.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                let hex = String(byte, radix: 16)
                result += "\\x" + (hex.count == 1 ? "0" + hex : hex)
            }
        }
        return result
    }

    private static func formatDouble(_ value: Double) -> String {
        if value.isInfinite { return value > 0 ? "inf" : "-inf" }
        if value.isNaN { return "nan" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }
}
