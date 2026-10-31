import Foundation
import Observation
import RediCore
import RedisClient
import RedisWire
import SwiftUI

/// Cluster topology with live per-node statistics.
@Observable
final class NodesModel {
    struct Row: Identifiable, Hashable {
        var id: String
        var address: String
        var role: ClusterNode.Role
        var primaryAddress: String?
        var slots: String
        var slotCount: Int
        var health: String
        var memory: Int64?
        var opsPerSecond: Int64?
        var clients: Int64?
        var keys: Int64?
        var version: String?
    }

    private(set) var rows: [Row] = []
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private unowned let workspace: WorkspaceModel

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
    }

    func refresh() async {
        guard let session = workspace.session else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await session.refreshTopology()
            guard let topology = await session.topology else { throw RedisSession.SessionError.notCluster }
            let byID = Dictionary(uniqueKeysWithValues: topology.nodes.map { ($0.id, $0) })
            var rows = topology.nodes.map { node in
                Row(id: node.id, address: node.endpoint.description, role: node.role,
                    primaryAddress: node.primaryID.flatMap { byID[$0]?.endpoint.description },
                    slots: Self.describe(node.slots), slotCount: node.slotCount, health: node.health)
            }
            // INFO from every node concurrently (replicas included), on the background role.
            let infos = await withTaskGroup(of: (Int, RedisInfo?).self) { group in
                for (index, node) in topology.nodes.enumerated() {
                    group.addTask {
                        let reply = try? await session.send(RedisCommand("INFO"), role: .background, target: .node(node.endpoint))
                        return (index, reply?.string.map(RedisInfo.init(parsing:)))
                    }
                }
                var results = [RedisInfo?](repeating: nil, count: topology.nodes.count)
                for await (index, info) in group { results[index] = info }
                return results
            }
            for (index, info) in infos.enumerated() {
                guard let info else { continue }
                rows[index].memory = info.int("used_memory")
                rows[index].opsPerSecond = info.int("instantaneous_ops_per_sec")
                rows[index].clients = info.int("connected_clients")
                rows[index].keys = info.sections.first { $0.name == "Keyspace" }?.fields
                    .compactMap { Int64(RedisInfo.parseList($0.value)["keys"] ?? "") }.reduce(0, +)
                rows[index].version = info["redis_version"]
            }
            self.rows = rows.sorted { ($0.primaryAddress ?? $0.address, $0.role == .replica ? 1 : 0) < ($1.primaryAddress ?? $1.address, $1.role == .replica ? 1 : 0) }
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    static func describe(_ ranges: [ClosedRange<Int>]) -> String {
        ranges.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ", ")
    }
}

struct NodesView: View {
    let model: NodesModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.rows.filter { $0.role == .primary }.count) primaries · \(model.rows.filter { $0.role == .replica }.count) replicas")
                    .foregroundStyle(.secondary)
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(1)
                }
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            }
            .padding(10)
            Divider()
            Table(model.rows) {
                TableColumn("Node") { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.role == .primary ? "crown.fill" : "arrow.turn.down.right")
                            .foregroundStyle(row.role == .primary ? .orange : .secondary)
                            .accessibilityLabel(row.role == .primary ? "Primary" : "Replica")
                        Text(row.address).font(.body.monospaced())
                    }
                }
                .width(min: 160, ideal: 190)
                TableColumn("Slots") { row in
                    Text(row.role == .primary ? "\(row.slots) (\(row.slotCount.formatted()))" : "replica of \(row.primaryAddress ?? "?")")
                        .foregroundStyle(row.role == .primary ? .primary : .secondary)
                        .lineLimit(1)
                }
                TableColumn("Health") { row in
                    Text(row.health).foregroundStyle(row.health == "online" ? .green : .orange)
                }
                .width(70)
                TableColumn("Memory") { Text($0.memory?.byteSize ?? "—").monospacedDigit() }.width(80)
                TableColumn("Ops/s") { Text($0.opsPerSecond.map { $0.formatted() } ?? "—").monospacedDigit() }.width(70)
                TableColumn("Clients") { Text($0.clients.map { $0.formatted() } ?? "—").monospacedDigit() }.width(60)
                TableColumn("Keys") { Text($0.keys.map { $0.formatted() } ?? "—").monospacedDigit() }.width(80)
                TableColumn("Version") { Text($0.version ?? "—").foregroundStyle(.secondary) }.width(70)
            }
        }
        .task { await model.refresh() }
    }
}
