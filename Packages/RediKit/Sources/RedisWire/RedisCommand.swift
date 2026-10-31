import Foundation

/// A command to send to Redis: a name followed by binary-safe arguments.
public struct RedisCommand: Sendable, Hashable, CustomStringConvertible {
    /// All arguments including the command name, exactly as sent on the wire.
    public var arguments: [[UInt8]]

    public init(arguments: [[UInt8]]) {
        precondition(!arguments.isEmpty, "A Redis command needs at least a name")
        self.arguments = arguments
    }

    public init(_ name: String, _ arguments: any RESPArgumentConvertible...) {
        self.init(name, arguments)
    }

    public init(_ name: String, _ arguments: [any RESPArgumentConvertible]) {
        var all: [[UInt8]] = [Array(name.utf8)]
        all.reserveCapacity(arguments.count + 1)
        for argument in arguments { all.append(argument.respArgument) }
        self.arguments = all
    }

    /// Upper-cased command name, e.g. `HGETALL`.
    public var name: String { String(decoding: arguments[0], as: UTF8.self).uppercased() }

    public mutating func append(_ argument: some RESPArgumentConvertible) {
        arguments.append(argument.respArgument)
    }

    public var description: String {
        arguments.map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ")
    }
}

/// Types that can be sent as a command argument.
public protocol RESPArgumentConvertible: Sendable {
    var respArgument: [UInt8] { get }
}

extension String: RESPArgumentConvertible {
    public var respArgument: [UInt8] { Array(utf8) }
}

extension Substring: RESPArgumentConvertible {
    public var respArgument: [UInt8] { Array(utf8) }
}

extension Array: RESPArgumentConvertible where Element == UInt8 {
    public var respArgument: [UInt8] { self }
}

extension Data: RESPArgumentConvertible {
    public var respArgument: [UInt8] { Array(self) }
}

extension Int: RESPArgumentConvertible {
    public var respArgument: [UInt8] { Array(String(self).utf8) }
}

extension Int64: RESPArgumentConvertible {
    public var respArgument: [UInt8] { Array(String(self).utf8) }
}

extension UInt64: RESPArgumentConvertible {
    public var respArgument: [UInt8] { Array(String(self).utf8) }
}

extension Double: RESPArgumentConvertible {
    public var respArgument: [UInt8] {
        if self == .infinity { return Array("+inf".utf8) }
        if self == -.infinity { return Array("-inf".utf8) }
        return Array(String(self).utf8)
    }
}
