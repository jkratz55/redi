import Foundation

/// How a binary value is shown and edited.
public enum ValueFormat: String, CaseIterable, Sendable, Codable, Identifiable {
    case text
    case json
    case messagePack
    case ascii
    case hex
    case binary
    case float32Vector

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .text: "Unicode"
        case .json: "JSON"
        case .messagePack: "MessagePack"
        case .ascii: "ASCII"
        case .hex: "HEX"
        case .binary: "Binary"
        case .float32Vector: "Vector (Float32)"
        }
    }

    /// Whether text in this format can be converted back to bytes for editing.
    public var isEditable: Bool {
        switch self {
        case .text, .json, .ascii, .hex: true
        case .messagePack, .binary, .float32Vector: false
        }
    }
}

public enum ValueFormatter {
    public enum ParseError: Error, Sendable, CustomStringConvertible {
        case invalidJSON
        case invalidHex
        case invalidEscape

        public var description: String {
            switch self {
            case .invalidJSON: "The text isn't valid JSON."
            case .invalidHex: "Hex values must be pairs of 0-9 / a-f."
            case .invalidEscape: "Invalid escape sequence. Use \\xHH, \\n, \\r, \\t, \\\\ or \\\"."
            }
        }
    }

    /// The best initial format: JSON for JSON documents, Unicode for valid UTF-8 text, MessagePack for
    /// a MessagePack map or array, HEX otherwise.
    public static func detect(_ bytes: some Collection<UInt8>) -> ValueFormat {
        guard !bytes.isEmpty else { return .text }
        guard isText(bytes) else { return MessagePack.isDocument(bytes) ? .messagePack : .hex }
        if let first = bytes.first(where: { !isWhitespace($0) }),
           first == UInt8(ascii: "{") || first == UInt8(ascii: "["),
           (try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed])) != nil {
            return .json
        }
        return .text
    }

    /// The best initial format for a collection's values (hash values, list elements, members…):
    /// MessagePack when a sample of them is MessagePack, Unicode otherwise. Text values are skipped,
    /// so a hash mixing plain fields with MessagePack ones still counts.
    public static func detect(elements values: some Sequence<[UInt8]>) -> ValueFormat {
        var sawDocument = false
        for value in values.prefix(32) where !value.isEmpty && !isText(value.prefix(256)) {
            guard MessagePack.isSingleValue(value) else { return .text }
            if MessagePack.isContainerMarker(value[0]) { sawDocument = true }
        }
        return sawDocument ? .messagePack : .text
    }

    /// MessagePack text for one collection element, or `nil` when it should show as it is: when it's
    /// printable text (a lone digit is also a MessagePack integer, but far more likely text) or isn't
    /// exactly one MessagePack value.
    public static func messagePackElement(_ bytes: some Collection<UInt8>, style: MessagePack.Style = .pretty,
                                          limit: Int = .max) -> String? {
        guard !bytes.isEmpty, !isText(bytes.prefix(256)) else { return nil }
        return try? MessagePack.render(bytes, style: style, single: true, limit: limit)
    }

    /// One line of text for a table cell showing a collection element in `format`.
    public static func cellText(_ bytes: [UInt8], as format: ValueFormat, limit: Int = 4096) -> String {
        let more = bytes.count > limit ? "…" : ""
        switch format {
        case .text, .json:
            return preview(bytes, limit: limit)
        case .messagePack:
            return messagePackElement(bytes, style: .compact, limit: limit) ?? preview(bytes, limit: limit)
        case .ascii:
            return escaped(bytes.prefix(limit)) + more
        case .hex:
            return bytes.prefix(limit / 3).map { String(format: "%02x", $0) }.joined(separator: " ") + (bytes.count > limit / 3 ? "…" : "")
        case .binary, .float32Vector:
            let prefix = Array(bytes.prefix(limit / 9 / 4 * 4))
            guard format == .binary || bytes.count % 4 == 0 else { return render(bytes, as: format) }
            return render(prefix, as: format) + (bytes.count > prefix.count ? "…" : "")
        }
    }

    /// The full text of a collection element in `format`, for copying and viewing.
    public static func elementText(_ bytes: [UInt8], as format: ValueFormat) -> String {
        switch format {
        case .text: String(decoding: bytes, as: UTF8.self)
        case .messagePack: messagePackElement(bytes) ?? String(decoding: bytes, as: UTF8.self)
        default: render(bytes, as: format)
        }
    }

    /// Valid UTF-8 without control characters other than tab/newline/carriage return.
    public static func isText(_ bytes: some Collection<UInt8>) -> Bool {
        guard String(validating: bytes, as: UTF8.self) != nil else { return false }
        return !bytes.contains { $0 < 0x20 && $0 != 9 && $0 != 10 && $0 != 13 || $0 == 0x7F }
    }

    /// Renders bytes. `limit` caps the input considered, keeping huge values cheap to display.
    public static func render(_ bytes: [UInt8], as format: ValueFormat, limit: Int = .max) -> String {
        let slice = bytes.count > limit ? bytes[..<limit] : bytes[...]
        switch format {
        case .text: return String(decoding: slice, as: UTF8.self)
        case .json: return prettyJSON(String(decoding: slice, as: UTF8.self))
        case .messagePack:
            do { return try MessagePack.render(slice) } catch { return String(describing: error) }
        case .ascii: return escaped(slice)
        case .hex: return hexDump(slice)
        case .binary: return slice.map { byte in
            let bits = String(byte, radix: 2)
            return String(repeating: "0", count: 8 - bits.count) + bits
        }.joined(separator: " ")
        case .float32Vector:
            guard slice.count % 4 == 0 else { return "Not a Float32 vector (\(slice.count) bytes isn't a multiple of 4)." }
            let values = stride(from: slice.startIndex, to: slice.endIndex, by: 4).map { offset -> String in
                let raw = UInt32(slice[offset]) | UInt32(slice[offset + 1]) << 8 | UInt32(slice[offset + 2]) << 16 | UInt32(slice[offset + 3]) << 24
                return String(Float(bitPattern: raw))
            }
            return "[" + values.joined(separator: ", ") + "]"
        }
    }

    /// One-line preview for table cells (escapes control bytes; truncated).
    public static func preview(_ bytes: some Collection<UInt8>, limit: Int = 512) -> String {
        let prefix = bytes.prefix(limit)
        var text = isText(prefix) || String(validating: prefix, as: UTF8.self) != nil
            ? String(decoding: prefix, as: UTF8.self).replacingOccurrences(of: "\n", with: "↵ ")
            : escaped(prefix)
        if bytes.count > limit { text += "…" }
        return text
    }

    /// Converts edited text back to bytes.
    public static func parse(_ text: String, as format: ValueFormat) throws(ParseError) -> [UInt8] {
        switch format {
        case .text: return Array(text.utf8)
        case .json:
            let data = Data(text.utf8)
            guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { throw .invalidJSON }
            return Array(data)
        case .ascii: return try unescape(text)
        case .hex:
            let digits = text.split(separator: "\n").map { line -> Substring in
                // Accept our own hex dump format: drop the offset column and ASCII gutter.
                var trimmed = line
                if let colon = trimmed.firstIndex(of: ":"), trimmed.distance(from: trimmed.startIndex, to: colon) == 8 {
                    trimmed = trimmed[trimmed.index(after: colon)...]
                }
                if let gutter = trimmed.range(of: "  |") { trimmed = trimmed[..<gutter.lowerBound] }
                return trimmed
            }.joined().filter { !$0.isWhitespace }
            guard digits.count.isMultiple(of: 2) else { throw .invalidHex }
            var bytes: [UInt8] = []
            var index = digits.startIndex
            while index < digits.endIndex {
                let next = digits.index(index, offsetBy: 2)
                guard let byte = UInt8(digits[index..<next], radix: 16) else { throw .invalidHex }
                bytes.append(byte)
                index = next
            }
            return bytes
        case .messagePack, .binary, .float32Vector:
            return Array(text.utf8)
        }
    }

    /// `redis-cli`-style escaping: printable ASCII as-is, `\n`, `\r`, `\t`, `\"`, `\\`, otherwise `\xHH`.
    public static func escaped(_ bytes: some Collection<UInt8>) -> String {
        var result = ""
        result.reserveCapacity(bytes.count)
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "\\"): result += "\\\\"
            case UInt8(ascii: "\""): result += "\\\""
            case 10: result += "\\n"
            case 13: result += "\\r"
            case 9: result += "\\t"
            case 0x20...0x7E: result.unicodeScalars.append(Unicode.Scalar(byte))
            default: result += String(format: "\\x%02x", byte)
            }
        }
        return result
    }

    public static func unescape(_ text: String) throws(ParseError) -> [UInt8] {
        var bytes: [UInt8] = []
        let utf8 = Array(text.utf8)
        var i = 0
        while i < utf8.count {
            let byte = utf8[i]
            guard byte == UInt8(ascii: "\\"), i + 1 < utf8.count else {
                bytes.append(byte)
                i += 1
                continue
            }
            switch utf8[i + 1] {
            case UInt8(ascii: "n"): bytes.append(10); i += 2
            case UInt8(ascii: "r"): bytes.append(13); i += 2
            case UInt8(ascii: "t"): bytes.append(9); i += 2
            case UInt8(ascii: "\\"): bytes.append(UInt8(ascii: "\\")); i += 2
            case UInt8(ascii: "\""): bytes.append(UInt8(ascii: "\"")); i += 2
            case UInt8(ascii: "x"):
                guard i + 3 < utf8.count, let value = UInt8(String(decoding: utf8[(i + 2)...(i + 3)], as: UTF8.self), radix: 16) else {
                    throw .invalidEscape
                }
                bytes.append(value)
                i += 4
            default: throw .invalidEscape
            }
        }
        return bytes
    }

    /// `hexdump -C`-style: offset, 16 bytes, ASCII gutter.
    public static func hexDump(_ bytes: some Collection<UInt8>) -> String {
        let array = Array(bytes)
        var lines: [String] = []
        lines.reserveCapacity(array.count / 16 + 1)
        var offset = 0
        while offset < array.count {
            let row = array[offset..<min(offset + 16, array.count)]
            var hex = row.map { String(format: "%02x", $0) }
            if hex.count > 8 { hex.insert("", at: 8) }
            let padded = hex.joined(separator: " ").padding(toLength: 49, withPad: " ", startingAt: 0)
            let ascii = String(row.map { (0x20...0x7E).contains($0) ? Character(Unicode.Scalar($0)) : "." })
            lines.append(String(format: "%08x: ", offset) + padded + "  |" + ascii + "|")
            offset += 16
        }
        return lines.joined(separator: "\n")
    }

    /// Re-indents JSON without reordering keys or reformatting numbers. Invalid JSON is returned unchanged.
    public static func prettyJSON(_ text: String, indent: String = "  ") -> String {
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil else { return text }
        var output = ""
        output.reserveCapacity(text.utf8.count * 2)
        var level = 0
        var inString = false
        var escaping = false
        var previous: Character = " "
        func newline() { output.append("\n"); output.append(String(repeating: indent, count: level)) }
        for character in text {
            if inString {
                output.append(character)
                if escaping { escaping = false } else if character == "\\" { escaping = true } else if character == "\"" { inString = false }
                previous = character
                continue
            }
            switch character {
            case "\"":
                inString = true
                output.append(character)
            case "{", "[":
                output.append(character)
                level += 1
                newline()
            case "}", "]":
                level -= 1
                if previous == "{" || previous == "[" {
                    // Empty container: collapse the newline we just wrote.
                    while output.last?.isWhitespace == true { output.removeLast() }
                } else {
                    newline()
                }
                output.append(character)
            case ",":
                output.append(character)
                newline()
            case ":":
                output.append(": ")
            case " ", "\n", "\r", "\t":
                continue
            default:
                output.append(character)
            }
            previous = character
        }
        return output
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }
}

extension Int64 {
    /// Human-readable TTL, e.g. `2d 3h`, `45s`, `350ms`.
    public var ttlDescription: String {
        let milliseconds = self
        if milliseconds < 1000 { return "\(milliseconds)ms" }
        var seconds = milliseconds / 1000
        let days = seconds / 86_400; seconds %= 86_400
        let hours = seconds / 3600; seconds %= 3600
        let minutes = seconds / 60; seconds %= 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m" }
        return "\(seconds)s"
    }
}
