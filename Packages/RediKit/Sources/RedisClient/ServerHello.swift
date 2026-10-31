import RedisWire

/// Server identity and capabilities learned during the handshake.
public struct ServerHello: Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        case standalone, cluster, sentinel
        case other(String)

        init(_ string: String) {
            switch string.lowercased() {
            case "standalone": self = .standalone
            case "cluster": self = .cluster
            case "sentinel": self = .sentinel
            default: self = .other(string)
            }
        }
    }

    public struct Module: Sendable, Hashable {
        public var name: String
        public var version: Int64?
    }

    /// `redis` or `valkey` (and other compatible servers that identify themselves).
    public var server: String
    public var version: ServerVersion
    public var protocolVersion: Int
    public var connectionID: Int64?
    public var mode: Mode
    /// `master` / `replica`, or `nil` when unknown.
    public var role: String?
    /// Loaded modules. Populated from `HELLO 3`. RESP2 servers report modules via `MODULE LIST`.
    public var modules: [Module]

    init(helloReply reply: RESPValue) {
        server = reply["server"]?.string ?? "redis"
        version = ServerVersion(reply["version"]?.string ?? "")
        protocolVersion = Int(reply["proto"]?.int ?? 3)
        connectionID = reply["id"]?.int
        mode = Mode(reply["mode"]?.string ?? "standalone")
        role = reply["role"]?.string
        modules = (reply["modules"]?.array ?? []).map { module in
            Module(name: module["name"]?.string ?? "?", version: module["ver"]?.int)
        }
    }

    init(info: RedisInfo, protocolVersion: Int) {
        server = info["server_name"] ?? "redis"
        version = ServerVersion(info["valkey_version"] ?? info["redis_version"] ?? "")
        self.protocolVersion = protocolVersion
        connectionID = nil
        mode = Mode(info["redis_mode"] ?? info["server_mode"] ?? "standalone")
        role = info["role"]
        modules = []
    }
}

/// A dotted server version that compares numerically (so 7.10 > 7.4).
public struct ServerVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let components: [Int]
    public let description: String

    public init(_ string: String) {
        description = string
        components = string.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        components = [major, minor, patch]
        description = "\(major).\(minor).\(patch)"
    }

    public var major: Int { components.first ?? 0 }

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}
