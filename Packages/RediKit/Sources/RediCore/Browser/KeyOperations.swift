import Foundation
import RedisClient
import RedisWire

/// Header information for a selected key.
public struct KeyDetails: Sendable, Hashable {
    public var key: [UInt8]
    public var type: RedisKeyType
    /// Milliseconds to expiry, or `nil` when the key doesn't expire.
    public var ttl: Int64?
    public var memory: Int64?
    public var encoding: String?
    /// Elements (or bytes for strings).
    public var length: Int64?
}

public struct HashEntry: Sendable, Hashable, Identifiable {
    public var field: [UInt8]
    public var value: [UInt8]
    /// Seconds to expiry for the field (Redis 7.4+ hash-field expiration), if set.
    public var ttl: Int64?
    public var id: [UInt8] { field }

    public init(field: [UInt8], value: [UInt8], ttl: Int64?) {
        self.field = field
        self.value = value
        self.ttl = ttl
    }
}

public struct ListEntry: Sendable, Hashable, Identifiable {
    public var index: Int
    public var value: [UInt8]
    public var id: Int { index }

    public init(index: Int, value: [UInt8]) {
        self.index = index
        self.value = value
    }
}

public struct SortedSetEntry: Sendable, Hashable, Identifiable {
    public var member: [UInt8]
    public var score: Double
    public var id: [UInt8] { member }

    public init(member: [UInt8], score: Double) {
        self.member = member
        self.score = score
    }
}

public struct StreamEntry: Sendable, Hashable, Identifiable {
    public var id: String
    public var fields: [(name: [UInt8], value: [UInt8])]

    public init(id: String, fields: [(name: [UInt8], value: [UInt8])]) {
        self.id = id
        self.fields = fields
    }

    public static func == (lhs: StreamEntry, rhs: StreamEntry) -> Bool {
        lhs.id == rhs.id && lhs.fields.map(\.name) == rhs.fields.map(\.name) && lhs.fields.map(\.value) == rhs.fields.map(\.value)
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Milliseconds part of the ID, as a date.
    public var date: Date? {
        guard let ms = id.split(separator: "-").first.flatMap({ Double($0) }) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

public struct StreamGroup: Sendable, Hashable, Identifiable {
    public var name: String
    public var consumers: Int
    public var pending: Int
    public var lastDeliveredID: String
    public var lag: Int?
    public var id: String { name }
}

public struct StreamConsumer: Sendable, Hashable, Identifiable {
    public var name: String
    public var pending: Int
    public var idleMilliseconds: Int64
    public var id: String { name }
}

public struct PendingMessage: Sendable, Hashable, Identifiable {
    public var id: String
    public var consumer: String
    public var idleMilliseconds: Int64
    public var deliveryCount: Int
}

/// A page of a collection value plus the cursor (or offset) for the next page.
public struct ValuePage<Element: Sendable>: Sendable {
    public var elements: [Element]
    /// SCAN cursor or next offset as text; `nil` when there's nothing more.
    public var next: String?

    public init(elements: [Element], next: String?) {
        self.elements = elements
        self.next = next
    }
}

/// Reads and writes key values. All calls go through the session's interactive connection.
public struct KeyOperations: Sendable {
    public let session: RedisSession

    public init(session: RedisSession) {
        self.session = session
    }

    // MARK: - Key-level

    public func details(_ key: [UInt8]) async throws -> KeyDetails {
        let header = try await session.pipeline([
            RedisCommand("TYPE", key), RedisCommand("PTTL", key),
            RedisCommand("MEMORY", "USAGE", key, "SAMPLES", 0), RedisCommand("OBJECT", "ENCODING", key),
        ])
        let type = RedisKeyType(typeReply: header[0].string ?? "other")
        let ttl = header[1].int ?? -1
        var length: Int64?
        if let command = Self.lengthCommand(for: type, key: key) {
            length = try await session.send(command).int
        }
        return KeyDetails(key: key, type: type, ttl: ttl >= 0 ? ttl : nil,
                          memory: header[2].int, encoding: header[3].serverError == nil ? header[3].string : nil,
                          length: length)
    }

    static func lengthCommand(for type: RedisKeyType, key: [UInt8]) -> RedisCommand? {
        switch type {
        case .string: RedisCommand("STRLEN", key)
        case .hash: RedisCommand("HLEN", key)
        case .list: RedisCommand("LLEN", key)
        case .set: RedisCommand("SCARD", key)
        case .zset: RedisCommand("ZCARD", key)
        case .stream: RedisCommand("XLEN", key)
        case .vectorSet: RedisCommand("VCARD", key)
        default: nil
        }
    }

    /// Renames without overwriting. Throws if `newName` already exists.
    public func rename(_ key: [UInt8], to newName: [UInt8]) async throws {
        let reply = try await session.execute(RedisCommand("RENAMENX", key, newName))
        if reply.int == 0 { throw RedisServerError("ERR A key named “\(String(decoding: newName, as: UTF8.self))” already exists.") }
    }

    /// Sets a TTL in seconds, or removes it when `seconds` is `nil`.
    public func setTTL(_ key: [UInt8], seconds: Int64?) async throws {
        if let seconds {
            try await session.execute(RedisCommand("EXPIRE", key, seconds))
        } else {
            try await session.execute(RedisCommand("PERSIST", key))
        }
    }

    /// Deletes keys with UNLINK (non-blocking), falling back to DEL on servers older than 4.0.
    @discardableResult
    public func delete(_ keys: [[UInt8]]) async throws -> Int {
        guard !keys.isEmpty else { return 0 }
        var total = 0
        for key in keys {
            let reply = try await session.send(RedisCommand("UNLINK", key))
            if reply.serverError != nil {
                total += Int(try await session.execute(RedisCommand("DEL", key)).int ?? 0)
            } else {
                total += Int(reply.int ?? 0)
            }
        }
        return total
    }

    /// A serialized copy of a key for undo: `DUMP` payload plus remaining TTL.
    public struct Snapshot: Sendable {
        public var key: [UInt8]
        public var payload: [UInt8]
        public var ttl: Int64
    }

    public func snapshot(_ key: [UInt8]) async throws -> Snapshot? {
        let replies = try await session.pipeline([RedisCommand("DUMP", key), RedisCommand("PTTL", key)])
        guard let payload = replies[0].bytes else { return nil }
        return Snapshot(key: key, payload: payload, ttl: max(0, replies[1].int ?? 0))
    }

    public func restore(_ snapshot: Snapshot) async throws {
        try await session.execute(RedisCommand("RESTORE", snapshot.key, snapshot.ttl, snapshot.payload, "REPLACE"))
    }

    // MARK: - Strings

    /// Loads at most `limit` bytes. Returns the value and whether it was truncated.
    public func string(_ key: [UInt8], limit: Int) async throws -> (value: [UInt8], isTruncated: Bool) {
        let length = try await session.execute(RedisCommand("STRLEN", key)).int ?? 0
        if length > limit {
            let prefix = try await session.execute(RedisCommand("GETRANGE", key, 0, limit - 1)).bytes ?? []
            return (prefix, true)
        }
        return (try await session.execute(RedisCommand("GET", key)).bytes ?? [], false)
    }

    public func setString(_ key: [UInt8], value: [UInt8]) async throws {
        // KEEPTTL (6.0+) preserves expiry; older servers fall back to plain SET.
        let reply = try await session.send(RedisCommand("SET", key, value, "KEEPTTL"))
        if reply.serverError != nil { try await session.execute(RedisCommand("SET", key, value)) }
    }

    // MARK: - Hashes

    public func hashPage(_ key: [UInt8], cursor: String, match: String?, count: Int, withFieldTTL: Bool) async throws -> ValuePage<HashEntry> {
        var command = RedisCommand("HSCAN", key, cursor)
        if let match { command.append("MATCH"); command.append(match) }
        command.append("COUNT"); command.append(count)
        let reply = try await session.execute(command)
        guard let parts = reply.array, parts.count == 2 else { return ValuePage(elements: [], next: nil) }
        let flat = parts[1].array ?? []
        var entries: [HashEntry] = []
        var i = 0
        while i + 1 < flat.count {
            entries.append(HashEntry(field: flat[i].bytes ?? [], value: flat[i + 1].bytes ?? [], ttl: nil))
            i += 2
        }
        if withFieldTTL, !entries.isEmpty {
            var ttl = RedisCommand("HTTL", key, "FIELDS", entries.count)
            for entry in entries { ttl.append(entry.field) }
            if let values = try? await session.execute(ttl).array {
                for (index, value) in values.enumerated() where index < entries.count {
                    if let seconds = value.int, seconds >= 0 { entries[index].ttl = seconds }
                }
            }
        }
        let next = parts[0].string ?? "0"
        return ValuePage(elements: entries, next: next == "0" ? nil : next)
    }

    public func setHashField(_ key: [UInt8], field: [UInt8], value: [UInt8]) async throws {
        try await session.execute(RedisCommand("HSET", key, field, value))
    }

    public func deleteHashFields(_ key: [UInt8], fields: [[UInt8]]) async throws {
        try await session.execute(RedisCommand(arguments: [Array("HDEL".utf8), key] + fields))
    }

    public func setHashFieldTTL(_ key: [UInt8], field: [UInt8], seconds: Int64?) async throws {
        if let seconds {
            try await session.execute(RedisCommand("HEXPIRE", key, seconds, "FIELDS", 1, field))
        } else {
            try await session.execute(RedisCommand("HPERSIST", key, "FIELDS", 1, field))
        }
    }

    // MARK: - Lists

    public func listRange(_ key: [UInt8], start: Int, count: Int) async throws -> [ListEntry] {
        let values = try await session.execute(RedisCommand("LRANGE", key, start, start + count - 1)).array ?? []
        return values.enumerated().map { ListEntry(index: start + $0.offset, value: $0.element.bytes ?? []) }
    }

    public func setListElement(_ key: [UInt8], index: Int, value: [UInt8]) async throws {
        try await session.execute(RedisCommand("LSET", key, index, value))
    }

    public func pushList(_ key: [UInt8], values: [[UInt8]], atHead: Bool) async throws {
        try await session.execute(RedisCommand(arguments: [Array((atHead ? "LPUSH" : "RPUSH").utf8), key] + values))
    }

    /// Removes the element at `index` with the standard placeholder trick (LSET to a unique
    /// sentinel, then LREM it), since Redis has no remove-by-index.
    public func removeListElement(_ key: [UInt8], index: Int) async throws {
        let placeholder = Array("__redi_deleted_\(UUID().uuidString)__".utf8)
        _ = try await session.pipeline([RedisCommand("LSET", key, index, placeholder), RedisCommand("LREM", key, 1, placeholder)])
            .map { try $0.throwIfError() }
    }

    // MARK: - Sets

    public func setPage(_ key: [UInt8], cursor: String, match: String?, count: Int) async throws -> ValuePage<[UInt8]> {
        var command = RedisCommand("SSCAN", key, cursor)
        if let match { command.append("MATCH"); command.append(match) }
        command.append("COUNT"); command.append(count)
        let reply = try await session.execute(command)
        guard let parts = reply.array, parts.count == 2 else { return ValuePage(elements: [], next: nil) }
        let next = parts[0].string ?? "0"
        return ValuePage(elements: (parts[1].array ?? []).compactMap(\.bytes), next: next == "0" ? nil : next)
    }

    public func addSetMembers(_ key: [UInt8], members: [[UInt8]]) async throws {
        try await session.execute(RedisCommand(arguments: [Array("SADD".utf8), key] + members))
    }

    public func removeSetMembers(_ key: [UInt8], members: [[UInt8]]) async throws {
        try await session.execute(RedisCommand(arguments: [Array("SREM".utf8), key] + members))
    }

    // MARK: - Sorted sets

    public func sortedSetRange(_ key: [UInt8], start: Int, count: Int, descending: Bool) async throws -> [SortedSetEntry] {
        let stop = start + count - 1
        var reply = try await session.send(descending
            ? RedisCommand("ZRANGE", key, start, stop, "REV", "WITHSCORES")
            : RedisCommand("ZRANGE", key, start, stop, "WITHSCORES"))
        if reply.serverError != nil, descending {
            reply = try await session.execute(RedisCommand("ZREVRANGE", key, start, stop, "WITHSCORES"))
        }
        return Self.scoredMembers(try reply.throwIfError())
    }

    public func sortedSetPage(_ key: [UInt8], cursor: String, match: String, count: Int) async throws -> ValuePage<SortedSetEntry> {
        let reply = try await session.execute(RedisCommand("ZSCAN", key, cursor, "MATCH", match, "COUNT", count))
        guard let parts = reply.array, parts.count == 2 else { return ValuePage(elements: [], next: nil) }
        let next = parts[0].string ?? "0"
        return ValuePage(elements: Self.scoredMembers(parts[1]), next: next == "0" ? nil : next)
    }

    /// Accepts RESP2 flat `[member, score, …]` and RESP3 `[[member, score], …]` shapes.
    static func scoredMembers(_ reply: RESPValue) -> [SortedSetEntry] {
        let values = reply.array ?? []
        if let first = values.first, first.array != nil {
            return values.compactMap { pair in
                guard let parts = pair.array, parts.count == 2 else { return nil }
                return SortedSetEntry(member: parts[0].bytes ?? [], score: parts[1].double ?? 0)
            }
        }
        var entries: [SortedSetEntry] = []
        var i = 0
        while i + 1 < values.count {
            entries.append(SortedSetEntry(member: values[i].bytes ?? [], score: values[i + 1].double ?? 0))
            i += 2
        }
        return entries
    }

    public func addSortedSetMember(_ key: [UInt8], member: [UInt8], score: Double) async throws {
        try await session.execute(RedisCommand("ZADD", key, score, member))
    }

    public func removeSortedSetMembers(_ key: [UInt8], members: [[UInt8]]) async throws {
        try await session.execute(RedisCommand(arguments: [Array("ZREM".utf8), key] + members))
    }

    // MARK: - Streams

    /// Newest-first page of entries ending at `end` (exclusive when continuing).
    public func streamPage(_ key: [UInt8], before end: String?, count: Int) async throws -> ValuePage<StreamEntry> {
        let upper = end.map { "(" + $0 } ?? "+"
        var reply = try await session.send(RedisCommand("XREVRANGE", key, upper, "-", "COUNT", count))
        if reply.serverError != nil, let end {
            // Exclusive ranges need Redis 6.2; emulate by over-fetching one.
            reply = try await session.execute(RedisCommand("XREVRANGE", key, end, "-", "COUNT", count + 1))
            var entries = Self.streamEntries(reply)
            if entries.first?.id == end { entries.removeFirst() }
            return ValuePage(elements: entries, next: entries.count >= count ? entries.last?.id : nil)
        }
        let entries = Self.streamEntries(try reply.throwIfError())
        return ValuePage(elements: entries, next: entries.count >= count ? entries.last?.id : nil)
    }

    static func streamEntries(_ reply: RESPValue) -> [StreamEntry] {
        (reply.array ?? []).compactMap { entry in
            guard let parts = entry.array, parts.count == 2, let id = parts[0].string else { return nil }
            let flat = parts[1].array ?? parts[1].pairs?.flatMap { [$0.key, $0.value] } ?? []
            var fields: [(name: [UInt8], value: [UInt8])] = []
            var i = 0
            while i + 1 < flat.count {
                fields.append((flat[i].bytes ?? [], flat[i + 1].bytes ?? []))
                i += 2
            }
            return StreamEntry(id: id, fields: fields)
        }
    }

    public func addStreamEntry(_ key: [UInt8], id: String, fields: [(name: [UInt8], value: [UInt8])]) async throws -> String {
        var command = RedisCommand("XADD", key, id.isEmpty ? "*" : id)
        for field in fields {
            command.append(field.name)
            command.append(field.value)
        }
        return try await session.execute(command).string ?? ""
    }

    public func deleteStreamEntries(_ key: [UInt8], ids: [String]) async throws {
        try await session.execute(RedisCommand("XDEL", [key] + ids.map { $0 as any RESPArgumentConvertible }))
    }

    public func streamGroups(_ key: [UInt8]) async throws -> [StreamGroup] {
        (try await session.execute(RedisCommand("XINFO", "GROUPS", key)).array ?? []).compactMap { group in
            guard let name = group["name"]?.string else { return nil }
            return StreamGroup(name: name, consumers: Int(group["consumers"]?.int ?? 0), pending: Int(group["pending"]?.int ?? 0),
                               lastDeliveredID: group["last-delivered-id"]?.string ?? "", lag: group["lag"]?.int.map(Int.init))
        }
    }

    public func streamConsumers(_ key: [UInt8], group: String) async throws -> [StreamConsumer] {
        (try await session.execute(RedisCommand("XINFO", "CONSUMERS", key, group)).array ?? []).compactMap { consumer in
            guard let name = consumer["name"]?.string else { return nil }
            return StreamConsumer(name: name, pending: Int(consumer["pending"]?.int ?? 0), idleMilliseconds: consumer["idle"]?.int ?? 0)
        }
    }

    public func pendingMessages(_ key: [UInt8], group: String, count: Int = 100) async throws -> [PendingMessage] {
        (try await session.execute(RedisCommand("XPENDING", key, group, "-", "+", count)).array ?? []).compactMap { entry in
            guard let parts = entry.array, parts.count == 4, let id = parts[0].string else { return nil }
            return PendingMessage(id: id, consumer: parts[1].string ?? "", idleMilliseconds: parts[2].int ?? 0,
                                  deliveryCount: Int(parts[3].int ?? 0))
        }
    }

    public func createStreamGroup(_ key: [UInt8], name: String, startID: String) async throws {
        try await session.execute(RedisCommand("XGROUP", "CREATE", key, name, startID.isEmpty ? "$" : startID, "MKSTREAM"))
    }

    public func deleteStreamGroup(_ key: [UInt8], name: String) async throws {
        try await session.execute(RedisCommand("XGROUP", "DESTROY", key, name))
    }

    public func acknowledge(_ key: [UInt8], group: String, ids: [String]) async throws {
        try await session.execute(RedisCommand("XACK", [key, group] + ids.map { $0 as any RESPArgumentConvertible }))
    }

    // MARK: - JSON (RedisJSON)

    public func json(_ key: [UInt8]) async throws -> String {
        try await session.execute(RedisCommand("JSON.GET", key)).string ?? "null"
    }

    public func setJSON(_ key: [UInt8], json: String) async throws {
        try await session.execute(RedisCommand("JSON.SET", key, "$", json))
    }

    // MARK: - Creating keys

    public enum NewValue: Sendable {
        case string([UInt8])
        case hash(field: [UInt8], value: [UInt8])
        case list([UInt8])
        case set([UInt8])
        case sortedSet(member: [UInt8], score: Double)
        case stream(id: String, fields: [(name: [UInt8], value: [UInt8])])
        case json(String)
    }

    /// Creates a key. Fails if it already exists, so nothing is overwritten by accident.
    public func create(_ key: [UInt8], value: NewValue, ttlSeconds: Int64?) async throws {
        if try await session.execute(RedisCommand("EXISTS", key)).int ?? 0 > 0 {
            throw RedisServerError("ERR A key named “\(String(decoding: key, as: UTF8.self))” already exists.")
        }
        switch value {
        case .string(let bytes): try await session.execute(RedisCommand("SET", key, bytes))
        case .hash(let field, let value): try await setHashField(key, field: field, value: value)
        case .list(let element): try await pushList(key, values: [element], atHead: false)
        case .set(let member): try await addSetMembers(key, members: [member])
        case .sortedSet(let member, let score): try await addSortedSetMember(key, member: member, score: score)
        case .stream(let id, let fields): _ = try await addStreamEntry(key, id: id, fields: fields)
        case .json(let text): try await setJSON(key, json: text)
        }
        if let ttlSeconds, ttlSeconds > 0 { try await setTTL(key, seconds: ttlSeconds) }
    }

    // MARK: - Bulk

    /// Deletes every key matching `filter`, yielding the running total. Uses the background
    /// connection and UNLINK in batches so the server stays responsive.
    public func bulkDelete(filter: ScanFilter, batchSize: Int = 500) -> AsyncThrowingStream<Int, any Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let scanner = await KeyScanner(session: session)
                    var cursor = ScanCursor()
                    var deleted = 0
                    while !cursor.isComplete {
                        try Task.checkCancellation()
                        let result = try await scanner.next(from: cursor, filter: filter, count: batchSize, target: batchSize)
                        cursor = result.cursor
                        if !result.keys.isEmpty {
                            let replies = try await session.pipeline(result.keys.map { RedisCommand("UNLINK", $0) }, role: .background)
                            deleted += replies.reduce(0) { $0 + Int($1.int ?? 0) }
                            continuation.yield(deleted)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
