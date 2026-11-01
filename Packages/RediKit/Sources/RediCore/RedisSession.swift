import Foundation
import RedisClient
import RedisWire

/// Everything Redi holds open to one Redis deployment: a standalone server, a Sentinel-managed
/// primary, or a whole cluster. It handles routing, redirection and failover so features above it
/// just send commands.
///
/// - Connections are dedicated per purpose (`Role`) and per node, opened lazily, and replaced
///   transparently after a drop. Long scans, MONITOR or Pub/Sub never delay interactive commands.
///   Commands in flight when a connection drops fail rather than being retried, because a retry
///   could run a non-idempotent command twice.
/// - **Databases:** `select(database:)` switches one at a time. Commands issued during a switch wait
///   for it, and every connection is brought to the current database before its next command, so
///   one session never reads from one database and writes to another.
/// - **Transactions:** MULTI/WATCH pin a role to one connection (and, in a cluster, one node) until
///   EXEC/DISCARD. Redirects aren't followed inside a transaction, so a write can't escape it; if
///   the pinned connection drops, the next command fails instead of running untransacted.
/// - **Cluster:** routes by hash slot using the server's command table (or `COMMAND GETKEYS` for
///   movable keys), follows `MOVED`/`ASK`, splits pipelines per node and fans out to primaries.
/// - **Sentinel:** resolves the primary from the sentinels and follows `+switch-master` live.
/// - **SSH:** every node address is forwarded through one control-master tunnel.
public actor RedisSession {
    public enum Role: Hashable, Sendable, CaseIterable {
        /// Interactive commands: key details, edits, CLI, Workbench.
        case command
        /// Key Browser scanning and row metadata.
        case scan
        /// Pub/Sub subscriptions.
        case subscriber
        /// MONITOR (Profiler).
        case monitor
        /// Long-running work such as Database Analysis and bulk actions.
        case background
        /// The CLI's own connection, so MULTI, blocking commands or CLIENT settings typed there
        /// never affect the browser.
        case cli
        /// The Workbench's own connection.
        case workbench

        /// Whether the role's connections follow the selected database (Pub/Sub and MONITOR don't).
        var usesDatabase: Bool { self != .subscriber && self != .monitor }
    }

    public enum Target: Hashable, Sendable {
        /// Route by the command's keys (cluster) or to the single primary.
        case automatic
        /// A specific node.
        case node(RedisEndpoint)
        /// Every primary. `send` returns a map of node address → reply.
        case allPrimaries
    }

    public enum Mode: Sendable, Hashable {
        case standalone
        case cluster
        case sentinel(SentinelOptions)
    }

    public struct SentinelOptions: Sendable, Hashable {
        public var masterName: String
        public var sentinels: [RedisEndpoint]
        public var username: String?
        public var password: String?

        public init(masterName: String, sentinels: [RedisEndpoint], username: String? = nil, password: String? = nil) {
            self.masterName = masterName
            self.sentinels = sentinels
            self.username = username
            self.password = password
        }
    }

    public struct Options: Sendable {
        public var mode: Mode
        /// Switch to cluster routing automatically when a standalone profile reaches a cluster node.
        public var detectsCluster: Bool
        public var tunnel: SSHTunnel.Configuration?
        public var isReadOnly: Bool

        public init(mode: Mode = .standalone, detectsCluster: Bool = true, tunnel: SSHTunnel.Configuration? = nil, isReadOnly: Bool = false) {
            self.mode = mode
            self.detectsCluster = detectsCluster
            self.tunnel = tunnel
            self.isReadOnly = isReadOnly
        }
    }

    public enum Event: Sendable, Hashable {
        /// Sentinel promoted a new primary; connections were moved to it.
        case failover(RedisEndpoint)
        case topologyChanged
    }

    public enum SessionError: Error, Sendable, Hashable, CustomStringConvertible {
        case readOnly(String)
        /// Read-only mode couldn't confirm the command only reads (no server metadata for it).
        case readOnlyUnverified(String)
        case tooManyRedirects
        case noNodeForSlot(Int)
        case notCluster
        /// The connection holding a MULTI or WATCH dropped, so the server discarded the transaction.
        case transactionLost
        /// A transaction's keys belong to different cluster nodes, so no single connection can run it.
        case crossNodeTransaction

        public var description: String {
            switch self {
            case .readOnly(let command): "\(command) is blocked because this connection is read-only."
            case .readOnlyUnverified(let command):
                "\(command) is blocked because this connection is read-only, and the server didn't report whether \(command) only reads data."
            case .tooManyRedirects: "The cluster redirected the command too many times."
            case .noNodeForSlot(let slot): "No cluster node serves slot \(slot)."
            case .notCluster: "This server isn't part of a cluster."
            case .transactionLost:
                "The connection was lost during the transaction, so the server discarded it and nothing queued was applied. Start again with MULTI (and WATCH)."
            case .crossNodeTransaction:
                "A transaction can only use keys served by one cluster node, and these keys belong to different nodes."
            }
        }
    }

    public struct NodeReply: Sendable, Hashable {
        public var node: RedisEndpoint
        public var reply: RESPValue
    }

    public nonisolated let configuration: RedisConnectionConfiguration
    public nonisolated let options: Options
    public nonisolated let events: AsyncStream<Event>

    public private(set) var hello: ServerHello?
    public private(set) var database: Int
    public private(set) var topology: ClusterTopology?
    /// The standalone server or current Sentinel primary (logical address, before tunnelling).
    public private(set) var primaryEndpoint: RedisEndpoint

    private struct Key: Hashable {
        var role: Role
        var node: RedisEndpoint
    }

    /// A role's open MULTI or WATCH, tracked from the commands sent through `send` and `pipeline`.
    /// The server keeps this state per connection, so the role stays on that one connection.
    private struct Transaction {
        var node: RedisEndpoint?
        /// The connection the transaction lives on; if it's replaced, the transaction is gone.
        var connection: ObjectIdentifier?
        var inMulti = false
        var watching = false
        /// MULTI went to the default node because nothing had chosen one; it may still move.
        var provisional = false
        /// Commands sent since MULTI, errors included (an error marks the transaction failed).
        var commandsInMulti = 0

        var isActive: Bool { inMulti || watching }

        mutating func apply(_ name: String, reply: RESPValue) {
            switch name {
            case "RESET":
                inMulti = false
                watching = false
            case "EXEC", "DISCARD":
                // Outside MULTI these just fail, and any WATCH stays in place.
                if inMulti {
                    inMulti = false
                    watching = false
                }
            case "MULTI" where !inMulti:
                if reply.serverError == nil {
                    inMulti = true
                    commandsInMulti = 0
                }
            case "WATCH" where !inMulti:
                if reply.serverError == nil { watching = true }
            case "UNWATCH" where !inMulti:
                watching = false
            default:
                if inMulti { commandsInMulti += 1 }
            }
        }
    }

    /// Commands that start tracking a transaction for their role.
    private static let transactionStarters: Set<String> = ["MULTI", "WATCH"]

    private let transportFactory: RedisTransportFactory
    private let eventContinuation: AsyncStream<Event>.Continuation
    private var tunnel: SSHTunnel?
    private var tunnelTask: Task<SSHTunnel, any Error>?
    private var connections: [Key: RedisConnection] = [:]
    private var connecting: [Key: Task<RedisConnection, any Error>] = [:]
    /// The database each data connection is in. Compared with `database` before every use.
    private var connectionDatabases: [Key: Int] = [:]
    /// The database switch in progress (`select`); data connections wait for it.
    private var databaseSwitch: Task<Void, any Error>?
    private var transactions: [Role: Transaction] = [:]
    private var openTask: Task<ServerHello, any Error>?
    private var isOpen = false
    /// Set by `close()`; a closed session can't be reused.
    public private(set) var isClosed = false
    private var table: CommandTable?
    private var tableTask: Task<CommandTable, any Error>?
    private var topologyRefresh: Task<Void, Never>?
    private var sentinelWatcher: Task<Void, Never>?

    public init(configuration: RedisConnectionConfiguration,
                options: Options = Options(),
                transportFactory: @escaping RedisTransportFactory = RedisConnection.defaultTransportFactory) {
        self.configuration = configuration
        self.options = options
        self.transportFactory = transportFactory
        database = configuration.database
        primaryEndpoint = configuration.endpoint
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    public var isCluster: Bool { topology != nil }

    /// Primaries to address individually (the single server when not clustered).
    public func primaries() -> [RedisEndpoint] {
        if let topology { return topology.primaries.map(\.endpoint) }
        return [primaryEndpoint]
    }

    // MARK: - Lifecycle

    /// Opens the tunnel, resolves the primary (Sentinel) or topology (cluster), and verifies
    /// credentials on the command connection.
    @discardableResult
    public func open() async throws -> ServerHello {
        if isOpen, let hello { return hello }
        if let openTask { return try await openTask.value }
        let task = Task { try await self.performOpen() }
        openTask = task
        defer { openTask = nil }
        return try await task.value
    }

    private func performOpen() async throws -> ServerHello {
        if isClosed { throw RedisClientError.connectionClosed }
        _ = try await liveTunnel()
        if case .sentinel(let sentinel) = options.mode {
            primaryEndpoint = try await resolveSentinelPrimary(sentinel)
            startSentinelWatcher(sentinel)
        }
        let connection = try await rawConnection(role: .command, node: primaryEndpoint)
        let hello = await connection.hello
        self.hello = hello
        let wantsCluster = options.mode == .cluster || (options.detectsCluster && options.mode == .standalone)
        if hello?.mode == .cluster, wantsCluster {
            try await refreshTopology()
            _ = try? await commandTable()
        }
        isOpen = true
        guard let hello else { throw RedisClientError.handshakeFailed("No server information") }
        return hello
    }

    /// Closes every connection and the tunnel. The session can't be reused afterwards.
    public func close() async {
        isClosed = true
        sentinelWatcher?.cancel()
        topologyRefresh?.cancel()
        for task in connecting.values { task.cancel() }
        connecting.removeAll()
        for connection in connections.values { await connection.close() }
        connections.removeAll()
        transactions.removeAll()
        tunnel?.close()
        tunnel = nil
        eventContinuation.finish()
    }

    /// Closes the connections for `role` (e.g. when the Profiler stops, or the CLI cancels a command).
    /// The server discards any transaction they held; since that's deliberate, the next command
    /// simply starts fresh rather than reporting the transaction as lost.
    public func release(_ role: Role) async {
        transactions[role] = nil
        for key in connecting.keys where key.role == role { connecting.removeValue(forKey: key)?.cancel() }
        for key in connections.keys where key.role == role { await connections.removeValue(forKey: key)?.close() }
    }

    // MARK: - Connections

    /// The live connection for `role` on `node` (default: the primary, or the first cluster primary).
    /// Commands sent on it skip read-only enforcement, so it's internal: only the streaming
    /// listeners (SUBSCRIBE, MONITOR) need it. Everything else goes through `send`, `pipeline` or `fanOut`.
    func connection(for role: Role = .command, node: RedisEndpoint? = nil) async throws -> RedisConnection {
        if !isOpen { try await open() }
        return try await rawConnection(role: role, node: node ?? defaultNode)
    }

    private var defaultNode: RedisEndpoint { topology?.primaries.first?.endpoint ?? primaryEndpoint }

    /// The connection for `role` on `node`, in the session's current database.
    private func rawConnection(role: Role, node: RedisEndpoint) async throws -> RedisConnection {
        if role.usesDatabase { await waitForDatabaseSwitch() }
        let key = Key(role: role, node: node)
        let connection = try await liveConnection(for: key)
        try await reconcileDatabase(of: connection, key: key)
        return connection
    }

    /// The open connection for `key`, connecting (once, shared by concurrent callers) if needed.
    private func liveConnection(for key: Key) async throws -> RedisConnection {
        if isClosed { throw RedisClientError.connectionClosed }
        if let existing = connections[key], await !existing.isClosed { return existing }
        if let inFlight = connecting[key] { return try await inFlight.value }

        let factory = transportFactory
        let task = Task { () throws -> RedisConnection in
            let configuration = try await self.connectionConfiguration(for: key.node)
            let connection = try await RedisConnection.connect(configuration, transportFactory: factory)
            // Registered here, before any waiter resumes, together with the database the connection
            // actually opened in: a switch may have happened while it was connecting.
            try await self.register(connection, key: key, database: configuration.database)
            return connection
        }
        connecting[key] = task
        defer { connecting[key] = nil }
        return try await task.value
    }

    private func register(_ connection: RedisConnection, key: Key, database: Int) async throws {
        if isClosed {
            await connection.close()
            throw RedisClientError.connectionClosed
        }
        connections[key] = connection
        connectionDatabases[key] = database
    }

    /// Waits for database switches in progress (including ones queued behind them).
    private func waitForDatabaseSwitch() async {
        var awaited: Task<Void, any Error>?
        while let pending = databaseSwitch, pending != awaited {
            _ = await pending.result
            awaited = pending
        }
    }

    /// Brings a data connection to the session's database. Skipped inside MULTI, where SELECT would
    /// only be queued; the connection catches up after EXEC or DISCARD.
    private func reconcileDatabase(of connection: RedisConnection, key: Key) async throws {
        guard key.role.usesDatabase, !isCluster, transactions[key.role]?.inMulti != true else { return }
        // Loops because the database can change again while SELECT is in flight.
        while connections[key] === connection, let current = connectionDatabases[key], current != database {
            let wanted = database
            try await connection.execute(RedisCommand("SELECT", wanted))
            if connections[key] === connection { connectionDatabases[key] = wanted }
        }
    }

    /// The SSH tunnel (`nil` without one), reopened if its ssh master has exited, e.g. after the
    /// network dropped or the Mac slept past ssh's keepalive. Forwards and connections made through
    /// the old master are dead with it, so they're dropped and replacements go through the new one.
    private func liveTunnel() async throws -> SSHTunnel? {
        guard let tunnelConfiguration = options.tunnel else { return nil }
        if let tunnel, tunnel.isRunning { return tunnel }
        if let tunnelTask { return try await tunnelTask.value }
        let task = Task { try await SSHTunnel.open(tunnelConfiguration) }
        tunnelTask = task
        defer { tunnelTask = nil }
        if let dead = tunnel {
            tunnel = nil
            dead.close()
            let stale = connections.values
            connections.removeAll()
            for connection in stale { await connection.close() }
        }
        let opened = try await task.value
        if isClosed {
            opened.close()
            throw RedisClientError.connectionClosed
        }
        tunnel = opened
        return opened
    }

    /// The tunnel in use, for tests.
    var currentTunnel: SSHTunnel? { tunnel }

    private func connectionConfiguration(for node: RedisEndpoint, sentinel: SentinelOptions? = nil) async throws -> RedisConnectionConfiguration {
        var configuration = self.configuration
        configuration.database = (isCluster || sentinel != nil) ? 0 : database
        if let sentinel {
            configuration.username = sentinel.username
            configuration.password = sentinel.password
        }
        if let tunnel = try await liveTunnel(), case .tcp(let host, let port) = node {
            configuration.endpoint = try await tunnel.forward(to: host, port: port)
            if configuration.tls != nil, configuration.tls?.serverName == nil {
                configuration.tls?.serverName = host
            }
        } else {
            configuration.endpoint = node
        }
        return configuration
    }

    // MARK: - Commands

    /// Sends a command, following cluster redirections. Error replies are returned as values.
    public func send(_ command: RedisCommand, role: Role = .command, target: Target = .automatic) async throws -> RESPValue {
        try await enforceReadOnly(command)
        if case .allPrimaries = target {
            // A transaction lives on one connection; fanning out would run commands on the others
            // immediately, outside it.
            if transactions[role] != nil || Self.transactionStarters.contains(command.name) {
                throw SessionError.crossNodeTransaction
            }
            let replies = try await unguardedFanOut(command, role: role)
            return .map(replies.map { RESPPair(.simpleString($0.node.description), $0.reply) })
        }
        if !isOpen { try await open() }
        if transactions[role] != nil || Self.transactionStarters.contains(command.name) {
            return try await sendInTransaction(command, role: role, target: target)
        }
        var node = try await route(command, target: target)
        var asking = false
        for _ in 0..<5 {
            let connection = try await rawConnection(role: role, node: node)
            let reply: RESPValue
            if asking {
                reply = try await connection.pipeline([RedisCommand("ASKING"), command])[1]
                asking = false
            } else {
                reply = try await connection.send(command)
            }
            guard isCluster, let error = reply.serverError,
                  let redirect = ClusterRedirect(error, defaultHost: node.host ?? "") else { return reply }
            switch redirect.kind {
            case .moved:
                topology?.assign(slot: redirect.slot, to: redirect.endpoint)
                scheduleTopologyRefresh()
            case .ask:
                asking = true
            }
            node = redirect.endpoint
        }
        throw SessionError.tooManyRedirects
    }

    /// Like `send` but throws `RedisServerError` for error replies.
    @discardableResult
    public func execute(_ command: RedisCommand, role: Role = .command, target: Target = .automatic) async throws -> RESPValue {
        try await send(command, role: role, target: target).throwIfError()
    }

    /// Sends a batch, grouped per node in cluster mode, and returns replies in input order. A batch
    /// with a transaction (or sent while one is open) goes to a single connection, unsplit.
    public func pipeline(_ commands: [RedisCommand], role: Role = .command, target: Target = .automatic) async throws -> [RESPValue] {
        guard !commands.isEmpty else { return [] }
        for command in commands { try await enforceReadOnly(command) }
        if !isOpen { try await open() }
        if target != .allPrimaries,
           transactions[role] != nil || commands.contains(where: { Self.transactionStarters.contains($0.name) }) {
            return try await pipelineInTransaction(commands, role: role, target: target)
        }

        switch target {
        case .node(let node):
            return try await rawConnection(role: role, node: node).pipeline(commands)
        case .allPrimaries:
            var results: [RESPValue] = []
            for command in commands { results.append(try await send(command, role: role, target: .allPrimaries)) }
            return results
        case .automatic:
            break
        }
        guard isCluster else { return try await rawConnection(role: role, node: primaryEndpoint).pipeline(commands) }

        var groups: [RedisEndpoint: [Int]] = [:]
        for (index, command) in commands.enumerated() {
            groups[try await route(command, target: .automatic), default: []].append(index)
        }
        var results = [RESPValue](repeating: .null, count: commands.count)
        if groups.count == 1, let node = groups.keys.first {
            results = try await rawConnection(role: role, node: node).pipeline(commands)
        } else {
            var batches: [(RedisConnection, [Int])] = []
            for (node, indices) in groups { batches.append((try await rawConnection(role: role, node: node), indices)) }
            try await withThrowingTaskGroup(of: ([Int], [RESPValue]).self) { group in
                for (connection, indices) in batches {
                    let batch = indices.map { commands[$0] }
                    group.addTask { (indices, try await connection.pipeline(batch)) }
                }
                for try await (indices, replies) in group {
                    for (offset, reply) in replies.enumerated() { results[indices[offset]] = reply }
                }
            }
        }
        // Slots that moved mid-pipeline are retried one by one.
        for index in results.indices {
            if let error = results[index].serverError, ClusterRedirect(error, defaultHost: "") != nil {
                results[index] = try await send(commands[index], role: role)
            }
        }
        return results
    }

    /// Runs a command on every primary concurrently (e.g. `DBSIZE`, `INFO`, `SLOWLOG GET`).
    public func fanOut(_ command: RedisCommand, role: Role = .command) async throws -> [NodeReply] {
        try await enforceReadOnly(command)
        return try await unguardedFanOut(command, role: role)
    }

    /// `fanOut` without the read-only check, for callers that already ran it.
    private func unguardedFanOut(_ command: RedisCommand, role: Role) async throws -> [NodeReply] {
        if !isOpen { try await open() }
        let nodes = primaries()
        var connections: [RedisConnection] = []
        for node in nodes { connections.append(try await rawConnection(role: role, node: node)) }
        return try await withThrowingTaskGroup(of: (Int, RESPValue).self) { group in
            for (index, connection) in connections.enumerated() {
                group.addTask { (index, try await connection.send(command)) }
            }
            var replies = [RESPValue](repeating: .null, count: nodes.count)
            for try await (index, reply) in group { replies[index] = reply }
            return zip(nodes, replies).map { NodeReply(node: $0, reply: $1) }
        }
    }

    /// Switches the session to `database`. Switches run one at a time, and data commands issued
    /// meanwhile wait for it. The server validates the switch on the command connection first: if it
    /// refuses (an index out of range, ACL), nothing changes. Other connections switch before their
    /// next command.
    public func select(database: Int) async throws {
        // Opened up front: opening waits for switches, so it can't happen inside one.
        if !isOpen { try await open() }
        let previous = databaseSwitch
        let task = Task { () throws in
            _ = await previous?.result
            try await self.performSelect(database)
        }
        databaseSwitch = task
        defer { if databaseSwitch == task { databaseSwitch = nil } }
        try await task.value
    }

    private func performSelect(_ database: Int) async throws {
        guard database != self.database else { return }
        guard !isCluster else { throw SessionError.notCluster }
        let key = Key(role: .command, node: primaryEndpoint)
        let connection = try await liveConnection(for: key)
        try await connection.execute(RedisCommand("SELECT", database))
        if connections[key] === connection { connectionDatabases[key] = database }
        self.database = database
    }

    // MARK: - Transactions

    /// Sends a command for a role with an open transaction, or one starting it (MULTI, WATCH).
    private func sendInTransaction(_ command: RedisCommand, role: Role, target: Target) async throws -> RESPValue {
        var state = transactions[role] ?? Transaction()
        let node: RedisEndpoint
        if let pinned = state.node {
            try await requireLiveTransaction(state, role: role)
            if isCluster, state.provisional, state.commandsInMulti == 0, target == .automatic,
               let owner = try await keyOwner(of: command), owner != pinned {
                // Nothing has been sent inside MULTI yet, so it can move to the node owning this key.
                _ = try await rawConnection(role: role, node: pinned).send(RedisCommand("DISCARD"))
                transactions[role] = nil
                let moved = try await rawConnection(role: role, node: owner)
                let reply = try await moved.send(RedisCommand("MULTI"))
                if let error = reply.serverError { throw error }
                state.node = owner
                state.connection = ObjectIdentifier(moved)
                state.provisional = false
                node = owner
            } else {
                node = pinned
            }
        } else {
            node = try await transactionNode(for: [command], target: target)
            state.node = node
            state.provisional = isCluster && target == .automatic && command.name == "MULTI"
        }
        let connection = try await rawConnection(role: role, node: node)
        if state.connection == nil { state.connection = ObjectIdentifier(connection) }
        // Redirects aren't followed: resending to another node would run the command outside the
        // transaction. The server marks the transaction failed instead, so EXEC applies nothing.
        let reply = try await connection.send(command)
        state.apply(command.name, reply: reply)
        transactions[role] = state.isActive ? state : nil
        return reply
    }

    /// Sends a batch containing (or continuing) a transaction on one connection.
    private func pipelineInTransaction(_ commands: [RedisCommand], role: Role, target: Target) async throws -> [RESPValue] {
        var state = transactions[role] ?? Transaction()
        let node: RedisEndpoint
        if let pinned = state.node {
            try await requireLiveTransaction(state, role: role)
            node = pinned
        } else {
            node = try await transactionNode(for: commands, target: target)
            state.node = node
        }
        let connection = try await rawConnection(role: role, node: node)
        if state.connection == nil { state.connection = ObjectIdentifier(connection) }
        let replies = try await connection.pipeline(commands)
        for (command, reply) in zip(commands, replies) { state.apply(command.name, reply: reply) }
        transactions[role] = state.isActive ? state : nil
        return replies
    }

    /// Fails (and forgets the transaction) if the connection it lived on has dropped or been replaced.
    private func requireLiveTransaction(_ state: Transaction, role: Role) async throws {
        if let node = state.node, let id = state.connection, let existing = connections[Key(role: role, node: node)],
           ObjectIdentifier(existing) == id, await !existing.isClosed {
            return
        }
        transactions[role] = nil
        throw SessionError.transactionLost
    }

    /// The node for a new transaction: the target node, or in a cluster the single node owning every
    /// key in `commands` (the default node when they're keyless). Keys on several nodes are refused
    /// before anything is sent.
    private func transactionNode(for commands: [RedisCommand], target: Target) async throws -> RedisEndpoint {
        if case .node(let node) = target { return node }
        guard let topology else { return primaryEndpoint }
        var owners = Set<RedisEndpoint>()
        for command in commands {
            if command.name == "WATCH" {
                for key in command.arguments.dropFirst() {
                    let slot = HashSlot.slot(for: key)
                    guard let node = topology.primary(forSlot: slot) else { throw SessionError.noNodeForSlot(slot) }
                    owners.insert(node.endpoint)
                }
            } else if let owner = try await keyOwner(of: command) {
                owners.insert(owner)
            }
        }
        guard owners.count <= 1 else { throw SessionError.crossNodeTransaction }
        return owners.first ?? defaultNode
    }

    /// The primary owning the command's first key, or `nil` for keyless commands and non-clusters.
    private func keyOwner(of command: RedisCommand) async throws -> RedisEndpoint? {
        guard let topology, let key = try await firstKey(of: command) else { return nil }
        let slot = HashSlot.slot(for: key)
        guard let node = topology.primary(forSlot: slot) else { throw SessionError.noNodeForSlot(slot) }
        return node.endpoint
    }

    // MARK: - Command metadata

    /// The server's command table (`COMMAND`), fetched once. Empty if the server refuses it.
    public func commandTable() async throws -> CommandTable {
        if let table { return table }
        if let tableTask { return try await tableTask.value }
        let task = Task { () throws -> CommandTable in
            let connection = try await self.rawConnection(role: .command, node: self.defaultNode)
            let reply = try await connection.send(RedisCommand("COMMAND"))
            return reply.serverError == nil ? CommandTable(reply: reply) : .empty
        }
        tableTask = task
        defer { tableTask = nil }
        let loaded = try await task.value
        table = loaded
        return loaded
    }

    private func enforceReadOnly(_ command: RedisCommand) async throws {
        guard options.isReadOnly else { return }
        // Open first, so the table comes from the data server (through the tunnel, or from the
        // primary Sentinel resolved) rather than the configured address.
        if !isOpen { try await open() }
        // A failure to fetch the table (e.g. the server is unreachable) is thrown as-is, so it isn't
        // reported as a read-only refusal. A server that refuses COMMAND yields an empty table.
        let table = try await commandTable()
        switch CommandSafety.readOnlyCheck(command.arguments, table: table) {
        case .allowed: return
        case .forbidden: throw SessionError.readOnly(command.name)
        case .unverified: throw SessionError.readOnlyUnverified(command.name)
        }
    }

    // MARK: - Cluster

    private func route(_ command: RedisCommand, target: Target) async throws -> RedisEndpoint {
        switch target {
        case .node(let node): return node
        case .allPrimaries: return defaultNode
        case .automatic:
            guard let topology else { return primaryEndpoint }
            guard let key = try await firstKey(of: command) else { return defaultNode }
            let slot = HashSlot.slot(for: key)
            guard let node = topology.primary(forSlot: slot) else { throw SessionError.noNodeForSlot(slot) }
            return node.endpoint
        }
    }

    private func firstKey(of command: RedisCommand) async throws -> [UInt8]? {
        let table = try await commandTable()
        if let indices = table.keyIndices(for: command.arguments) {
            return indices.first.map { command.arguments[$0] }
        }
        guard table.info(for: command.arguments) != nil else { return nil }
        // Movable keys (EVAL, ZUNION, XREAD, ...): ask the server.
        let getKeys = RedisCommand(arguments: [Array("COMMAND".utf8), Array("GETKEYS".utf8)] + command.arguments)
        let reply = try await rawConnection(role: .command, node: defaultNode).send(getKeys)
        return reply.array?.first?.bytes
    }

    /// Reloads slot ownership (`CLUSTER SHARDS`, falling back to `CLUSTER SLOTS`).
    public func refreshTopology() async throws {
        let seed = topology?.primaries.first?.endpoint ?? primaryEndpoint
        let connection = try await rawConnection(role: .command, node: seed)
        let seedHost = primaryEndpoint.host ?? "127.0.0.1"
        var parsed: ClusterTopology?
        let shards = try await connection.send(RedisCommand("CLUSTER", "SHARDS"))
        if shards.serverError == nil {
            parsed = ClusterTopology.parse(shards: shards, seedHost: seedHost, preferTLSPort: configuration.tls != nil)
        }
        if parsed == nil {
            parsed = ClusterTopology.parse(slots: try await connection.execute(RedisCommand("CLUSTER", "SLOTS")), seedHost: seedHost)
        }
        guard let parsed else { throw RedisClientError.handshakeFailed("Couldn't read the cluster topology.") }
        topology = parsed
        eventContinuation.yield(.topologyChanged)
    }

    private func scheduleTopologyRefresh() {
        guard topologyRefresh == nil else { return }
        topologyRefresh = Task {
            try? await Task.sleep(for: .milliseconds(100))
            try? await self.refreshTopology()
            self.topologyRefresh = nil
        }
    }

    // MARK: - Sentinel

    private func sentinelConfigurations(_ sentinel: SentinelOptions) async throws -> [RedisConnectionConfiguration] {
        var configurations: [RedisConnectionConfiguration] = []
        for endpoint in sentinel.sentinels {
            var configuration = try await connectionConfiguration(for: endpoint, sentinel: sentinel)
            configuration.connectTimeout = min(configuration.connectTimeout, .seconds(5))
            configurations.append(configuration)
        }
        return configurations
    }

    private func resolveSentinelPrimary(_ sentinel: SentinelOptions) async throws -> RedisEndpoint {
        let configurations = try await sentinelConfigurations(sentinel)
        return try await Sentinel.resolveMaster(named: sentinel.masterName, sentinels: configurations,
                                                transportFactory: transportFactory).master
    }

    /// Subscribes to `+switch-master` on a sentinel and moves the session to each new primary.
    private func startSentinelWatcher(_ sentinel: SentinelOptions) {
        sentinelWatcher?.cancel()
        sentinelWatcher = Task { [weak self] in
            var delay = Duration.seconds(1)
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let configurations = try await self.sentinelConfigurations(sentinel)
                    var watcher: RedisConnection?
                    for configuration in configurations {
                        if let connection = try? await RedisConnection.connect(configuration, transportFactory: self.transportFactory) {
                            watcher = connection
                            break
                        }
                    }
                    if let watcher {
                        try await watcher.sendWithoutReply(RedisCommand("SUBSCRIBE", "+switch-master"))
                        // Catch failovers that happened while we weren't listening.
                        if let current = try? await self.resolveSentinelPrimary(sentinel) { await self.moveToPrimary(current) }
                        delay = .seconds(1)
                        for await message in watcher.pushes {
                            guard let parts = message.array, parts.count == 3, parts[0].string == "message",
                                  let payload = parts[2].string else { continue }
                            let fields = payload.split(separator: " ")
                            guard fields.count == 5, fields[0] == Substring(sentinel.masterName), let port = Int(fields[4]) else { continue }
                            await self.moveToPrimary(.tcp(host: String(fields[3]), port: port))
                        }
                        await watcher.close()
                    }
                } catch {}
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(30))
            }
        }
    }

    private func moveToPrimary(_ endpoint: RedisEndpoint) async {
        guard endpoint != primaryEndpoint, !isClosed else { return }
        primaryEndpoint = endpoint
        for connection in connections.values { await connection.close() }
        connections.removeAll()
        eventContinuation.yield(.failover(endpoint))
    }
}

extension RedisEndpoint {
    public var host: String? {
        if case .tcp(let host, _) = self { return host }
        return nil
    }

    public var port: Int? {
        if case .tcp(_, let port) = self { return port }
        return nil
    }
}
