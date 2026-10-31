import Foundation
import RedisClient
import RedisWire
import Synchronization

/// Collects items from a reader and hands them out in batches. A flusher drains it on a fixed
/// cadence, so bursts are delivered promptly without waking the consumer per item.
final class Batcher<Item: Sendable>: Sendable {
    private let buffer = Mutex<[Item]>([])

    func append(_ item: Item) { buffer.withLock { $0.append(item) } }

    func drain() -> [Item] {
        buffer.withLock { items in
            defer { items.removeAll(keepingCapacity: true) }
            return items
        }
    }

    /// Yields batches every `interval` until cancelled.
    static func flusher(_ batcher: Batcher<Item>, interval: Duration, yield: @escaping @Sendable ([Item]) -> Void) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                let items = batcher.drain()
                if !items.isEmpty { yield(items) }
            }
        }
    }
}

/// Fixed-capacity FIFO that overwrites the oldest element. Used for message and MONITOR logs so
/// memory stays bounded however fast data arrives.
public struct RingBuffer<Element> {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage.reserveCapacity(min(capacity, 4096))
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    /// Logical index 0 is the oldest element.
    public subscript(index: Int) -> Element {
        storage[(head + index) % storage.count]
    }

    /// Appends, returning true if an old element was evicted.
    @discardableResult
    public mutating func append(_ element: Element) -> Bool {
        if storage.count < capacity {
            storage.append(element)
            return false
        }
        storage[head] = element
        head = (head + 1) % capacity
        return true
    }

    public mutating func append(contentsOf elements: some Sequence<Element>) {
        for element in elements { append(element) }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    public var elements: [Element] { (0..<count).map { self[$0] } }
}

extension RingBuffer: Sendable where Element: Sendable {}

// MARK: - Pub/Sub

public struct PubSubMessage: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case message, pattern, sharded }
    public var kind: Kind
    public var pattern: [UInt8]?
    public var channel: [UInt8]
    public var payload: [UInt8]
    public var receivedAt: Date

    /// Parses a pub/sub data frame (RESP3 push or RESP2 array). Returns nil for confirmations.
    public static func parse(_ value: RESPValue, at date: Date = Date()) -> PubSubMessage? {
        guard let parts = value.array, let type = parts.first?.string else { return nil }
        switch type {
        case "message" where parts.count == 3:
            return PubSubMessage(kind: .message, pattern: nil, channel: parts[1].bytes ?? [], payload: parts[2].bytes ?? [], receivedAt: date)
        case "smessage" where parts.count == 3:
            return PubSubMessage(kind: .sharded, pattern: nil, channel: parts[1].bytes ?? [], payload: parts[2].bytes ?? [], receivedAt: date)
        case "pmessage" where parts.count == 4:
            return PubSubMessage(kind: .pattern, pattern: parts[1].bytes, channel: parts[2].bytes ?? [], payload: parts[3].bytes ?? [], receivedAt: date)
        default:
            return nil
        }
    }
}

public enum PubSubEvent: Sendable {
    case messages([PubSubMessage])
    /// Subscription confirmations: total subscriptions on the connection.
    case subscribed(count: Int)
    case connectionLost(String)
    case resubscribed
}

/// Owns the subscriber connection(s) of a session. Classic SUBSCRIBE/PSUBSCRIBE use one
/// connection (cluster pub/sub is broadcast). SSUBSCRIBE goes to the node owning each channel's
/// slot. Lost connections are re-established and resubscribed automatically.
public actor PubSubListener {
    public nonisolated let events: AsyncStream<PubSubEvent>
    private let continuation: AsyncStream<PubSubEvent>.Continuation
    private let session: RedisSession
    private var channels: [String] = []
    private var patterns: [String] = []
    private var shardChannels: [String] = []
    private var readers: [Task<Void, Never>] = []
    private var isStopped = false

    public init(session: RedisSession) {
        self.session = session
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1024))
    }

    public var subscriptions: (channels: [String], patterns: [String], sharded: [String]) { (channels, patterns, shardChannels) }

    /// Replaces the current subscriptions.
    public func subscribe(channels: [String], patterns: [String], sharded: [String] = []) async throws {
        await stopReaders()
        isStopped = false
        self.channels = channels
        self.patterns = patterns
        self.shardChannels = sharded
        try await start()
    }

    public func stop() async {
        isStopped = true
        await stopReaders()
        channels = []
        patterns = []
        shardChannels = []
    }

    private func stopReaders() async {
        for reader in readers { reader.cancel() }
        readers.removeAll()
        await session.release(.subscriber)
    }

    private func start() async throws {
        if !channels.isEmpty || !patterns.isEmpty {
            let connection = try await session.connection(for: .subscriber)
            try await subscribe(connection, commands: commandsForGlobal())
            readers.append(read(connection, node: nil))
        }
        if !shardChannels.isEmpty {
            var byNode: [RedisEndpoint: [String]] = [:]
            let topology = await session.topology
            let primary = await session.primaryEndpoint
            for channel in shardChannels {
                let node = topology?.primary(forSlot: HashSlot.slot(for: channel))?.endpoint ?? primary
                byNode[node, default: []].append(channel)
            }
            for (node, channels) in byNode {
                let connection = try await session.connection(for: .subscriber, node: node)
                try await subscribe(connection, commands: [RedisCommand("SSUBSCRIBE", channels)])
                readers.append(read(connection, node: node))
            }
        }
    }

    private func commandsForGlobal() -> [RedisCommand] {
        var commands: [RedisCommand] = []
        if !channels.isEmpty { commands.append(RedisCommand("SUBSCRIBE", channels)) }
        if !patterns.isEmpty { commands.append(RedisCommand("PSUBSCRIBE", patterns)) }
        return commands
    }

    private func subscribe(_ connection: RedisConnection, commands: [RedisCommand]) async throws {
        for command in commands { try await connection.sendWithoutReply(command) }
    }

    /// Reads one connection's pushes; messages are delivered in batches every 50 ms.
    private func read(_ connection: RedisConnection, node: RedisEndpoint?) -> Task<Void, Never> {
        let continuation = self.continuation
        return Task { [weak self] in
            let batcher = Batcher<PubSubMessage>()
            let flusher = Batcher.flusher(batcher, interval: .milliseconds(50)) { continuation.yield(.messages($0)) }
            for await value in connection.pushes {
                if let message = PubSubMessage.parse(value) {
                    batcher.append(message)
                } else if let parts = value.array, let kind = parts.first?.string, kind.hasSuffix("subscribe"), let count = parts.last?.int {
                    continuation.yield(.subscribed(count: Int(count)))
                }
            }
            flusher.cancel()
            let rest = batcher.drain()
            if !rest.isEmpty { continuation.yield(.messages(rest)) }
            guard !Task.isCancelled else { return }
            await self?.connectionDropped(node: node)
        }
    }

    private func connectionDropped(node: RedisEndpoint?) async {
        guard !isStopped else { return }
        continuation.yield(.connectionLost(node?.description ?? ""))
        var delay = Duration.milliseconds(500)
        while !isStopped, !Task.isCancelled {
            try? await Task.sleep(for: delay)
            do {
                await stopReaders()
                try await start()
                continuation.yield(.resubscribed)
                return
            } catch {
                delay = min(delay * 2, .seconds(15))
            }
        }
    }

    public func publish(channel: String, message: [UInt8], sharded: Bool = false) async throws -> Int {
        Int(try await session.execute(RedisCommand(sharded ? "SPUBLISH" : "PUBLISH", channel, message)).int ?? 0)
    }
}

// MARK: - MONITOR

/// One line of MONITOR output, e.g. `1698765432.123456 [0 127.0.0.1:52345] "SET" "k" "v"`.
public struct MonitorEntry: Sendable, Hashable {
    public var timestamp: Double
    public var database: Int
    public var client: String
    public var command: String
    public var arguments: String
    public var node: String?

    public var date: Date { Date(timeIntervalSince1970: timestamp) }

    public static func parse(_ line: String, node: String? = nil) -> MonitorEntry? {
        guard let space = line.firstIndex(of: " "), let timestamp = Double(line[..<space]),
              let open = line.firstIndex(of: "["), let close = line[open...].firstIndex(of: "]") else { return nil }
        let inside = line[line.index(after: open)..<close].split(separator: " ", maxSplits: 1)
        let database = Int(inside.first ?? "") ?? 0
        let client = inside.count > 1 ? String(inside[1]) : ""
        let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        var command = rest
        var arguments = ""
        if rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(of: "\"") {
            command = String(rest[rest.index(after: rest.startIndex)..<end]).uppercased()
            arguments = rest[rest.index(after: end)...].trimmingCharacters(in: .whitespaces)
        }
        return MonitorEntry(timestamp: timestamp, database: database, client: client, command: command, arguments: arguments, node: node)
    }
}

/// Runs MONITOR on dedicated connections (every primary in a cluster) and streams parsed entries
/// in batches.
public actor MonitorListener {
    public nonisolated let entries: AsyncStream<[MonitorEntry]>
    private let continuation: AsyncStream<[MonitorEntry]>.Continuation
    private let session: RedisSession
    private var readers: [Task<Void, Never>] = []

    public init(session: RedisSession) {
        self.session = session
        (entries, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    public func start() async throws {
        await stop()
        let nodes = await session.primaries()
        let isCluster = await session.isCluster
        for node in nodes {
            let connection = try await session.connection(for: .monitor, node: node)
            let reply = try await connection.send(RedisCommand("MONITOR"))
            try reply.throwIfError()
            let label = isCluster ? node.description : nil
            let continuation = self.continuation
            readers.append(Task {
                let batcher = Batcher<MonitorEntry>()
                let flusher = Batcher.flusher(batcher, interval: .milliseconds(50)) { continuation.yield($0) }
                for await value in connection.pushes {
                    if let line = value.string, let entry = MonitorEntry.parse(line, node: label) { batcher.append(entry) }
                }
                flusher.cancel()
                let rest = batcher.drain()
                if !rest.isEmpty { continuation.yield(rest) }
            })
        }
    }

    public func stop() async {
        for reader in readers { reader.cancel() }
        readers.removeAll()
        await session.release(.monitor)
    }
}
