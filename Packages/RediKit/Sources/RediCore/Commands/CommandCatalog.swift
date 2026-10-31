import Foundation
import RedisWire

/// One argument in a command's documentation (`COMMAND DOCS`).
public struct CommandArgument: Codable, Sendable, Hashable {
    public var name: String
    /// `key`, `string`, `integer`, `double`, `pattern`, `unix-time`, `pure-token`, `oneof`, `block`.
    public var type: String
    public var token: String?
    public var displayText: String?
    public var isOptional: Bool
    public var isMultiple: Bool
    public var isMultipleToken: Bool
    public var arguments: [CommandArgument]

    public init(name: String, type: String, token: String? = nil, displayText: String? = nil, isOptional: Bool = false,
                isMultiple: Bool = false, isMultipleToken: Bool = false, arguments: [CommandArgument] = []) {
        self.name = name
        self.type = type
        self.token = token
        self.displayText = displayText
        self.isOptional = isOptional
        self.isMultiple = isMultiple
        self.isMultipleToken = isMultipleToken
        self.arguments = arguments
    }

    /// `redis-cli`/redis.io-style synopsis fragment, e.g. `[EX seconds | PX milliseconds]`.
    public var synopsis: String {
        var text: String
        switch type {
        case "pure-token": text = token ?? name.uppercased()
        case "oneof": text = arguments.map(\.synopsis).joined(separator: " | ")
        case "block": text = arguments.map(\.synopsis).joined(separator: " ")
        default:
            let value = displayText ?? name
            text = token.map { "\($0) \(value)" } ?? value
        }
        if isMultiple {
            text = isMultipleToken ? "\(text) [\(text) ...]" : (token.map { "\($0) \(displayText ?? name) [\(displayText ?? name) ...]" } ?? "\(text) [\(text) ...]")
        }
        if isOptional {
            return "[\(text)]"
        }
        return type == "oneof" && !isOptional ? "<\(text)>" : text
    }
}

/// Documentation for one command or subcommand.
public struct CommandDoc: Codable, Sendable, Hashable, Identifiable {
    /// Upper-case display name, e.g. `GET` or `CLIENT LIST`.
    public var name: String
    public var summary: String
    public var since: String?
    public var group: String?
    public var complexity: String?
    public var deprecatedSince: String?
    public var replacedBy: String?
    public var arguments: [CommandArgument]
    public var isContainer: Bool

    public var id: String { name }

    public init(name: String, summary: String, since: String? = nil, group: String? = nil, complexity: String? = nil,
                deprecatedSince: String? = nil, replacedBy: String? = nil, arguments: [CommandArgument] = [], isContainer: Bool = false) {
        self.name = name
        self.summary = summary
        self.since = since
        self.group = group
        self.complexity = complexity
        self.deprecatedSince = deprecatedSince
        self.replacedBy = replacedBy
        self.arguments = arguments
        self.isContainer = isContainer
    }

    /// Full synopsis, e.g. `SET key value [NX | XX] [GET] …`.
    public var synopsis: String {
        ([name] + arguments.map(\.synopsis)).joined(separator: " ")
    }

    /// Group name for display ("string" → "String", "sorted-set" → "Sorted Set").
    public var groupTitle: String {
        (group ?? "other").split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// Command documentation for completion, inline hints and the Command Helper.
///
/// Built from the server's `COMMAND DOCS` (Redis 7+, includes loaded modules) or, for older
/// servers, from the bundled catalog dumped from Redis 8 (`redi-tools dump-commands`).
public struct CommandCatalog: Sendable {
    public private(set) var docs: [String: CommandDoc]
    /// Top-level names sorted for completion.
    public let names: [String]

    public init(docs: [CommandDoc]) {
        var byName: [String: CommandDoc] = [:]
        for doc in docs { byName[doc.name] = doc }
        self.docs = byName
        names = byName.keys.filter { !$0.contains(" ") }.sorted()
    }

    public static let empty = CommandCatalog(docs: [])

    /// Parses the reply to `COMMAND DOCS` (RESP3 map or RESP2 flat array).
    public init(commandDocsReply reply: RESPValue) {
        var docs: [CommandDoc] = []
        for pair in reply.pairs ?? [] {
            guard let name = pair.key.string else { continue }
            Self.collect(name: name.uppercased(), fields: pair.value, into: &docs)
        }
        self.init(docs: docs)
    }

    private static func collect(name: String, fields: RESPValue, into docs: inout [CommandDoc]) {
        let subcommands = fields["subcommands"]?.pairs ?? []
        docs.append(CommandDoc(
            name: name.replacingOccurrences(of: "|", with: " "),
            summary: fields["summary"]?.string ?? "",
            since: fields["since"]?.string,
            group: fields["group"]?.string,
            complexity: fields["complexity"]?.string,
            deprecatedSince: fields["deprecated_since"]?.string,
            replacedBy: fields["replaced_by"]?.string,
            arguments: (fields["arguments"]?.array ?? []).compactMap(parseArgument),
            isContainer: !subcommands.isEmpty))
        for sub in subcommands {
            guard let subName = sub.key.string else { continue }
            collect(name: subName.uppercased(), fields: sub.value, into: &docs)
        }
    }

    private static func parseArgument(_ value: RESPValue) -> CommandArgument? {
        guard let name = value["name"]?.string else { return nil }
        let flags = Set((value["flags"]?.array ?? []).compactMap(\.string))
        return CommandArgument(
            name: name, type: value["type"]?.string ?? "string",
            token: value["token"]?.string, displayText: value["display_text"]?.string,
            isOptional: flags.contains("optional"), isMultiple: flags.contains("multiple"),
            isMultipleToken: flags.contains("multiple_token"),
            arguments: (value["arguments"]?.array ?? []).compactMap(parseArgument))
    }

    /// The catalog shipped with Redi (Redis 8 core commands), for servers without `COMMAND DOCS`.
    public static let bundled: CommandCatalog = {
        guard let url = Bundle.module.url(forResource: "commands", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let docs = try? JSONDecoder().decode([CommandDoc].self, from: data) else { return .empty }
        return CommandCatalog(docs: docs)
    }()

    public var isEmpty: Bool { docs.isEmpty }

    /// Docs for a command line: `["client", "list"]` → `CLIENT LIST` (falls back to `CLIENT`).
    public func doc(for arguments: [String]) -> CommandDoc? {
        guard let first = arguments.first?.uppercased() else { return nil }
        if arguments.count > 1, let sub = docs["\(first) \(arguments[1].uppercased())"] { return sub }
        return docs[first]
    }

    public func subcommands(of container: String) -> [CommandDoc] {
        let prefix = container.uppercased() + " "
        return docs.values.filter { $0.name.hasPrefix(prefix) }.sorted { $0.name < $1.name }
    }

    /// Completions for the word being typed. Command names first, then subcommands.
    public func completions(for line: String) -> [String] {
        let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let endsWithSpace = line.last == " "
        if words.isEmpty { return [] }
        if words.count == 1, !endsWithSpace {
            let prefix = words[0].uppercased()
            return names.filter { $0.hasPrefix(prefix) }
        }
        if words.count == 1 || (words.count == 2 && !endsWithSpace), docs[words[0].uppercased()]?.isContainer == true {
            let prefix = endsWithSpace ? "" : words[1].uppercased()
            return subcommands(of: words[0]).compactMap { $0.name.split(separator: " ").last.map(String.init) }
                .filter { $0.hasPrefix(prefix) }
        }
        return []
    }

    /// The `redis-cli`-style hint shown after what's been typed: the arguments not yet supplied.
    public func hint(for line: String) -> String? {
        guard let arguments = try? CommandLineParser.split(line).map({ String(decoding: $0, as: UTF8.self) }),
              let doc = doc(for: arguments) else { return nil }
        let consumedName = doc.name.split(separator: " ").count
        let typed = max(0, arguments.count - consumedName)
        let parts = doc.arguments.map(\.synopsis)
        // Required positional arguments are consumed one per typed word; optional ones stay visible.
        var remaining = parts
        var skip = typed
        while skip > 0, let first = remaining.first, !first.hasPrefix("[") {
            remaining.removeFirst()
            skip -= 1
        }
        if skip > 0 && remaining.allSatisfy({ $0.hasPrefix("[") }) == false { return nil }
        let text = remaining.joined(separator: " ")
        if text.isEmpty { return nil }
        return (line.last == " " || line.isEmpty) ? text : " " + text
    }
}
