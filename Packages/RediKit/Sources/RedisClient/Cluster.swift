import RedisWire

/// Redis Cluster key → slot mapping (CRC16/XMODEM of the key, or of its `{hashtag}`, mod 16384).
public enum HashSlot {
    public static let count = 16_384

    public static func slot(for key: some Collection<UInt8>) -> Int {
        let bytes = Array(key)
        var hashed = bytes[...]
        if let open = bytes.firstIndex(of: UInt8(ascii: "{")),
           let close = bytes[(open + 1)...].firstIndex(of: UInt8(ascii: "}")),
           close > open + 1 {
            hashed = bytes[(open + 1)..<close]
        }
        return Int(crc16(hashed) & 0x3FFF)
    }

    public static func slot(for key: String) -> Int { slot(for: Array(key.utf8)) }

    static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc = (crc << 8) ^ table[Int(((crc >> 8) ^ UInt16(byte)) & 0xFF)]
        }
        return crc
    }

    private static let table: [UInt16] = (0..<256).map { index -> UInt16 in
        var crc = UInt16(index) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
        return crc
    }
}

/// One node of a Redis Cluster.
public struct ClusterNode: Sendable, Hashable, Identifiable {
    public enum Role: String, Sendable, Hashable { case primary, replica }

    public var id: String
    public var endpoint: RedisEndpoint
    public var role: Role
    /// For replicas, the id of the primary they replicate.
    public var primaryID: String?
    /// Slot ranges served (primaries only).
    public var slots: [ClosedRange<Int>]
    public var health: String

    public var slotCount: Int { slots.reduce(0) { $0 + $1.count } }
}

/// Slot ownership for a cluster, built from `CLUSTER SHARDS` (Redis 7+) or `CLUSTER SLOTS`.
public struct ClusterTopology: Sendable, Hashable {
    public private(set) var nodes: [ClusterNode]
    /// Index into `nodes` of the primary owning each slot, or -1 when unassigned.
    private var owners: [Int16]

    public var primaries: [ClusterNode] { nodes.filter { $0.role == .primary && !$0.slots.isEmpty } }

    public func replicas(of primary: ClusterNode) -> [ClusterNode] {
        nodes.filter { $0.primaryID == primary.id }
    }

    public func primary(forSlot slot: Int) -> ClusterNode? {
        guard slot >= 0, slot < owners.count else { return nil }
        let index = Int(owners[slot])
        return index >= 0 ? nodes[index] : nil
    }

    public var coversAllSlots: Bool { !owners.contains(-1) }

    init(nodes: [ClusterNode]) {
        self.nodes = nodes
        owners = Array(repeating: -1, count: HashSlot.count)
        for (index, node) in nodes.enumerated() where node.role == .primary {
            for range in node.slots {
                for slot in range where slot < HashSlot.count { owners[slot] = Int16(index) }
            }
        }
    }

    /// Applies a `MOVED` redirection: `slot` is now served by `endpoint`.
    public mutating func assign(slot: Int, to endpoint: RedisEndpoint) {
        guard slot >= 0, slot < owners.count else { return }
        if let index = nodes.firstIndex(where: { $0.endpoint == endpoint && $0.role == .primary }) {
            owners[slot] = Int16(index)
        } else {
            nodes.append(ClusterNode(id: endpoint.description, endpoint: endpoint, role: .primary,
                                     primaryID: nil, slots: [slot...slot], health: "online"))
            owners[slot] = Int16(nodes.count - 1)
        }
    }

    /// Parses `CLUSTER SHARDS`. `seedHost` substitutes for nodes whose endpoint is unknown (`?`).
    public static func parse(shards reply: RESPValue, seedHost: String, preferTLSPort: Bool = false) -> ClusterTopology? {
        guard let shards = reply.array, !shards.isEmpty else { return nil }
        var nodes: [ClusterNode] = []
        for shard in shards {
            let slotValues = (shard["slots"]?.array ?? []).compactMap(\.int).map(Int.init)
            var ranges: [ClosedRange<Int>] = []
            var i = 0
            while i + 1 < slotValues.count {
                ranges.append(slotValues[i]...slotValues[i + 1])
                i += 2
            }
            let shardNodes = shard["nodes"]?.array ?? []
            let primaryID = shardNodes.first { $0["role"]?.string == "master" }?["id"]?.string
            for node in shardNodes {
                guard let id = node["id"]?.string else { continue }
                var host = node["endpoint"]?.string ?? node["ip"]?.string ?? seedHost
                if host.isEmpty || host == "?" { host = node["ip"]?.string ?? seedHost }
                let port = Int((preferTLSPort ? node["tls-port"]?.int : nil) ?? node["port"]?.int ?? node["tls-port"]?.int ?? 6379)
                let isPrimary = node["role"]?.string == "master"
                nodes.append(ClusterNode(id: id, endpoint: .tcp(host: host, port: port),
                                         role: isPrimary ? .primary : .replica,
                                         primaryID: isPrimary ? nil : primaryID,
                                         slots: isPrimary ? ranges : [],
                                         health: node["health"]?.string ?? "online"))
            }
        }
        return nodes.isEmpty ? nil : ClusterTopology(nodes: nodes)
    }

    /// Parses `CLUSTER SLOTS` (works on every cluster-capable version).
    public static func parse(slots reply: RESPValue, seedHost: String) -> ClusterTopology? {
        guard let entries = reply.array, !entries.isEmpty else { return nil }
        var byID: [String: ClusterNode] = [:]
        var order: [String] = []
        for entry in entries {
            guard let fields = entry.array, fields.count >= 3,
                  let start = fields[0].int, let end = fields[1].int else { continue }
            var primaryID: String?
            for (offset, nodeValue) in fields.dropFirst(2).enumerated() {
                guard let node = nodeValue.array, node.count >= 2, let port = node[1].int else { continue }
                var host = node[0].string ?? seedHost
                if host.isEmpty || host == "?" { host = seedHost }
                let endpoint = RedisEndpoint.tcp(host: host, port: Int(port))
                let id = node.count >= 3 ? (node[2].string ?? endpoint.description) : endpoint.description
                if offset == 0 {
                    primaryID = id
                    if byID[id] == nil {
                        byID[id] = ClusterNode(id: id, endpoint: endpoint, role: .primary, primaryID: nil, slots: [], health: "online")
                        order.append(id)
                    }
                    byID[id]?.slots.append(Int(start)...Int(end))
                } else if byID[id] == nil {
                    byID[id] = ClusterNode(id: id, endpoint: endpoint, role: .replica, primaryID: primaryID, slots: [], health: "online")
                    order.append(id)
                }
            }
        }
        let nodes = order.compactMap { byID[$0] }
        return nodes.isEmpty ? nil : ClusterTopology(nodes: nodes)
    }
}

/// A `MOVED` or `ASK` redirection parsed from an error reply.
public struct ClusterRedirect: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case moved, ask }
    public var kind: Kind
    public var slot: Int
    public var endpoint: RedisEndpoint

    /// `MOVED 3999 127.0.0.1:6381` / `ASK 3999 127.0.0.1:6381` (an empty host means "same host").
    public init?(_ error: RedisServerError, defaultHost: String) {
        let parts = error.message.split(separator: " ")
        guard parts.count == 3, let slot = Int(parts[1]) else { return nil }
        switch parts[0] {
        case "MOVED": kind = .moved
        case "ASK": kind = .ask
        default: return nil
        }
        let address = parts[2]
        guard let colon = address.lastIndex(of: ":"), let port = Int(address[address.index(after: colon)...]) else { return nil }
        var host = String(address[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.isEmpty { host = defaultHost }
        self.slot = slot
        endpoint = .tcp(host: host, port: port)
    }
}

/// A monitored primary as reported by `SENTINEL MASTERS`.
public struct SentinelMaster: Sendable, Hashable, Identifiable {
    public var name: String
    public var endpoint: RedisEndpoint
    public var flags: String
    public var replicaCount: Int
    public var sentinelCount: Int
    public var id: String { name }
}

/// Sentinel queries. Sentinels speak the normal protocol but only a small command set.
public enum Sentinel {
    /// Asks each sentinel in turn for the current address of `masterName`.
    public static func resolveMaster(
        named masterName: String,
        sentinels: [RedisConnectionConfiguration],
        transportFactory: RedisTransportFactory = RedisConnection.defaultTransportFactory
    ) async throws -> (master: RedisEndpoint, sentinel: RedisConnectionConfiguration) {
        var lastError: (any Error)?
        for configuration in sentinels {
            do {
                let connection = try await RedisConnection.connect(configuration, transportFactory: transportFactory)
                defer { Task { await connection.close() } }
                let reply = try await connection.execute(RedisCommand("SENTINEL", "GET-MASTER-ADDR-BY-NAME", masterName))
                guard let parts = reply.array, parts.count == 2, let host = parts[0].string, let port = parts[1].int else {
                    throw RedisClientError.handshakeFailed("Sentinel doesn't know a master named “\(masterName)”.")
                }
                return (.tcp(host: host, port: Int(port)), configuration)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? RedisClientError.connectionFailed("No sentinels configured.")
    }

    /// Lists the primaries a sentinel monitors, for the connection form's "Discover" button.
    public static func masters(
        sentinel configuration: RedisConnectionConfiguration,
        transportFactory: RedisTransportFactory = RedisConnection.defaultTransportFactory
    ) async throws -> [SentinelMaster] {
        let connection = try await RedisConnection.connect(configuration, transportFactory: transportFactory)
        defer { Task { await connection.close() } }
        let reply = try await connection.execute(RedisCommand("SENTINEL", "MASTERS"))
        return (reply.array ?? []).compactMap { entry in
            guard let fields = entry.pairs else { return nil }
            var values: [String: String] = [:]
            for pair in fields { if let key = pair.key.string { values[key] = pair.value.string } }
            guard let name = values["name"], let host = values["ip"], let port = values["port"].flatMap(Int.init) else { return nil }
            return SentinelMaster(name: name, endpoint: .tcp(host: host, port: port), flags: values["flags"] ?? "",
                                  replicaCount: Int(values["num-slaves"] ?? "") ?? 0,
                                  sentinelCount: Int(values["num-other-sentinels"] ?? "").map { $0 + 1 } ?? 1)
        }
    }
}
