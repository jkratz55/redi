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
}
