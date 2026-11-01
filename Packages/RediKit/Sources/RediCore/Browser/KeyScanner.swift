import RedisClient
import RedisWire

/// Position of an incremental scan across one or more nodes (cluster scans visit primaries in turn).
public struct ScanCursor: Sendable, Hashable {
    public var nodeIndex = 0
    public var cursor = "0"
    public var isComplete = false

    public init() {}
}

/// What to scan for.
public struct ScanFilter: Sendable, Hashable {
    /// A `SCAN MATCH` glob; empty means everything.
    public var pattern: String
    public var type: RedisKeyType?

    public init(pattern: String = "", type: RedisKeyType? = nil) {
        self.pattern = pattern
        self.type = type
    }

    /// The filter as a MATCH pattern. Text without glob characters is treated as a prefix search,
    /// the way users expect a search field to work.
    public var matchPattern: String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        return Self.hasGlob(trimmed) ? trimmed : Self.escapeGlob(trimmed) + "*"
    }

    /// For text without glob characters, the exact key to look up before scanning.
    public var exactKey: String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || Self.hasGlob(trimmed) ? nil : trimmed
    }

    static func hasGlob(_ text: String) -> Bool {
        text.contains { "*?[".contains($0) }
    }

    static func escapeGlob(_ text: String) -> String {
        var result = ""
        for character in text {
            if "*?[]\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}

/// One step of a scan.
public struct ScanResult: Sendable {
    public var cursor: ScanCursor
    public var keys: [[UInt8]]
    /// Server-side type of each key, when the server filtered by type.
    public var type: RedisKeyType?
    /// SCAN calls made (for "scanned ≈ N" progress).
    public var iterations: Int
}

public enum ScanError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The session's primaries changed (a Sentinel failover, or cluster nodes added, removed or
    /// promoted) since the scanner was made. Its cursor belongs to nodes that are no longer the
    /// primaries, so the scan has to start over with a new scanner.
    case topologyChanged

    public var description: String {
        switch self {
        case .topologyChanged: "The server's primaries changed during the scan."
        }
    }
}

/// Incremental SCAN over a session, collecting at least `target` keys per call (or finishing).
/// A scanner is fixed to the primaries at the time it's made; once they change it throws
/// `ScanError.topologyChanged` rather than reading a demoted or departed node.
public struct KeyScanner: Sendable {
    public let session: RedisSession
    public let nodes: [RedisEndpoint]
    public let serverSupportsTypeFilter: Bool

    public init(session: RedisSession) async {
        self.session = session
        nodes = await session.primaries()
        let version = await session.hello?.version ?? ServerVersion(6)
        serverSupportsTypeFilter = version >= ServerVersion(6)
    }

    /// Sum of DBSIZE across primaries. Throws the server's error (an ACL denial, say) rather than
    /// counting a refused node as empty.
    public func databaseSize() async throws -> Int {
        try await requireCurrentTopology()
        var total = 0
        for node in nodes {
            total += Int(try await session.execute(RedisCommand("DBSIZE"), role: .scan, target: .node(node)).int ?? 0)
        }
        return total
    }

    /// Whether the session's primaries are still the ones this scanner walks. Order doesn't matter:
    /// the cursor indexes the scanner's own `nodes`.
    public func isCurrent() async -> Bool {
        Set(await session.primaries()) == Set(nodes)
    }

    private func requireCurrentTopology() async throws {
        guard await isCurrent() else { throw ScanError.topologyChanged }
    }

    /// Looks up a single key directly, so searching for an exact name is instant on any database size.
    public func lookup(exactKey key: String, type: RedisKeyType?) async throws -> RedisKeyType? {
        let found = RedisKeyType(typeReply: try await session.send(RedisCommand("TYPE", key), role: .scan).string ?? "none")
        guard found != .none else { return nil }
        if let type, type != found { return nil }
        return found
    }

    /// Collects at least `target` keys, stopping early after `maxIterations` SCAN calls so callers
    /// can report progress (and be cancelled) while a sparse filter walks a huge keyspace.
    public func next(from cursor: ScanCursor, filter: ScanFilter, count: Int, target: Int,
                     maxIterations: Int = .max) async throws -> ScanResult {
        var cursor = cursor
        var keys: [[UInt8]] = []
        var iterations = 0
        let serverType = serverSupportsTypeFilter ? filter.type?.scanTypeName : nil
        while !cursor.isComplete, keys.count < target, iterations < maxIterations {
            iterations += 1
            try Task.checkCancellation()
            try await requireCurrentTopology()
            var command = RedisCommand("SCAN", cursor.cursor)
            if let match = filter.matchPattern {
                command.append("MATCH")
                command.append(match)
            }
            command.append("COUNT")
            command.append(count)
            if let serverType {
                command.append("TYPE")
                command.append(serverType)
            }
            let reply = try await session.execute(command, role: .scan, target: .node(nodes[cursor.nodeIndex]))
            guard let parts = reply.array, parts.count == 2, let next = parts[0].string else {
                throw RedisClientError.protocolViolation("Unexpected SCAN reply")
            }
            var page = (parts[1].array ?? []).compactMap(\.bytes)
            if let type = filter.type, serverType == nil, !page.isEmpty {
                // Old servers (or module types without SCAN TYPE support): filter client-side.
                let types = try await session.pipeline(page.map { RedisCommand("TYPE", $0) }, role: .scan)
                page = zip(page, types).filter { RedisKeyType(typeReply: $1.string ?? "") == type }.map(\.0)
            }
            keys.append(contentsOf: page)
            if next == "0" {
                cursor.nodeIndex += 1
                cursor.cursor = "0"
                cursor.isComplete = cursor.nodeIndex >= nodes.count
            } else {
                cursor.cursor = next
            }
        }
        return ScanResult(cursor: cursor, keys: keys, type: filter.type, iterations: iterations)
    }
}

/// Type, TTL and memory for a key row.
public struct KeyMetadata: Sendable, Hashable {
    public var type: RedisKeyType
    /// Milliseconds to expiry; `nil` for keys without TTL.
    public var ttl: Int64?
    /// Bytes reported by `MEMORY USAGE`, if available.
    public var memory: Int64?
    /// Whether the key was gone when the metadata was fetched.
    public var isMissing: Bool { type == .none }

    public init(type: RedisKeyType, ttl: Int64?, memory: Int64?) {
        self.type = type
        self.ttl = ttl
        self.memory = memory
    }

    /// Fetches metadata for many keys in one pipeline (3 commands per key), on the scan connection.
    public static func load(_ keys: [[UInt8]], session: RedisSession, includeMemory: Bool = true) async throws -> [KeyMetadata] {
        guard !keys.isEmpty else { return [] }
        var commands: [RedisCommand] = []
        commands.reserveCapacity(keys.count * 3)
        for key in keys {
            commands.append(RedisCommand("TYPE", key))
            commands.append(RedisCommand("PTTL", key))
            if includeMemory { commands.append(RedisCommand("MEMORY", "USAGE", key, "SAMPLES", 0)) }
        }
        let replies = try await session.pipeline(commands, role: .scan)
        let stride = includeMemory ? 3 : 2
        return keys.indices.map { index in
            let base = index * stride
            let ttl = replies[base + 1].int ?? -1
            return KeyMetadata(type: RedisKeyType(typeReply: replies[base].string ?? "other"),
                               ttl: ttl >= 0 ? ttl : nil,
                               memory: includeMemory ? replies[base + 2].int : nil)
        }
    }
}
