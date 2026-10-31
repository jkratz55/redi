import RedisWire

/// Classifies commands for confirmation prompts, read-only mode and special handling.
public enum CommandSafety {
    public enum Classification: Sendable, Hashable {
        /// Runs without ceremony.
        case normal
        /// Destroys data or disrupts the server; ask first. The string explains why.
        case destructive(String)
        /// Potentially very slow on large datasets (e.g. `KEYS`); warn first.
        case expensive(String)
        /// Needs a dedicated connection and streaming UI (SUBSCRIBE, MONITOR).
        case streaming(StreamingKind)
        /// Blocks the connection (BLPOP, XREAD BLOCK, WAIT).
        case blocking
    }

    public enum StreamingKind: Sendable, Hashable { case pubSub, monitor }

    /// Commands that change data or server state, even if the server's flags don't mark them `write`.
    static let destructive: [String: String] = [
        "flushall": "Deletes every key in every database.",
        "flushdb": "Deletes every key in the current database.",
        "shutdown": "Stops the Redis server.",
        "debug": "Can crash or stall the server.",
        "swapdb": "Swaps two databases for every client.",
        "config|set": "Changes server configuration.",
        "config|rewrite": "Rewrites the server's configuration file.",
        "config|resetstat": "Resets server statistics.",
        "client|kill": "Disconnects other clients.",
        "script|flush": "Removes every cached Lua script.",
        "function|flush": "Removes every function library.",
        "function|delete": "Removes a function library.",
        "acl|setuser": "Changes access control for a user.",
        "acl|deluser": "Deletes users.",
        "cluster|reset": "Resets this cluster node.",
        "cluster|failover": "Triggers a manual failover.",
        "cluster|forget": "Removes a node from the cluster.",
        "cluster|flushslots": "Removes this node's slot assignments.",
        "replicaof": "Changes replication for this server.",
        "slaveof": "Changes replication for this server.",
        "failover": "Starts a coordinated failover.",
        "module|load": "Loads code into the server.",
        "module|unload": "Unloads a server module.",
        "migrate": "Moves keys to another server.",
    ]

    static let expensive: [String: String] = [
        "keys": "KEYS blocks the server while it scans every key. Use the Key Browser (SCAN) on large databases.",
        "smembers": "Returns every member at once; large sets can be slow.",
        "hgetall": "Returns every field at once; large hashes can be slow.",
    ]

    public static func classify(_ arguments: [[UInt8]], table: CommandTable) -> Classification {
        guard let first = arguments.first else { return .normal }
        let name = String(decoding: first, as: UTF8.self).lowercased()
        let sub = arguments.count > 1 ? name + "|" + String(decoding: arguments[1], as: UTF8.self).lowercased() : name

        switch name {
        case "subscribe", "psubscribe", "ssubscribe": return .streaming(.pubSub)
        case "monitor": return .streaming(.monitor)
        default: break
        }
        if let reason = destructive[sub] ?? destructive[name] { return .destructive(reason) }
        if name == "keys" { return .expensive(expensive["keys"]!) }
        if let info = table.info(for: arguments), info.isBlocking { return .blocking }
        return .normal
    }

    /// Whether read-only mode must refuse the command: anything flagged `write` by the server, plus
    /// the destructive administrative commands above.
    public static func isForbiddenInReadOnlyMode(_ arguments: [[UInt8]], table: CommandTable) -> Bool {
        guard let first = arguments.first else { return false }
        let name = String(decoding: first, as: UTF8.self).lowercased()
        let sub = arguments.count > 1 ? name + "|" + String(decoding: arguments[1], as: UTF8.self).lowercased() : name
        if destructive[sub] != nil || destructive[name] != nil { return true }
        if let info = table.info(for: arguments) { return info.isWrite }
        // Without server metadata, fall back to a conservative list of common writes.
        return fallbackWrites.contains(name)
    }

    static let fallbackWrites: Set<String> = [
        "set", "setex", "psetex", "setnx", "mset", "msetnx", "append", "incr", "incrby", "incrbyfloat", "decr", "decrby",
        "getset", "getdel", "getex", "setrange", "del", "unlink", "expire", "pexpire", "expireat", "pexpireat", "persist",
        "rename", "renamenx", "move", "copy", "restore", "hset", "hsetnx", "hmset", "hdel", "hincrby", "hincrbyfloat",
        "lpush", "rpush", "lpushx", "rpushx", "lpop", "rpop", "lset", "lrem", "linsert", "ltrim", "lmove", "rpoplpush",
        "sadd", "srem", "spop", "smove", "sinterstore", "sunionstore", "sdiffstore", "zadd", "zrem", "zincrby",
        "zpopmin", "zpopmax", "zremrangebyrank", "zremrangebyscore", "zremrangebylex", "zunionstore", "zinterstore",
        "xadd", "xdel", "xtrim", "xgroup", "xack", "xclaim", "xautoclaim", "pfadd", "pfmerge", "geoadd",
        "eval", "evalsha", "fcall", "json.set", "json.del", "json.arrappend", "ts.add", "ts.create",
    ]
}
