// redi-seed: writes a realistic, namespaced mixed-type dataset as RESP commands to stdout.
//
//   swift run -c release --package-path Packages/RediKit redi-seed --keys 1000000 | redis-cli -p 6379 --pipe
//
// Key shapes (by index modulo 10):
//   user:<id>                hash   (6 fields)
//   session:<id>             string with TTL
//   cart:<id>                list   (1–20 items)
//   tags:<id>                set    (1–15 members)
//   leaderboard:<region>:<n> zset   (50 members)
//   events:<n>               stream (10 entries)
//   cache:page:<n>           JSON string
//   bin:<n>                  binary string (non-UTF-8 bytes)
//   counter:<n>              integer string
//   deeply:nested:ns:<a>:<b>:<n> string (exercises the tree view)
import Foundation
import RedisWire

var keyCount = 100_000
var prefix = ""
var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    switch flag {
    case "--keys": keyCount = Int(arguments.popFirst() ?? "") ?? keyCount
    case "--prefix": prefix = arguments.popFirst() ?? ""
    case "-h", "--help":
        print("usage: redi-seed [--keys N] [--prefix P]  |  redis-cli --pipe")
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown flag \(flag)\n".utf8))
        exit(2)
    }
}

var generator = SplitMix64(seed: 0x5EED)
let regions = ["us", "eu", "apac", "latam"]
let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet"]
var buffer: [UInt8] = []
buffer.reserveCapacity(1 << 21)

@MainActor func emit(_ arguments: [any RESPArgumentConvertible]) {
    RESPEncoder.encode(arguments: arguments.map(\.respArgument), into: &buffer)
    if buffer.count >= 1 << 20 { flush() }
}

@MainActor func flush() {
    buffer.withUnsafeBytes { FileHandle.standardOutput.write(Data($0)) }
    buffer.removeAll(keepingCapacity: true)
}

for index in 0..<keyCount {
    let id = String(index)
    switch index % 10 {
    case 0:
        emit(["HSET", "\(prefix)user:\(id)", "name", "User \(id)", "email", "user\(id)@example.com",
              "plan", ["free", "pro", "team"][index % 3], "created", Int(1_700_000_000 + index),
              "visits", Int(generator.next() % 5000), "region", regions[index % regions.count]])
    case 1:
        emit(["SET", "\(prefix)session:\(id)", "token-\(generator.next())", "EX", Int(600 + generator.next() % 86_400)])
    case 2:
        var command: [any RESPArgumentConvertible] = ["RPUSH", "\(prefix)cart:\(id)"]
        for item in 0..<(1 + Int(generator.next() % 20)) { command.append("sku-\(item)-\(generator.next() % 999)") }
        emit(command)
    case 3:
        var command: [any RESPArgumentConvertible] = ["SADD", "\(prefix)tags:\(id)"]
        for _ in 0..<(1 + Int(generator.next() % 15)) { command.append(words[Int(generator.next() % 10)] + String(generator.next() % 100)) }
        emit(command)
    case 4:
        var command: [any RESPArgumentConvertible] = ["ZADD", "\(prefix)leaderboard:\(regions[index % 4]):\(id)"]
        for player in 0..<50 { command.append(Int(generator.next() % 100_000)); command.append("player:\(player)") }
        emit(command)
    case 5:
        for entry in 0..<10 {
            emit(["XADD", "\(prefix)events:\(id)", "*", "type", words[entry], "user", Int(generator.next() % 10_000), "amount", Double(generator.next() % 10_000) / 100])
        }
    case 6:
        let json = #"{"id":\#(index),"title":"Page \#(index)","tags":["\#(words[index % 10])","\#(words[(index + 3) % 10])"],"views":\#(generator.next() % 100_000),"published":true}"#
        emit(["SET", "\(prefix)cache:page:\(id)", json, "EX", 3600])
    case 7:
        var bytes: [UInt8] = []
        for _ in 0..<(16 + Int(generator.next() % 48)) { bytes.append(UInt8(truncatingIfNeeded: generator.next())) }
        emit(["SET", "\(prefix)bin:\(id)", bytes])
    case 8:
        emit(["SET", "\(prefix)counter:\(id)", Int(generator.next() % 1_000_000)])
    default:
        emit(["SET", "\(prefix)deeply:nested:ns:\(index % 7):\(index % 13):\(id)", words[index % 10]])
    }
}
flush()

/// Small deterministic PRNG so datasets are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
