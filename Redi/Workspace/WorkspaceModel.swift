import Foundation
import Observation
import RediCore
import RedisClient
import RedisWire

/// State for one connection window. Feature models are created on first use and share the
/// window's `RedisSession`.
@Observable
final class WorkspaceModel {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected(ServerHello)
        case failed(String)
    }

    let profile: ConnectionProfile
    private(set) var status: Status = .disconnected
    var selection: SidebarItem? = .keys
    var isBottomPanelVisible = false
    var bottomPanelTab: BottomPanelTab = .cli
    /// Transient notice shown above the detail area (e.g. a Sentinel failover).
    private(set) var notice: String?
    private(set) var isCluster = false
    private(set) var clusterNodes: [ClusterNode] = []
    private(set) var primaryAddress: String
    private(set) var database: Int
    private(set) var databaseCount = 16
    /// A command for the CLI to pre-fill (set by "Open in CLI" actions).
    var pendingCLICommand: String?
    /// Command docs from the server (`COMMAND DOCS`), or the bundled catalog for older servers.
    private(set) var commandCatalog: CommandCatalog = .bundled

    @ObservationIgnored let session: RedisSession?
    @ObservationIgnored private let setupError: String?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var onConnected: (() -> Void)?
    @ObservationIgnored private var browserModel: BrowserModel?

    @ObservationIgnored private var cliModel: CLIModel?
    @ObservationIgnored private var nodesModel: NodesModel?
    @ObservationIgnored private var workbenchModel: WorkbenchModel?
    @ObservationIgnored private var pubSubModel: PubSubModel?
    @ObservationIgnored private var profilerModel: ProfilerModel?
    @ObservationIgnored private var overviewModel: OverviewModel?
    @ObservationIgnored private var slowLogModel: SlowLogModel?
    @ObservationIgnored private var analysisModel: AnalysisModel?

    var pubSub: PubSubModel { pubSubModel ?? { let model = PubSubModel(workspace: self); pubSubModel = model; return model }() }
    var profiler: ProfilerModel { profilerModel ?? { let model = ProfilerModel(workspace: self); profilerModel = model; return model }() }
    var overview: OverviewModel { overviewModel ?? { let model = OverviewModel(workspace: self); overviewModel = model; return model }() }
    var slowLog: SlowLogModel { slowLogModel ?? { let model = SlowLogModel(workspace: self); slowLogModel = model; return model }() }
    var analysis: AnalysisModel { analysisModel ?? { let model = AnalysisModel(workspace: self); analysisModel = model; return model }() }

    var workbench: WorkbenchModel {
        if let workbenchModel { return workbenchModel }
        let model = WorkbenchModel(workspace: self)
        workbenchModel = model
        return model
    }

    /// The Key Browser, created on first use.
    var browser: BrowserModel {
        if let browserModel { return browserModel }
        let model = BrowserModel(workspace: self)
        browserModel = model
        return model
    }

    var cli: CLIModel {
        if let cliModel { return cliModel }
        let model = CLIModel(workspace: self)
        cliModel = model
        return model
    }

    var nodes: NodesModel {
        if let nodesModel { return nodesModel }
        let model = NodesModel(workspace: self)
        nodesModel = model
        return model
    }

    init(profile: ConnectionProfile, secrets: ConnectionSecrets, onConnected: (() -> Void)? = nil) {
        self.profile = profile
        self.onConnected = onConnected
        database = profile.database
        primaryAddress = profile.address
        do {
            session = try SessionFactory.makeSession(profile: profile, secrets: secrets)
            setupError = nil
        } catch {
            session = nil
            setupError = String(describing: error)
        }
    }

    var hello: ServerHello? {
        if case .connected(let hello) = status { return hello }
        return nil
    }

    var isConnected: Bool { hello != nil }

    var keyDelimiter: String {
        profile.keyDelimiter ?? UserDefaults.standard.string(forKey: SettingsKey.keyDelimiter) ?? ":"
    }

    /// Window subtitle, e.g. "Redis 8.10.3 · standalone · db0".
    var subtitle: String {
        switch status {
        case .disconnected: String(localized: "Disconnected")
        case .connecting: String(localized: "Connecting to \(profile.address)…")
        case .failed: String(localized: "Not connected")
        case .connected(let hello):
            if isCluster {
                String(localized: "\(hello.server.capitalized) \(hello.version.description) · cluster · \(clusterNodes.filter { $0.role == .primary }.count) primaries")
            } else if profile.mode == .sentinel {
                String(localized: "\(hello.server.capitalized) \(hello.version.description) · sentinel → \(primaryAddress) · db\(database)")
            } else {
                String(localized: "\(hello.server.capitalized) \(hello.version.description) · \(hello.mode.displayName) · db\(database)")
            }
        }
    }

    // MARK: - Lifecycle

    func connect() async {
        guard let session else {
            status = .failed(setupError ?? "Invalid connection settings")
            return
        }
        status = .connecting
        do {
            let hello = try await session.open()
            await refreshTopologyState()
            if !isCluster, let reply = try? await session.send(RedisCommand("CONFIG", "GET", "databases")),
               let count = reply.pairs?.first?.value.int {
                databaseCount = max(1, Int(count))
            }
            status = .connected(hello)
            startObservingEvents()
            Task { await loadCommandCatalog(version: hello.version) }
            onConnected?()
            onConnected = nil
        } catch {
            status = .failed(String(describing: error))
        }
    }

    func reconnectIfNeeded() async {
        if case .connected = status { return }
        await connect()
    }

    func disconnect() async {
        await pubSubModel?.unsubscribe()
        await profilerModel?.stop()
        eventTask?.cancel()
        noticeTask?.cancel()
        await session?.close()
        status = .disconnected
    }

    func selectDatabase(_ index: Int) async {
        guard let session, index != database else { return }
        do {
            try await session.select(database: index)
            database = index
            browserModel?.databaseDidChange()
        } catch {
            show(notice: String(describing: error))
        }
    }

    func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func dismissNotice() {
        notice = nil
    }

    private func loadCommandCatalog(version: ServerVersion) async {
        guard version >= ServerVersion(7), let session,
              let reply = try? await session.send(RedisCommand("COMMAND", "DOCS")), reply.serverError == nil else { return }
        let catalog = CommandCatalog(commandDocsReply: reply)
        if !catalog.isEmpty { commandCatalog = catalog }
    }

    private func refreshTopologyState() async {
        guard let session else { return }
        let topology = await session.topology
        isCluster = topology != nil
        clusterNodes = topology?.nodes ?? []
        primaryAddress = await session.primaryEndpoint.description
    }

    private func startObservingEvents() {
        guard let session, eventTask == nil else { return }
        eventTask = Task { [weak self] in
            for await event in session.events {
                guard let self else { return }
                switch event {
                case .failover(let endpoint):
                    self.primaryAddress = endpoint.description
                    self.show(notice: String(localized: "Sentinel failover: now connected to the new primary at \(endpoint.description)."))
                case .topologyChanged:
                    await self.refreshTopologyState()
                }
            }
        }
    }
}

extension ServerHello.Mode {
    var displayName: String {
        switch self {
        case .standalone: "standalone"
        case .cluster: "cluster"
        case .sentinel: "sentinel"
        case .other(let name): name
        }
    }
}
