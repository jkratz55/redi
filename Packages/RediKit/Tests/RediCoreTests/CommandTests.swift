import Foundation
import RedisClient
import RedisWire
import Testing
@testable import RediCore
@testable import RedisTestSupport

@Suite("Command line parsing")
struct CommandLineTests {
    private func split(_ line: String) throws -> [String] {
        try CommandLineParser.split(line).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func basics() throws {
        #expect(try split("SET key value") == ["SET", "key", "value"])
        #expect(try split("   GET   k  ") == ["GET", "k"])
        #expect(try split("") == [])
        #expect(try split(#"SET k "hello world""#) == ["SET", "k", "hello world"])
        #expect(try split(#"SET k 'it\'s'"#) == ["SET", "k", "it's"])
        #expect(try split(#"SET k "a\nb\t\"c\"""#) == ["SET", "k", "a\nb\t\"c\""])
        #expect(try split(#"SET k """#) == ["SET", "k", ""])
        #expect(try CommandLineParser.split(#"SET k "\x00\xff""#)[2] == [0, 255])
    }

    @Test func errors() {
        #expect(throws: CommandLineParser.Error.unbalancedQuotes) { try split(#"SET k "open"#) }
        #expect(throws: CommandLineParser.Error.invalidQuoteTermination) { try split(#"SET k "a"b"#) }
    }

    @Test func quotingRoundTrips() throws {
        for argument: [UInt8] in [Array("plain".utf8), Array("with space".utf8), [], [0, 10, 34, 92, 200]] {
            #expect(try CommandLineParser.split(CommandLineParser.quote(argument)) == [argument])
        }
    }
}

@Suite("Reply formatting")
struct ReplyFormatterTests {
    @Test func matchesRedisCli() {
        #expect(ReplyFormatter.cliText(.simpleString("OK")) == "OK")
        #expect(ReplyFormatter.cliText(.integer(5)) == "(integer) 5")
        #expect(ReplyFormatter.cliText(.null) == "(nil)")
        #expect(ReplyFormatter.cliText(.error(RedisServerError("ERR nope"))) == "(error) ERR nope")
        #expect(ReplyFormatter.cliText(.bulkString(Array("a\"b\n".utf8))) == #""a\"b\n""#)
        #expect(ReplyFormatter.cliText(.array([])) == "(empty array)")
        #expect(ReplyFormatter.cliText(.double(3.5)) == "(double) 3.5")
        #expect(ReplyFormatter.cliText(.boolean(true)) == "(true)")
        let nested: RESPValue = ["a", ["b", "c"], 1]
        #expect(ReplyFormatter.cliText(nested) == """
        1) "a"
        2) 1) "b"
           2) "c"
        3) (integer) 1
        """)
        let wide = RESPValue.array((1...10).map { .integer($0) })
        #expect(ReplyFormatter.cliText(wide).hasPrefix(" 1) (integer) 1\n 2)"))
        #expect(ReplyFormatter.cliText(.map([RESPPair("k", "v")])) == #"1# "k" => "v""#)
    }
}

@Suite("Command catalog")
struct CommandCatalogTests {
    let catalog = CommandCatalog.bundled

    @Test("Bundled catalog loads")
    func bundled() {
        #expect(catalog.docs.count > 300)
        #expect(catalog.docs["GET"]?.group == "string")
        #expect(catalog.docs["CLIENT LIST"] != nil)
        #expect(catalog.docs["CLIENT"]?.isContainer == true)
    }

    @Test("Synopsis matches the reference style")
    func synopsis() throws {
        let get = try #require(catalog.docs["GET"])
        #expect(get.synopsis == "GET key")
        let set = try #require(catalog.docs["SET"])
        #expect(set.synopsis.hasPrefix("SET key value [NX | XX"))
        #expect(catalog.docs["DEL"]?.synopsis == "DEL key [key ...]")
    }

    @Test("Completion and hints")
    func completionAndHints() {
        #expect(catalog.completions(for: "HGETA") == ["HGETALL"])
        #expect(catalog.completions(for: "client li").contains("LIST"))
        #expect(catalog.completions(for: "GET k").isEmpty)
        #expect(catalog.hint(for: "GET") == " key")
        #expect(catalog.hint(for: "GET ") == "key")
        #expect(catalog.hint(for: "SET k ")?.hasPrefix("value") == true)
        #expect(catalog.hint(for: "NOTACOMMAND") == nil)
    }

    @Test("Live COMMAND DOCS and COMMAND tables", .enabled(if: RedisServerFixture.isAvailable))
    func live() async throws {
        let server = try await RedisServerFixture()
        let connection = try await RedisConnection.connect(server.configuration())
        let docs = CommandCatalog(commandDocsReply: try await connection.execute(RedisCommand("COMMAND", "DOCS")))
        #expect(docs.docs["HSET"]?.summary.isEmpty == false)

        let table = CommandTable(reply: try await connection.execute(RedisCommand("COMMAND")))
        #expect(table.info(named: "set")?.isWrite == true)
        #expect(table.info(named: "get")?.isReadOnly == true)
        #expect(table.keyIndices(for: [Array("MSET".utf8), Array("a".utf8), Array("1".utf8), Array("b".utf8), Array("2".utf8)]) == [1, 3])
        #expect(table.keyIndices(for: [Array("EVAL".utf8), Array("x".utf8)]) == nil)
        #expect(table.keyIndices(for: [Array("PING".utf8)]) == [])
        #expect(table.info(for: [Array("CLIENT".utf8), Array("LIST".utf8)])?.name == "client|list")
        #expect(table.info(for: [Array("OBJECT".utf8), Array("ENCODING".utf8), Array("k".utf8)])?.firstKey == 2)

        func classify(_ line: String) throws -> CommandSafety.Classification {
            CommandSafety.classify(try CommandLineParser.split(line), table: table)
        }
        #expect(try classify("FLUSHALL") == .destructive("Deletes every key in every database."))
        #expect(try classify("config set maxmemory 1") != .normal)
        #expect(try classify("KEYS *") == .expensive(CommandSafety.expensive["keys"]!))
        #expect(try classify("SUBSCRIBE ch") == .streaming(.pubSub))
        #expect(try classify("UNSUBSCRIBE") == .streaming(.pubSub))
        #expect(try classify("BLPOP q 0") == .blocking)
        #expect(try classify("GET k") == .normal)
        #expect(CommandSafety.isForbiddenInReadOnlyMode(try CommandLineParser.split("SET a b"), table: table))
        #expect(!CommandSafety.isForbiddenInReadOnlyMode(try CommandLineParser.split("CONFIG GET maxmemory"), table: table))
        await connection.close()
    }

    @Test("Read-only sessions refuse writes", .enabled(if: RedisServerFixture.isAvailable))
    func readOnlySession() async throws {
        let server = try await RedisServerFixture()
        let session = RedisSession(configuration: server.configuration(), options: RedisSession.Options(isReadOnly: true))
        #expect(try await session.send(RedisCommand("GET", "k")).isNull)
        await #expect(throws: RedisSession.SessionError.readOnly("SET")) { try await session.send(RedisCommand("SET", "k", "v")) }
        await #expect(throws: RedisSession.SessionError.self) { try await session.send(RedisCommand("FLUSHALL")) }
        await session.close()
    }

    private func check(_ line: String, table: CommandTable = .empty) throws -> CommandSafety.ReadOnlyCheck {
        CommandSafety.readOnlyCheck(try CommandLineParser.split(line), table: table)
    }

    @Test("Read-only mode without server metadata fails closed")
    func readOnlyWithoutMetadata() throws {
        // Everything the app itself sends through a session while browsing a read-only connection.
        for line in ["TYPE k", "PTTL k", "TTL k", "EXISTS k", "DUMP k", "SCAN 0 MATCH * COUNT 500", "DBSIZE", "INFO", "INFO server",
                     "CONFIG GET databases", "MEMORY USAGE k", "OBJECT ENCODING k", "GET k", "STRLEN k", "GETRANGE k 0 9",
                     "HSCAN k 0", "HLEN k", "HTTL k FIELDS 1 f", "LRANGE k 0 9", "LLEN k", "SSCAN k 0", "SCARD k",
                     "ZRANGE k 0 9 WITHSCORES", "ZREVRANGE k 0 9", "ZSCAN k 0", "ZCARD k", "XREVRANGE k + - COUNT 10", "XLEN k",
                     "XINFO GROUPS k", "XINFO CONSUMERS k g", "XPENDING k g - + 10", "JSON.GET k", "VCARD k", "SLOWLOG GET 128",
                     "PUBSUB CHANNELS", "PUBSUB NUMSUB ch", "COMMAND DOCS", "PING", "EVAL_RO \"return 1\" 0", "FCALL_RO f 0"] {
            #expect(try check(line) == .allowed, "\(line)")
        }
        for line in ["SET k v", "DEL k", "HSET k f v", "XGROUP CREATE k g $", "EVAL \"return 1\" 0", "EVALSHA abc 0", "FCALL f 0",
                     "PUBLISH ch m", "CONFIG SET maxmemory 1", "SLOWLOG RESET", "CLUSTER SETSLOT 1 NODE x", "FLUSHDB"] {
            #expect(try check(line) == .forbidden, "\(line)")
        }
        // Unknown to Redi and the server didn't say: refused rather than guessed.
        for line in ["BLMOVE a b LEFT RIGHT 0", "FT.CREATE idx SCHEMA f TEXT", "ACL LOG RESET", "MYMODULE.DO x", "CLIENT KILL ID 1"] {
            #expect(try check(line) != .allowed, "\(line)")
        }
        #expect(try check("MYMODULE.DO x") == .unverified)
    }

    /// Admin commands change server state without being flagged `write`, so with server metadata an
    /// admin command is only allowed when it's known to read.
    @Test("Read-only mode allows admin commands only when they're known reads", .enabled(if: RedisServerFixture.isAvailable))
    func readOnlyAdminCommands() async throws {
        let server = try await RedisServerFixture()
        let session = RedisSession(configuration: server.configuration(), options: RedisSession.Options(isReadOnly: true))
        let table = try await session.commandTable()
        #expect(table.info(named: "client|unpause")?.isAdmin == true)
        #expect(table.info(named: "client|unpause")?.isWrite == false, "the server doesn't flag it write; the admin rule must catch it")

        // Everything the app reads in read-only mode (browsing, Overview, Slow Log, Profiler, Pub/Sub,
        // command docs), plus admin commands that only read.
        for line in ["TYPE k", "PTTL k", "SCAN 0 MATCH * COUNT 500", "DBSIZE", "INFO", "INFO replication", "CONFIG GET slowlog-*",
                     "MEMORY USAGE k SAMPLES 0", "OBJECT ENCODING k", "SLOWLOG GET 128", "SLOWLOG LEN", "MONITOR", "PUBSUB CHANNELS",
                     "PUBSUB NUMSUB ch", "COMMAND", "COMMAND DOCS", "XINFO GROUPS k", "CLIENT LIST", "CLIENT INFO",
                     "LATENCY LATEST", "ACL WHOAMI", "ACL LIST", "ACL USERS", "ACL GETUSER default", "ACL LOG", "ACL LOG 10",
                     "MODULE LIST", "LASTSAVE", "ROLE"] {
            #expect(try check(line, table: table) == .allowed, "\(line)")
        }
        for line in ["SAVE", "BGSAVE", "BGREWRITEAOF", "CLIENT UNPAUSE", "CLIENT NO-EVICT on", "CLIENT UNBLOCK 1",
                     "MODULE LOADEX /tmp/x.so", "ACL LOG RESET", "SCRIPT KILL", "FUNCTION KILL", "SLOWLOG RESET", "LATENCY RESET"] {
            #expect(try check(line, table: table) == .forbidden, "\(line)")
        }
        await #expect(throws: RedisSession.SessionError.readOnly("CLIENT")) { try await session.send(RedisCommand("CLIENT", "UNPAUSE")) }
        await session.close()
    }

    @Test("Commands carrying a password are recognised, as redis-cli does for its history")
    func sensitiveCommands() {
        for line in ["AUTH secret", "auth user secret", "HELLO 3 AUTH user secret", "hello 3 setname me auth u p",
                     "MIGRATE h 6379 k 0 1000 AUTH pw", "MIGRATE h 6379 \"\" 0 1000 AUTH2 user pw KEYS a b",
                     "ACL SETUSER alice on >pw", "CONFIG SET requirepass pw", "config set maxmemory 1 masterauth pw",
                     "CONFIG SET masteruser u", "SENTINEL SET mymaster auth-pass pw", "SENTINEL CONFIG SET sentinel-pass pw",
                     "AUTH \"unclosed"] {
            #expect(CommandSafety.isSensitive(line: line), "\(line)")
        }
        for line in ["GET auth", "HELLO 3", "CONFIG SET maxmemory 1", "CONFIG GET requirepass", "ACL LIST", "MIGRATE h 6379 k 0 1000",
                     "SET k v", "SENTINEL MASTERS", ""] {
            #expect(!CommandSafety.isSensitive(line: line), "\(line)")
        }
        #expect(CommandSafety.redacted(line: "AUTH secret") == "AUTH ••••")
        #expect(CommandSafety.redacted(line: "acl setuser alice on >pw") == "ACL SETUSER ••••")
        #expect(CommandSafety.redacted(line: "CONFIG SET requirepass pw") == "CONFIG SET ••••")
        #expect(CommandSafety.redacted(line: "HELLO 3 AUTH u p") == "HELLO ••••")
        #expect(CommandSafety.redacted(line: "GET k") == nil)
    }

    @Test("SAVE asks first; MODULE LOADEX is destructive like MODULE LOAD")
    func saveAndModuleLoadex() throws {
        #expect(CommandSafety.classify(try CommandLineParser.split("SAVE"), table: .empty) == .expensive(CommandSafety.expensive["save"]!))
        #expect(CommandSafety.classify(try CommandLineParser.split("MODULE LOADEX /tmp/x.so"), table: .empty) == .destructive("Loads code into the server."))
        #expect(CommandSafety.classify(try CommandLineParser.split("BGSAVE"), table: .empty) == .normal)
    }

    @Test("Read-only mode refuses scripts and admin writes the server doesn't flag", .enabled(if: RedisServerFixture.isAvailable))
    func readOnlyScripts() async throws {
        let server = try await RedisServerFixture()
        let writer = try await RedisConnection.connect(server.configuration())
        try await writer.execute(RedisCommand("FUNCTION", "LOAD", """
            #!lua name=redi
            redis.register_function('touchkey', function(keys) return redis.call('SET', keys[1], 'changed') end)
            redis.register_function{function_name='readkey', callback=function(keys) return redis.call('GET', keys[1]) end, flags={'no-writes'}}
            """))
        try await writer.execute(RedisCommand("SET", "k", "original"))
        let sha = try #require(try await writer.execute(RedisCommand("SCRIPT", "LOAD", "return redis.call('SET', KEYS[1], 'changed')")).string)

        let session = RedisSession(configuration: server.configuration(), options: RedisSession.Options(isReadOnly: true))
        let table = try await session.commandTable()
        #expect(table.info(named: "eval")?.isWrite == false, "Redis doesn't flag EVAL as a write; the explicit list must catch it")
        for command in [RedisCommand("EVAL", "return redis.call('SET', KEYS[1], 'changed')", 1, "k"),
                        RedisCommand("EVALSHA", sha, 1, "k"), RedisCommand("FCALL", "touchkey", 1, "k"),
                        RedisCommand("PUBLISH", "ch", "m"), RedisCommand("SLOWLOG", "RESET")] {
            await #expect(throws: RedisSession.SessionError.readOnly(command.name)) { try await session.send(command) }
        }
        #expect(try await session.execute(RedisCommand("EVAL_RO", "return redis.call('GET', KEYS[1])", 1, "k")).string == "original")
        #expect(try await session.execute(RedisCommand("FCALL_RO", "readkey", 1, "k")).string == "original")

        // fanOut is a public dispatch path too.
        await #expect(throws: RedisSession.SessionError.readOnly("SET")) { try await session.fanOut(RedisCommand("SET", "k", "changed")) }
        await #expect(throws: RedisSession.SessionError.self) {
            try await session.fanOut(RedisCommand("CONFIG", "SET", "slowlog-log-slower-than", 1))
        }
        #expect(try await session.fanOut(RedisCommand("DBSIZE")).first?.reply.int == 1)
        await #expect(throws: RedisSession.SessionError.self) {
            try await session.pipeline([RedisCommand("GET", "k"), RedisCommand("EVAL", "return 1", 0)])
        }

        #expect(try await writer.execute(RedisCommand("GET", "k")).string == "original")
        await session.close()
        await writer.close()
    }

    @Test("Read-only mode fails closed when the server denies COMMAND", .enabled(if: RedisServerFixture.isAvailable))
    func readOnlyWithoutCommandAccess() async throws {
        let server = try await RedisServerFixture()
        let admin = try await RedisConnection.connect(server.configuration())
        try await admin.execute(RedisCommand("ACL", "SETUSER", "nocommand", "on", ">secret", "~*", "&*", "+@all", "-command"))
        try await admin.execute(RedisCommand("SET", "k", "v"))

        let session = RedisSession(configuration: server.configuration(username: "nocommand", password: "secret"),
                                   options: RedisSession.Options(isReadOnly: true))
        #expect(try await session.commandTable().isEmpty)
        #expect(try await session.execute(RedisCommand("GET", "k")).string == "v")
        #expect(try await session.execute(RedisCommand("TYPE", "k")).string == "string")
        await #expect(throws: RedisSession.SessionError.readOnly("SET")) { try await session.send(RedisCommand("SET", "k", "x")) }
        await #expect(throws: RedisSession.SessionError.readOnlyUnverified("BLMOVE")) {
            try await session.send(RedisCommand("BLMOVE", "k", "other", "LEFT", "RIGHT", 0))
        }
        #expect(try await admin.execute(RedisCommand("GET", "k")).string == "v")
        await session.close()
        await admin.close()
    }
}
