import Foundation
import RedisClient
import RedisWire

// MARK: - INFO snapshots

/// One sample of server metrics for the Overview dashboard. Rates that Redis reports only as
/// cumulative counters (CPU, hit ratio) are computed from the previous sample.
public struct InfoSnapshot: Sendable, Hashable, Identifiable {
    public var id: Date { date }
    public var date: Date
    public var opsPerSecond: Double
    public var usedMemory: Int64
    public var peakMemory: Int64
    public var maxMemory: Int64
    public var fragmentation: Double?
    public var connectedClients: Int64
    public var blockedClients: Int64
    public var inputKbps: Double
    public var outputKbps: Double
    /// Percent of one core, since the previous sample.
    public var cpuPercent: Double?
    /// Hits / (hits + misses) since the previous sample.
    public var hitRatio: Double?
    public var totalKeys: Int64
    public var expiringKeys: Int64
    public var evictedKeys: Int64
    public var uptimeSeconds: Int64
    public var version: String
    public var role: String
    public var keyspace: [DatabaseKeyspace]
    // Cumulative counters, kept for delta computation.
    var cpuSeconds: Double
    var hits: Int64
    var misses: Int64

    public struct DatabaseKeyspace: Sendable, Hashable, Identifiable {
        public var database: Int
        public var keys: Int64
        public var expires: Int64
        public var id: Int { database }
    }

    public init(info: RedisInfo, previous: InfoSnapshot?, date: Date = Date()) {
        self.date = date
        opsPerSecond = info.double("instantaneous_ops_per_sec") ?? 0
        usedMemory = info.int("used_memory") ?? 0
        peakMemory = info.int("used_memory_peak") ?? 0
        maxMemory = info.int("maxmemory") ?? 0
        fragmentation = info.double("mem_fragmentation_ratio")
        connectedClients = info.int("connected_clients") ?? 0
        blockedClients = info.int("blocked_clients") ?? 0
        inputKbps = info.double("instantaneous_input_kbps") ?? 0
        outputKbps = info.double("instantaneous_output_kbps") ?? 0
        evictedKeys = info.int("evicted_keys") ?? 0
        uptimeSeconds = info.int("uptime_in_seconds") ?? 0
        version = info["redis_version"] ?? info["valkey_version"] ?? ""
        role = info["role"] ?? ""
        cpuSeconds = (info.double("used_cpu_sys") ?? 0) + (info.double("used_cpu_user") ?? 0)
        hits = info.int("keyspace_hits") ?? 0
        misses = info.int("keyspace_misses") ?? 0
        keyspace = info.sections.first { $0.name == "Keyspace" }?.fields.compactMap { field in
            guard field.key.hasPrefix("db"), let database = Int(field.key.dropFirst(2)) else { return nil }
            let values = RedisInfo.parseList(field.value)
            return DatabaseKeyspace(database: database, keys: Int64(values["keys"] ?? "") ?? 0, expires: Int64(values["expires"] ?? "") ?? 0)
        } ?? []
        totalKeys = keyspace.reduce(0) { $0 + $1.keys }
        expiringKeys = keyspace.reduce(0) { $0 + $1.expires }
        if let previous {
            let elapsed = date.timeIntervalSince(previous.date)
            if elapsed > 0 { cpuPercent = max(0, (cpuSeconds - previous.cpuSeconds) / elapsed * 100) }
            let deltaHits = hits - previous.hits
            let deltaMisses = misses - previous.misses
            if deltaHits + deltaMisses > 0 { hitRatio = Double(deltaHits) / Double(deltaHits + deltaMisses) }
        } else if hits + misses > 0 {
            hitRatio = Double(hits) / Double(hits + misses)
        }
    }

    /// Sums cluster primaries into one snapshot.
    public static func combine(_ snapshots: [InfoSnapshot]) -> InfoSnapshot? {
        guard var total = snapshots.first else { return nil }
        for other in snapshots.dropFirst() {
            total.opsPerSecond += other.opsPerSecond
            total.usedMemory += other.usedMemory
            total.peakMemory += other.peakMemory
            total.maxMemory += other.maxMemory
            total.connectedClients += other.connectedClients
            total.blockedClients += other.blockedClients
            total.inputKbps += other.inputKbps
            total.outputKbps += other.outputKbps
            total.cpuPercent = total.cpuPercent.map { $0 + (other.cpuPercent ?? 0) }
            total.totalKeys += other.totalKeys
            total.expiringKeys += other.expiringKeys
            total.evictedKeys += other.evictedKeys
            total.cpuSeconds += other.cpuSeconds
            total.hits += other.hits
            total.misses += other.misses
        }
        let lookups = total.hits + total.misses
        if snapshots.allSatisfy({ $0.hitRatio != nil }), lookups > 0 {
            total.hitRatio = snapshots.map { ($0.hitRatio ?? 0) }.reduce(0, +) / Double(snapshots.count)
        }
        total.fragmentation = nil
        return total
    }
}

// MARK: - Slow log

public struct SlowLogEntry: Sendable, Hashable, Identifiable {
    public var id: String { "\(node ?? "")#\(entryID)" }
    public var entryID: Int64
    public var date: Date
    public var durationMicroseconds: Int64
    public var arguments: [String]
    public var client: String
    public var clientName: String
    public var node: String?

    public var command: String { arguments.joined(separator: " ") }

    public static func parse(_ reply: RESPValue, node: String? = nil) -> [SlowLogEntry] {
        (reply.array ?? []).compactMap { item in
            guard let fields = item.array, fields.count >= 4, let id = fields[0].int, let timestamp = fields[1].int,
                  let duration = fields[2].int else { return nil }
            let arguments = (fields[3].array ?? []).map { ValueFormatter.preview($0.bytes ?? [], limit: 200) }
            return SlowLogEntry(entryID: id, date: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                                durationMicroseconds: duration, arguments: arguments,
                                client: fields.count > 4 ? fields[4].string ?? "" : "",
                                clientName: fields.count > 5 ? fields[5].string ?? "" : "", node: node)
        }
    }
}

// MARK: - Memory analysis

public struct AnalysisReport: Sendable, Codable, Hashable, Identifiable {
    public struct TypeSummary: Sendable, Codable, Hashable { public var type: String; public var keys: Int; public var memory: Int64 }
    public struct NamespaceSummary: Sendable, Codable, Hashable { public var prefix: String; public var keys: Int; public var memory: Int64 }
    public struct KeyFigure: Sendable, Codable, Hashable {
        public var key: String
        public var type: String
        public var memory: Int64
        public var length: Int64?
        public var ttl: Int64?
    }
    public struct TTLBucket: Sendable, Codable, Hashable { public var label: String; public var keys: Int; public var memory: Int64 }
    public struct Recommendation: Sendable, Codable, Hashable {
        public enum Severity: String, Sendable, Codable { case info, warning }
        public var title: String
        public var detail: String
        public var severity: Severity
    }

    public var id = UUID()
    public var date = Date()
    public var database: Int
    public var source: String
    public var isSample: Bool
    public var scannedKeys: Int
    public var totalKeys: Int
    public var totalMemory: Int64
    public var durationSeconds: Double
    public var byType: [TypeSummary]
    public var namespaces: [NamespaceSummary]
    public var topByMemory: [KeyFigure]
    public var topByLength: [KeyFigure]
    public var ttlBuckets: [TTLBucket]
    public var recommendations: [Recommendation]
}

/// Scans the keyspace (or a sample) and aggregates memory by type, namespace and TTL.
public struct MemoryAnalyzer: Sendable {
    public struct Progress: Sendable {
        public var scanned: Int
        public var total: Int
        public init(scanned: Int, total: Int) {
            self.scanned = scanned
            self.total = total
        }
    }

    public let session: RedisSession
    public let delimiter: String
    /// Stop after this many keys (`nil` analyses everything).
    public let sampleLimit: Int?
    /// Run against this node instead of the primaries (e.g. a replica).
    public let node: RedisEndpoint?

    public init(session: RedisSession, delimiter: String, sampleLimit: Int?, node: RedisEndpoint? = nil) {
        self.session = session
        self.delimiter = delimiter.isEmpty ? ":" : delimiter
        self.sampleLimit = sampleLimit
        self.node = node
    }

    /// The first replica of a standalone primary, from `INFO replication`.
    public static func replica(of session: RedisSession) async -> RedisEndpoint? {
        guard let reply = try? await session.send(RedisCommand("INFO", "replication")), let text = reply.string else { return nil }
        let info = RedisInfo(parsing: text)
        guard let replica = info["slave0"] else { return nil }
        let fields = RedisInfo.parseList(replica)
        guard let ip = fields["ip"], let port = fields["port"].flatMap(Int.init), fields["state"] == "online" else { return nil }
        return .tcp(host: ip, port: port)
    }

    private struct Accumulator {
        var scanned = 0
        var totalMemory: Int64 = 0
        var types: [String: (keys: Int, memory: Int64)] = [:]
        var namespaces: [String: (keys: Int, memory: Int64)] = [:]
        var byMemory: [AnalysisReport.KeyFigure] = []
        var byLength: [AnalysisReport.KeyFigure] = []
        var buckets = Array(repeating: (keys: 0, memory: Int64(0)), count: 6)
        var noTTLKeys = 0
        var hugeCollections = 0
        var bigKeys = 0
    }

    static let bucketLabels = ["No expiry", "< 1 hour", "1 hour – 1 day", "1 – 7 days", "7 – 30 days", "> 30 days"]

    public func run(progress: @Sendable (Progress) -> Void) async throws -> AnalysisReport {
        let started = Date()
        let primaries = await session.primaries()
        let nodes = node.map { [$0] } ?? primaries
        var total = 0
        for node in nodes {
            total += Int(try await session.send(RedisCommand("DBSIZE"), role: .background, target: .node(node)).int ?? 0)
        }
        let limit = sampleLimit.map { min($0, total) } ?? total
        var accumulator = Accumulator()
        progress(Progress(scanned: 0, total: limit))

        outer: for node in nodes {
            var cursor = "0"
            repeat {
                try Task.checkCancellation()
                let reply = try await session.execute(RedisCommand("SCAN", cursor, "COUNT", 1000), role: .background, target: .node(node))
                guard let parts = reply.array, parts.count == 2 else { break }
                cursor = parts[0].string ?? "0"
                var keys = (parts[1].array ?? []).compactMap(\.bytes)
                if let sampleLimit, accumulator.scanned + keys.count > sampleLimit {
                    keys = Array(keys.prefix(sampleLimit - accumulator.scanned))
                }
                if !keys.isEmpty { try await analyze(keys, node: node, into: &accumulator) }
                progress(Progress(scanned: accumulator.scanned, total: limit))
                if let sampleLimit, accumulator.scanned >= sampleLimit { break outer }
            } while cursor != "0"
        }

        return makeReport(accumulator, total: total, started: started, source: node?.description ?? (nodes.count > 1 ? "\(nodes.count) primaries" : nodes.first?.description ?? ""))
    }

    private func analyze(_ keys: [[UInt8]], node: RedisEndpoint, into accumulator: inout Accumulator) async throws {
        var commands: [RedisCommand] = []
        commands.reserveCapacity(keys.count * 3)
        for key in keys {
            commands.append(RedisCommand("TYPE", key))
            commands.append(RedisCommand("MEMORY", "USAGE", key, "SAMPLES", 0))
            commands.append(RedisCommand("PTTL", key))
        }
        let replies = try await session.pipeline(commands, role: .background, target: .node(node))
        var types: [RedisKeyType] = []
        var lengthCommands: [(Int, RedisCommand)] = []
        for (index, key) in keys.enumerated() {
            let type = RedisKeyType(typeReply: replies[index * 3].string ?? "other")
            types.append(type)
            if type != .string, let command = KeyOperations.lengthCommand(for: type, key: key) { lengthCommands.append((index, command)) }
        }
        var lengths = [Int64?](repeating: nil, count: keys.count)
        if !lengthCommands.isEmpty {
            let lengthReplies = try await session.pipeline(lengthCommands.map(\.1), role: .background, target: .node(node))
            for ((index, _), reply) in zip(lengthCommands, lengthReplies) { lengths[index] = reply.int }
        }

        for (index, key) in keys.enumerated() {
            let type = types[index]
            guard type != .none else { continue }
            let memory = replies[index * 3 + 1].int ?? 0
            let ttl = replies[index * 3 + 2].int ?? -1
            accumulator.scanned += 1
            accumulator.totalMemory += memory
            accumulator.types[type.displayName, default: (0, 0)].keys += 1
            accumulator.types[type.displayName, default: (0, 0)].memory += memory
            let name = String(decoding: key, as: UTF8.self)
            let prefix = name.range(of: delimiter).map { String(name[..<$0.upperBound]) + "*" } ?? "(no namespace)"
            accumulator.namespaces[prefix, default: (0, 0)].keys += 1
            accumulator.namespaces[prefix, default: (0, 0)].memory += memory
            let bucket: Int
            switch ttl {
            case ..<0: bucket = 0; accumulator.noTTLKeys += 1
            case ..<3_600_000: bucket = 1
            case ..<86_400_000: bucket = 2
            case ..<(7 * 86_400_000): bucket = 3
            case ..<(30 * 86_400_000): bucket = 4
            default: bucket = 5
            }
            accumulator.buckets[bucket].keys += 1
            accumulator.buckets[bucket].memory += memory
            if memory > 10 * 1_048_576 { accumulator.bigKeys += 1 }
            if let length = lengths[index], length > 5000 { accumulator.hugeCollections += 1 }
            let figure = AnalysisReport.KeyFigure(key: ValueFormatter.preview(key, limit: 300), type: type.displayName,
                                                  memory: memory, length: lengths[index], ttl: ttl >= 0 ? ttl : nil)
            accumulator.byMemory.append(figure)
            if lengths[index] != nil { accumulator.byLength.append(figure) }
        }
        if accumulator.byMemory.count > 500 {
            accumulator.byMemory = Array(accumulator.byMemory.sorted { $0.memory > $1.memory }.prefix(25))
        }
        if accumulator.byLength.count > 500 {
            accumulator.byLength = Array(accumulator.byLength.sorted { ($0.length ?? 0) > ($1.length ?? 0) }.prefix(25))
        }
    }

    private func makeReport(_ accumulator: Accumulator, total: Int, started: Date, source: String) -> AnalysisReport {
        let namespaces = accumulator.namespaces.map { AnalysisReport.NamespaceSummary(prefix: $0.key, keys: $0.value.keys, memory: $0.value.memory) }
            .sorted { $0.memory > $1.memory }
        var recommendations: [AnalysisReport.Recommendation] = []
        if accumulator.bigKeys > 0 {
            recommendations.append(.init(title: "Large keys",
                                         detail: "\(accumulator.bigKeys) keys use more than 10 MB. Big values make replication, eviction and deletion expensive. Consider splitting them.",
                                         severity: .warning))
        }
        if accumulator.hugeCollections > 0 {
            recommendations.append(.init(title: "Big collections",
                                         detail: "\(accumulator.hugeCollections) collections hold more than 5,000 elements. Commands such as HGETALL or SMEMBERS on them are O(N); prefer the SCAN family.",
                                         severity: .warning))
        }
        if accumulator.scanned > 100, Double(accumulator.noTTLKeys) / Double(accumulator.scanned) > 0.5 {
            recommendations.append(.init(title: "Keys without expiry",
                                         detail: "\(Int(Double(accumulator.noTTLKeys) / Double(accumulator.scanned) * 100))% of analyzed keys never expire. If they're cache data, set a TTL so memory is reclaimed automatically.",
                                         severity: .info))
        }
        for namespace in namespaces.prefix(10) where namespace.keys > 10_000 && namespace.memory / Int64(namespace.keys) < 100 {
            recommendations.append(.init(title: "Many small keys in \(namespace.prefix)",
                                         detail: "\(namespace.keys) keys average under 100 bytes. Grouping them into hashes can cut per-key overhead substantially.",
                                         severity: .info))
        }
        return AnalysisReport(
            database: 0, source: source, isSample: sampleLimit != nil && accumulator.scanned < total,
            scannedKeys: accumulator.scanned, totalKeys: total, totalMemory: accumulator.totalMemory,
            durationSeconds: Date().timeIntervalSince(started),
            byType: accumulator.types.map { .init(type: $0.key, keys: $0.value.keys, memory: $0.value.memory) }.sorted { $0.memory > $1.memory },
            namespaces: Array(namespaces.prefix(30)),
            topByMemory: Array(accumulator.byMemory.sorted { $0.memory > $1.memory }.prefix(20)),
            topByLength: Array(accumulator.byLength.sorted { ($0.length ?? 0) > ($1.length ?? 0) }.prefix(20)),
            ttlBuckets: Self.bucketLabels.enumerated().map { .init(label: $0.element, keys: accumulator.buckets[$0.offset].keys, memory: accumulator.buckets[$0.offset].memory) },
            recommendations: recommendations)
    }
}
