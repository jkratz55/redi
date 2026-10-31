import Foundation
import RedisClient
import RedisWire
import Synchronization

/// An in-memory `RedisTransport` that answers commands with a scripted handler.
///
/// Replies can be delivered in small chunks (`chunkSize`) to exercise incremental parsing, and
/// unsolicited data can be injected with `inject(_:)` to simulate push messages.
public final class ScriptedTransport: RedisTransport {
    /// Returns the reply for a command (arguments as strings), or `nil` to send nothing.
    public typealias Handler = @Sendable (_ arguments: [String]) -> RESPValue?

    public enum Encoding: Sendable { case resp3, resp2 }

    private struct State {
        var parser = RESPParser()
        var outbox: [Data] = []
        var waiter: CheckedContinuation<Data?, any Error>?
        var closed = false
        var received: [[String]] = []
        var encoding: Encoding
    }

    private let handler: Handler
    private let chunkSize: Int
    private let state: Mutex<State>

    public init(encoding: Encoding = .resp3, chunkSize: Int = .max, handler: @escaping Handler) {
        self.handler = handler
        self.chunkSize = max(1, chunkSize)
        state = Mutex(State(encoding: encoding))
    }

    /// Every command received so far, in order.
    public var receivedCommands: [[String]] { state.withLock { $0.received } }

    /// Switches reply encoding, e.g. after a scripted `HELLO 3` succeeds.
    public func setEncoding(_ encoding: Encoding) { state.withLock { $0.encoding = encoding } }

    public func start(timeout: Duration) async throws {}

    public func write(_ bytes: [UInt8]) {
        var replies: [UInt8] = []
        state.withLock { state in
            state.parser.append(bytes)
            while let value = try? state.parser.next() {
                let arguments = (value.array ?? []).map { $0.string ?? "" }
                state.received.append(arguments)
                guard let reply = handler(arguments) else { continue }
                switch state.encoding {
                case .resp3: RESPEncoder.encode(reply, into: &replies)
                case .resp2: RESPEncoder.encodeRESP2(reply, into: &replies)
                }
            }
        }
        deliver(replies)
    }

    /// Sends raw reply bytes as if they came from the server.
    public func inject(_ value: RESPValue) {
        var bytes: [UInt8] = []
        RESPEncoder.encode(value, into: &bytes)
        deliver(bytes)
    }

    public func injectRaw(_ bytes: [UInt8]) { deliver(bytes) }

    public func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                if !state.outbox.isEmpty {
                    continuation.resume(returning: state.outbox.removeFirst())
                } else if state.closed {
                    continuation.resume(returning: nil)
                } else {
                    state.waiter = continuation
                }
            }
        }
    }

    public func close() {
        state.withLock { state in
            state.closed = true
            state.waiter?.resume(returning: nil)
            state.waiter = nil
        }
    }

    private func deliver(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        var chunks: [Data] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + chunkSize)
            chunks.append(Data(bytes[offset..<end]))
            offset = end
        }
        state.withLock { state in
            guard !state.closed else { return }
            state.outbox.append(contentsOf: chunks)
            if let waiter = state.waiter {
                state.waiter = nil
                waiter.resume(returning: state.outbox.removeFirst())
            }
        }
    }
}

extension ScriptedTransport {
    /// A handler emulating a minimal Redis 7 server: `HELLO`, `PING`, `ECHO`, `SELECT`, `GET`/`SET`.
    public static func minimalServer(version: String = "7.2.4", supportsHello: Bool = true) -> Handler {
        let store = Mutex<[String: RESPValue]>([:])
        return { arguments in
            switch arguments.first?.uppercased() {
            case "HELLO":
                guard supportsHello else { return .error(RedisServerError("ERR unknown command 'HELLO'")) }
                return .map([
                    RESPPair("server", "redis"), RESPPair("version", .bulkString(Array(version.utf8))),
                    RESPPair("proto", 3), RESPPair("id", 7), RESPPair("mode", "standalone"),
                    RESPPair("role", "master"), RESPPair("modules", .array([])),
                ])
            case "INFO":
                return .bulkString(Array("# Server\r\nredis_version:\(version)\r\nredis_mode:standalone\r\n# Replication\r\nrole:master\r\n".utf8))
            case "PING": return .simpleString("PONG")
            case "ECHO": return .bulkString(Array((arguments.dropFirst().first ?? "").utf8))
            case "SELECT", "CLIENT", "AUTH": return .simpleString("OK")
            case "SET":
                store.withLock { $0[arguments[1]] = .bulkString(Array(arguments[2].utf8)) }
                return .simpleString("OK")
            case "GET":
                return store.withLock { $0[arguments[1]] } ?? .null
            default:
                return .error(RedisServerError("ERR unknown command '\(arguments.first ?? "")'"))
            }
        }
    }
}
