// redi-tools: maintenance tasks for the Redi source tree.
//
//   swift run --package-path Packages/RediKit redi-tools dump-commands [--port 6379] \
//       > Packages/RediKit/Sources/RediCore/Resources/commands.json
//
// `dump-commands` regenerates the bundled command catalog from a running server's COMMAND DOCS
// (use the newest Redis available). It's the fallback for servers older than 7.0.
import Foundation
import RediCore
import RedisClient
import RedisWire

@main
struct RediTools {
    static func main() async throws {
        var arguments = CommandLine.arguments.dropFirst()
        guard let task = arguments.popFirst() else { usage() }
        var port = 6379
        var host = "127.0.0.1"
        while let flag = arguments.popFirst() {
            switch flag {
            case "--port": port = Int(arguments.popFirst() ?? "") ?? port
            case "--host": host = arguments.popFirst() ?? host
            default: usage()
            }
        }
        switch task {
        case "dump-commands":
            let connection = try await RedisConnection.connect(RedisConnectionConfiguration(endpoint: .tcp(host: host, port: port)))
            let reply = try await connection.execute(RedisWire.RedisCommand("COMMAND", "DOCS"))
            await connection.close()
            let catalog = CommandCatalog(commandDocsReply: reply)
            let docs = catalog.docs.values.sorted { $0.name < $1.name }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(docs))
            FileHandle.standardError.write(Data("Dumped \(docs.count) commands.\n".utf8))
        default:
            usage()
        }
    }

    static func usage() -> Never {
        FileHandle.standardError.write(Data("usage: redi-tools dump-commands [--host H] [--port P]\n".utf8))
        exit(2)
    }
}
