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
        // Under RESP3 even the unsubscribe confirmations arrive as pushes, never as a reply.
        case "subscribe", "psubscribe", "ssubscribe", "unsubscribe", "punsubscribe", "sunsubscribe": return .streaming(.pubSub)
        case "monitor": return .streaming(.monitor)
        default: break
        }
        if let reason = destructive[sub] ?? destructive[name] { return .destructive(reason) }
        if name == "keys" { return .expensive(expensive["keys"]!) }
        if let info = table.info(for: arguments), info.isBlocking { return .blocking }
        return .normal
    }

    /// The command's display name ("AUTH", "CLIENT REPLY") when it changes how a connection logs in,
    /// speaks or replies. Redi sets those up itself on every connection it opens, from the profile,
    /// and a typed one would only affect the one connection it reaches, or stop it pairing replies
    /// with commands (CLIENT REPLY OFF). The CLI and the Workbench refuse these.
    public static func connectionCommand(_ arguments: [[UInt8]]) -> String? {
        guard let first = arguments.first else { return nil }
        let name = String(decoding: first, as: UTF8.self).lowercased()
        if connectionCommands.contains(name) { return name.uppercased() }
        if name == "client", arguments.count > 1, String(decoding: arguments[1], as: UTF8.self).lowercased() == "reply" {
            return "CLIENT REPLY"
        }
        return nil
    }

    static let connectionCommands: Set<String> = ["auth", "hello", "reset", "quit"]

    public enum ReadOnlyCheck: Sendable, Hashable {
        case allowed
        /// Changes data or server state.
        case forbidden
        /// Not known to only read: the server reported no metadata for it, and it isn't on the list of
        /// known reads. Read-only mode refuses it rather than guess.
        case unverified
    }

    /// Whether read-only mode allows the command. Refused:
    /// - the destructive commands above and `readOnlyForbidden`, whatever the server's flags say;
    /// - anything the server flags `write`;
    /// - without server metadata for the command, anything not in `knownReads` (fail closed).
    public static func readOnlyCheck(_ arguments: [[UInt8]], table: CommandTable) -> ReadOnlyCheck {
        guard let first = arguments.first else { return .allowed }
        let name = String(decoding: first, as: UTF8.self).lowercased()
        let sub = arguments.count > 1 ? name + "|" + String(decoding: arguments[1], as: UTF8.self).lowercased() : name
        if destructive[sub] != nil || destructive[name] != nil || readOnlyForbidden.contains(sub) || readOnlyForbidden.contains(name) {
            return .forbidden
        }
        if let info = table.info(for: arguments) { return info.isWrite ? .forbidden : .allowed }
        if knownReads.contains(name) || knownReads.contains(sub) { return .allowed }
        return fallbackWrites.contains(name) ? .forbidden : .unverified
    }

    public static func isForbiddenInReadOnlyMode(_ arguments: [[UInt8]], table: CommandTable) -> Bool {
        readOnlyCheck(arguments, table: table) != .allowed
    }

    /// Commands the server doesn't flag `write` that can still change data, other clients or server
    /// state. Their read-only variants (`EVAL_RO`, `EVALSHA_RO`, `FCALL_RO`) stay allowed.
    static let readOnlyForbidden: Set<String> = [
        // A script's effects depend on the script, so Redis doesn't flag these `write`.
        "eval", "evalsha", "fcall",
        // Messages reach other clients; the Pub/Sub publish button is disabled in read-only mode too.
        "publish", "spublish",
        "slowlog|reset", "latency|reset", "client|pause", "acl|load", "acl|save",
        "cluster|meet", "cluster|addslots", "cluster|addslotsrange", "cluster|delslots", "cluster|delslotsrange",
        "cluster|setslot", "cluster|replicate", "cluster|saveconfig", "cluster|bumpepoch", "cluster|set-config-epoch",
    ]

    /// Commands that only read, allowed in read-only mode when the server reports no metadata (for
    /// example when `COMMAND` is denied by ACL). Container commands are listed per subcommand.
    static let knownReads: Set<String> = [
        // Connection, server and transactions (queued commands are each checked when sent).
        "ping", "echo", "time", "info", "dbsize", "lastsave", "role", "select", "command",
        "multi", "exec", "discard", "watch", "unwatch", "monitor",
        "config|get", "client|list", "client|info", "client|getname", "client|id",
        "slowlog|get", "slowlog|len", "latency|latest", "latency|history", "latency|doctor", "latency|histogram", "latency|graph",
        "acl|whoami", "acl|cat", "acl|list", "acl|users", "acl|getuser", "module|list",
        "memory|usage", "memory|stats", "memory|doctor", "memory|malloc-stats",
        "object|encoding", "object|freq", "object|idletime", "object|refcount",
        "cluster|info", "cluster|nodes", "cluster|slots", "cluster|shards", "cluster|myid", "cluster|myshardid",
        "cluster|keyslot", "cluster|countkeysinslot", "cluster|getkeysinslot", "cluster|links", "cluster|replicas", "cluster|slaves",
        // Keys
        "exists", "type", "ttl", "pttl", "expiretime", "pexpiretime", "dump", "keys", "scan", "randomkey", "touch", "sort_ro",
        // Strings and bitmaps
        "get", "mget", "strlen", "getrange", "substr", "lcs", "getbit", "bitcount", "bitpos", "bitfield_ro",
        // Hashes
        "hget", "hmget", "hgetall", "hkeys", "hvals", "hlen", "hexists", "hstrlen", "hscan", "hrandfield",
        "httl", "hpttl", "hexpiretime", "hpexpiretime",
        // Lists
        "lrange", "llen", "lindex", "lpos",
        // Sets
        "smembers", "sismember", "smismember", "scard", "srandmember", "sscan", "sinter", "sintercard", "sunion", "sdiff",
        // Sorted sets
        "zrange", "zrevrange", "zrangebyscore", "zrevrangebyscore", "zrangebylex", "zrevrangebylex", "zscore", "zmscore",
        "zrank", "zrevrank", "zcard", "zcount", "zlexcount", "zscan", "zrandmember", "zinter", "zunion", "zdiff", "zintercard",
        // Streams
        "xrange", "xrevrange", "xlen", "xread", "xpending", "xinfo|stream", "xinfo|groups", "xinfo|consumers",
        // HyperLogLog and geo
        "pfcount", "geopos", "geodist", "geohash", "georadius_ro", "georadiusbymember_ro", "geosearch",
        // Read-only scripting
        "eval_ro", "evalsha_ro", "fcall_ro", "script|exists", "function|list", "function|stats", "function|dump",
        // Pub/Sub
        "subscribe", "psubscribe", "ssubscribe", "unsubscribe", "punsubscribe", "sunsubscribe",
        "pubsub|channels", "pubsub|numsub", "pubsub|numpat", "pubsub|shardchannels", "pubsub|shardnumsub",
        // Modules: JSON, Search, TimeSeries, Bloom, vector sets
        "json.get", "json.mget", "json.type", "json.strlen", "json.arrlen", "json.objkeys", "json.objlen", "json.resp",
        "ft.search", "ft.aggregate", "ft.info", "ft._list", "ft.explain", "ft.profile", "ft.spellcheck", "ft.tagvals",
        "ts.get", "ts.mget", "ts.range", "ts.revrange", "ts.mrange", "ts.mrevrange", "ts.info", "ts.queryindex",
        "bf.exists", "bf.mexists", "bf.info", "bf.card", "cf.exists", "cf.mexists", "cf.count", "cf.info",
        "vcard", "vdim", "vemb", "vinfo", "vsim", "vrandmember", "vgetattr", "vlinks", "vismember",
    ]

    /// Common writes, so read-only mode without metadata can say "read-only" rather than "unverified".
    static let fallbackWrites: Set<String> = [
        "set", "setex", "psetex", "setnx", "mset", "msetnx", "append", "incr", "incrby", "incrbyfloat", "decr", "decrby",
        "getset", "getdel", "getex", "setrange", "del", "unlink", "expire", "pexpire", "expireat", "pexpireat", "persist",
        "rename", "renamenx", "move", "copy", "restore", "hset", "hsetnx", "hmset", "hdel", "hincrby", "hincrbyfloat",
        "lpush", "rpush", "lpushx", "rpushx", "lpop", "rpop", "lset", "lrem", "linsert", "ltrim", "lmove", "rpoplpush",
        "sadd", "srem", "spop", "smove", "sinterstore", "sunionstore", "sdiffstore", "zadd", "zrem", "zincrby",
        "zpopmin", "zpopmax", "zremrangebyrank", "zremrangebyscore", "zremrangebylex", "zunionstore", "zinterstore",
        "xadd", "xdel", "xtrim", "xgroup", "xack", "xclaim", "xautoclaim", "pfadd", "pfmerge", "geoadd",
        "json.set", "json.del", "json.arrappend", "ts.add", "ts.create",
    ]
}
