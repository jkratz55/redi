import RedisWire

/// Per-command metadata reported by the server's `COMMAND` reply: arity, flags, ACL categories and
/// legacy key positions. Drives cluster routing, read-only enforcement and safety prompts.
public struct CommandInfo: Sendable, Hashable, Codable {
    /// Lower-case, with subcommands joined by `|` (e.g. `get`, `client|list`), as Redis reports it.
    public var name: String
    public var arity: Int
    public var flags: Set<String>
    public var firstKey: Int
    public var lastKey: Int
    public var keyStep: Int
    public var aclCategories: Set<String>
    public var tips: [String]
    public var subcommands: [String]

    public var isWrite: Bool { flags.contains("write") }
    public var isReadOnly: Bool { flags.contains("readonly") }
    public var hasMovableKeys: Bool { flags.contains("movablekeys") }
    public var isAdmin: Bool { flags.contains("admin") || aclCategories.contains("@admin") }
    public var isDangerous: Bool { aclCategories.contains("@dangerous") }
    public var isBlocking: Bool { aclCategories.contains("@blocking") }
    public var isPubSub: Bool { flags.contains("pubsub") || aclCategories.contains("@pubsub") }
    /// Display name, e.g. `CLIENT LIST`.
    public var displayName: String { name.replacingOccurrences(of: "|", with: " ").uppercased() }
}

public struct CommandTable: Sendable {
    public private(set) var commands: [String: CommandInfo]

    public static let empty = CommandTable(commands: [:])

    public init(commands: [String: CommandInfo]) {
        self.commands = commands
    }

    /// Parses the reply to `COMMAND` (or `COMMAND INFO ...`).
    public init(reply: RESPValue) {
        var commands: [String: CommandInfo] = [:]
        for entry in reply.array ?? [] {
            Self.collect(entry, into: &commands)
        }
        self.commands = commands
    }

    private static func collect(_ entry: RESPValue, into commands: inout [String: CommandInfo]) {
        guard let fields = entry.array, fields.count >= 6, let name = fields[0].string?.lowercased() else { return }
        let set = { (value: RESPValue?) -> Set<String> in
            Set((value?.array ?? []).compactMap { $0.string?.lowercased() })
        }
        let subcommandEntries = fields.count > 9 ? (fields[9].array ?? []) : []
        let info = CommandInfo(
            name: name,
            arity: Int(fields[1].int ?? 0),
            flags: set(fields[2]),
            firstKey: Int(fields[3].int ?? 0),
            lastKey: Int(fields[4].int ?? 0),
            keyStep: Int(fields[5].int ?? 0),
            aclCategories: set(fields.count > 6 ? fields[6] : nil),
            tips: fields.count > 7 ? (fields[7].array ?? []).compactMap(\.string) : [],
            subcommands: subcommandEntries.compactMap { $0.array?.first?.string?.lowercased() })
        commands[name] = info
        for subcommand in subcommandEntries { collect(subcommand, into: &commands) }
    }

    public var isEmpty: Bool { commands.isEmpty }

    /// Top-level command names, sorted (for completion).
    public var topLevelNames: [String] {
        commands.keys.filter { !$0.contains("|") }.sorted()
    }

    public func info(named name: String) -> CommandInfo? {
        commands[name.lowercased().replacingOccurrences(of: " ", with: "|")]
    }

    /// The most specific entry for a command line: `CLIENT LIST` resolves to `client|list` when the
    /// server reports subcommands, otherwise to `client`.
    public func info(for arguments: [[UInt8]]) -> CommandInfo? {
        guard let first = arguments.first else { return nil }
        let name = String(decoding: first, as: UTF8.self).lowercased()
        guard let info = commands[name] else { return nil }
        if !info.subcommands.isEmpty, arguments.count > 1 {
            let sub = name + "|" + String(decoding: arguments[1], as: UTF8.self).lowercased()
            if let subInfo = commands[sub] { return subInfo }
        }
        return info
    }

    /// Indices of key arguments from legacy key positions. `[]` for keyless commands; `nil` when
    /// the command is unknown or its keys are movable (ask the server with `COMMAND GETKEYS`).
    public func keyIndices(for arguments: [[UInt8]]) -> [Int]? {
        guard let info = info(for: arguments) else { return nil }
        if info.hasMovableKeys { return nil }
        guard info.firstKey > 0, info.keyStep > 0 else { return [] }
        let last = info.lastKey < 0 ? arguments.count + info.lastKey : info.lastKey
        guard info.firstKey < arguments.count else { return [] }
        return Array(stride(from: info.firstKey, through: min(last, arguments.count - 1), by: info.keyStep))
    }
}
