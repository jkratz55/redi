import Foundation
import RedisWire

/// One authenticated connection to a Redis server.
///
/// Commands may be issued concurrently. They're written in call order and replies are matched
/// FIFO, so pipelining falls out naturally: `pipeline(_:)` sends a batch in one write and resumes
/// a single continuation when every reply has arrived.
///
/// Out-of-band data (RESP3 push messages, and any reply that arrives with no command waiting, such
/// as MONITOR output or RESP2 pub/sub messages) is delivered on `pushes`.
///
/// A connection is single-use: once closed it stays closed. `RedisSession` handles reconnecting.
public actor RedisConnection {
    public nonisolated let id = UUID()
    public nonisolated let configuration: RedisConnectionConfiguration
    /// Out-of-band messages. Finishes when the connection closes.
    public nonisolated let pushes: AsyncStream<RESPValue>

    /// What the server reported during the handshake.
    public private(set) var hello: ServerHello?
    public private(set) var closeReason: RedisClientError?
    public var isClosed: Bool { closeReason != nil }

    private nonisolated let transport: any RedisTransport
    private let pushContinuation: AsyncStream<RESPValue>.Continuation
    private var parser = RESPParser()
    private var pending = PendingQueue()
    private var nextBatchID: UInt64 = 0
    private var readTask: Task<Void, Never>?

    public static let defaultTransportFactory: RedisTransportFactory = { NWTransport(configuration: $0) }

    init(configuration: RedisConnectionConfiguration, transport: any RedisTransport) {
        self.configuration = configuration
        self.transport = transport
        (pushes, pushContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(10_000))
    }

    deinit {
        transport.close()
        pushContinuation.finish()
    }

    /// Opens, authenticates and (if configured) selects a database.
    public static func connect(
        _ configuration: RedisConnectionConfiguration,
        transportFactory: RedisTransportFactory = RedisConnection.defaultTransportFactory
    ) async throws -> RedisConnection {
        let transport = transportFactory(configuration)
        let connection = RedisConnection(configuration: configuration, transport: transport)
        do {
            try await transport.start(timeout: configuration.connectTimeout)
            await connection.startReading()

            // A server or proxy that accepts the socket but never answers must not hang the UI.
            let watchdog = Task { [weak connection] in
                try? await Task.sleep(for: configuration.connectTimeout)
                guard !Task.isCancelled else { return }
                await connection?.close(reason: .connectTimeout(configuration.endpoint))
            }
            defer { watchdog.cancel() }
            try await connection.performHandshake()
        } catch {
            await connection.close()
            throw error
        }
        return connection
    }

    // MARK: - Commands

    /// Sends one command and returns its reply. Error replies are returned as `.error` values,
    /// not thrown. The CLI and Workbench render them; typed callers use `execute(_:)`.
    public func send(_ command: RedisCommand) async throws -> RESPValue {
        try await pipeline([command])[0]
    }

    /// Like `send(_:)` but throws `RedisServerError` for error replies.
    @discardableResult
    public func execute(_ command: RedisCommand) async throws -> RESPValue {
        try await send(command).throwIfError()
    }

    /// Sends all commands in one write and returns their replies in order.
    public func pipeline(_ commands: [RedisCommand]) async throws -> [RESPValue] {
        guard !commands.isEmpty else { return [] }
        if let closeReason { throw closeReason }
        try Task.checkCancellation()

        var bytes: [UInt8] = []
        for command in commands { RESPEncoder.encode(command, into: &bytes) }

        nextBatchID &+= 1
        let batchID = nextBatchID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Enqueue and write without suspending in between so reply order matches write order.
                pending.append(PendingBatch(id: batchID, expected: commands.count, continuation: continuation))
                transport.write(bytes)
            }
        } onCancel: {
            Task { await self.abandon(batchID: batchID) }
        }
    }

    /// Writes a command without registering for a reply. For pub/sub and MONITOR, where replies
    /// arrive on `pushes`.
    public func sendWithoutReply(_ command: RedisCommand) throws {
        if let closeReason { throw closeReason }
        var bytes: [UInt8] = []
        RESPEncoder.encode(command, into: &bytes)
        transport.write(bytes)
    }

    /// Closes the connection. Commands still waiting fail with `RedisClientError.connectionClosed`.
    public func close() {
        close(reason: .connectionClosed)
    }

    // MARK: - Reading

    private func startReading() {
        let transport = self.transport
        // Detached and weak: an idle read must not keep an abandoned connection alive. When the
        // connection deinitialises it closes the transport, which ends the pending read.
        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            while true {
                let result: Result<Data?, any Error>
                do { result = .success(try await transport.read()) } catch { result = .failure(error) }
                guard let self, await self.ingest(result) else { return }
            }
        }
    }

    /// Feeds one read result into the parser. Returns false when reading should stop.
    private func ingest(_ result: Result<Data?, any Error>) -> Bool {
        guard closeReason == nil else { return false }
        switch result {
        case .failure(let error as RedisClientError):
            close(reason: error)
            return false
        case .failure(let error):
            close(reason: .connectionFailed(String(describing: error)))
            return false
        case .success(nil):
            close(reason: .connectionClosed)
            return false
        case .success(let data?):
            data.withUnsafeBytes { parser.append($0) }
            do {
                while let value = try parser.next() { dispatch(value) }
            } catch {
                close(reason: .protocolViolation(error.description))
                return false
            }
            return true
        }
    }

    private func dispatch(_ value: RESPValue) {
        if case .push = value.unwrapped {
            pushContinuation.yield(value)
            return
        }
        guard let batch = pending.first else {
            // Unsolicited: MONITOR lines, RESP2 pub/sub messages.
            pushContinuation.yield(value)
            return
        }
        batch.results.append(value)
        if batch.results.count == batch.expected {
            pending.removeFirst()
            batch.continuation?.resume(returning: batch.results)
            batch.continuation = nil
        }
    }

    /// The caller was cancelled. Fail it now; its replies are still consumed (and discarded) when
    /// they arrive so later commands stay correctly matched.
    private func abandon(batchID: UInt64) {
        guard let batch = pending.first(where: { $0.id == batchID }), let continuation = batch.continuation else { return }
        batch.continuation = nil
        continuation.resume(throwing: CancellationError())
    }

    func close(reason: RedisClientError) {
        guard closeReason == nil else { return }
        closeReason = reason
        transport.close()
        readTask?.cancel()
        for batch in pending.drain() {
            batch.continuation?.resume(throwing: reason)
            batch.continuation = nil
        }
        pushContinuation.finish()
    }

    // MARK: - Handshake

    private func performHandshake() async throws {
        if configuration.protocolPreference == .resp3 {
            var hello = RedisCommand("HELLO", "3")
            if let password = configuration.password {
                hello.append("AUTH")
                hello.append(configuration.username ?? "default")
                hello.append(password)
            }
            if let name = configuration.clientName {
                hello.append("SETNAME")
                hello.append(name)
            }
            let reply = try await send(hello)
            if let error = reply.serverError {
                if Self.isAuthenticationError(error) {
                    throw RedisClientError.authenticationFailed(Self.authenticationMessage(error))
                }
                // Redis < 6 ("unknown command"), or a server/proxy without RESP3: use RESP2.
                guard error.code == "NOPROTO" || Self.isUnknownCommand(error) else {
                    throw RedisClientError.handshakeFailed(error.message)
                }
            } else {
                self.hello = ServerHello(helloReply: reply)
                try await selectConfiguredDatabase()
                return
            }
        }

        if let password = configuration.password {
            let auth: RedisCommand
            if let username = configuration.username, username != "default" {
                auth = RedisCommand("AUTH", username, password)
            } else {
                auth = RedisCommand("AUTH", password)
            }
            let reply = try await send(auth)
            if let error = reply.serverError {
                throw RedisClientError.authenticationFailed(Self.authenticationMessage(error))
            }
        }
        var setup: [RedisCommand] = [RedisCommand("INFO", "server"), RedisCommand("INFO", "replication")]
        if let name = configuration.clientName {
            setup.insert(RedisCommand("CLIENT", "SETNAME", name), at: 0)
        }
        let replies = try await pipeline(setup)
        let serverInfo = replies[replies.count - 2]
        if let error = serverInfo.serverError {
            if Self.isAuthenticationError(error) {
                throw RedisClientError.authenticationFailed(Self.authenticationMessage(error))
            }
            throw RedisClientError.handshakeFailed(error.message)
        }
        var info = RedisInfo(parsing: serverInfo.string ?? "")
        info.merge(RedisInfo(parsing: replies[replies.count - 1].string ?? ""))
        hello = ServerHello(info: info, protocolVersion: 2)
        try await selectConfiguredDatabase()
    }

    private func selectConfiguredDatabase() async throws {
        guard configuration.database != 0, hello?.mode != .cluster else { return }
        let reply = try await send(RedisCommand("SELECT", configuration.database))
        if let error = reply.serverError {
            throw RedisClientError.handshakeFailed("Couldn't select database \(configuration.database): \(error.message)")
        }
    }

    private static func isUnknownCommand(_ error: RedisServerError) -> Bool {
        error.message.localizedCaseInsensitiveContains("unknown command")
    }

    private static func isAuthenticationError(_ error: RedisServerError) -> Bool {
        ["WRONGPASS", "NOAUTH", "NOPERM"].contains(error.code)
            || error.message.localizedCaseInsensitiveContains("invalid password")
            || error.message.localizedCaseInsensitiveContains("without any password configured")
    }

    private static func authenticationMessage(_ error: RedisServerError) -> String {
        if error.code == "NOAUTH" { return "The server requires a password." }
        if error.code == "WRONGPASS" { return "Invalid username or password." }
        return error.message
    }
}

// MARK: - Pending reply bookkeeping

/// Replies still owed for one `pipeline` call. Only touched from the owning actor.
private final class PendingBatch {
    let id: UInt64
    let expected: Int
    var results: [RESPValue]
    var continuation: CheckedContinuation<[RESPValue], any Error>?

    init(id: UInt64, expected: Int, continuation: CheckedContinuation<[RESPValue], any Error>) {
        self.id = id
        self.expected = expected
        self.continuation = continuation
        results = []
        results.reserveCapacity(expected)
    }
}

/// FIFO with O(1) amortised removal from the front.
private struct PendingQueue {
    private var storage: [PendingBatch] = []
    private var head = 0

    var first: PendingBatch? { head < storage.count ? storage[head] : nil }

    mutating func append(_ batch: PendingBatch) {
        storage.append(batch)
    }

    mutating func removeFirst() {
        head += 1
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }

    func first(where predicate: (PendingBatch) -> Bool) -> PendingBatch? {
        storage[head...].first(where: predicate)
    }

    mutating func drain() -> ArraySlice<PendingBatch> {
        let remaining = storage[head...]
        storage = []
        head = 0
        return remaining
    }
}
