import Charts
import Foundation
import Observation
import RediCore
import RedisClient
import RedisWire
import SwiftUI

@Observable
final class OverviewModel {
    enum Scope: Hashable { case allPrimaries, node(RedisEndpoint) }

    var interval = 5 {
        didSet { if oldValue != interval { restartIfRunning() } }
    }
    var scope: Scope = .allPrimaries {
        didSet {
            if oldValue != scope {
                samples = []
                previous = [:]
                restartIfRunning()
            }
        }
    }
    private(set) var samples: [InfoSnapshot] = []
    private(set) var error: String?

    @ObservationIgnored private unowned let workspace: WorkspaceModel
    @ObservationIgnored private var previous: [RedisEndpoint: InfoSnapshot] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    private static let capacity = 180

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
    }

    var latest: InfoSnapshot? { samples.last }

    func setVisible(_ visible: Bool) {
        if visible { start() } else { stop() }
    }

    private func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.sample()
                count += 1
                // The second sample comes quickly so rates and charts have two points right away.
                let delay = count == 1 && self.samples.count < 2 ? 1 : self.interval
                // Tolerance lets the system coalesce wakeups.
                try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(Double(delay) * 0.1))
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
    }

    private func restartIfRunning() {
        guard task != nil else { return }
        stop()
        start()
    }

    private func sample() async {
        guard let session = workspace.session else { return }
        do {
            let date = Date()
            var snapshots: [InfoSnapshot] = []
            switch scope {
            case .allPrimaries:
                // One refused node fails the sample: partial totals would pass for the whole server.
                let replies = try await session.fanOut(RedisCommand("INFO"), role: .background)
                try replies.throwIfAnyError()
                for reply in replies {
                    snapshots.append(snapshot(reply.reply, node: reply.node, date: date))
                }
            case .node(let node):
                snapshots.append(snapshot(try await session.execute(RedisCommand("INFO"), role: .background, target: .node(node)), node: node, date: date))
            }
            guard let combined = InfoSnapshot.combine(snapshots) else { return }
            samples.append(combined)
            if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    private func snapshot(_ reply: RESPValue, node: RedisEndpoint, date: Date) -> InfoSnapshot {
        let snapshot = InfoSnapshot(info: RedisInfo(parsing: reply.string ?? ""), previous: previous[node], date: date)
        previous[node] = snapshot
        return snapshot
    }
}

struct OverviewView: View {
    @Bindable var model: OverviewModel
    let workspace: WorkspaceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controls
                if let latest = model.latest {
                    metrics(latest)
                    charts
                    keyspace(latest)
                } else if let error = model.error {
                    ContentUnavailableView("Couldn't Read INFO", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
        .onVisibilityChange { model.setVisible($0) }
    }

    private var controls: some View {
        HStack {
            if workspace.isCluster {
                Picker("Scope", selection: $model.scope) {
                    Text("All Primaries").tag(OverviewModel.Scope.allPrimaries)
                    ForEach(workspace.clusterNodes) { node in
                        Text("\(node.endpoint.description) (\(node.role == .primary ? "primary" : "replica"))").tag(OverviewModel.Scope.node(node.endpoint))
                    }
                }
                .fixedSize()
            }
            Spacer()
            Picker("Refresh", selection: $model.interval) {
                Text("1 s").tag(1)
                Text("2 s").tag(2)
                Text("5 s").tag(5)
                Text("10 s").tag(10)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private func metrics(_ latest: InfoSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            MetricCard(title: "Ops/sec", value: latest.opsPerSecond.formatted(.number.precision(.fractionLength(0))), systemImage: "bolt")
            MetricCard(title: "Memory", value: latest.usedMemory.byteSize,
                       detail: latest.maxMemory > 0 ? "of \(latest.maxMemory.byteSize)" : "no maxmemory", systemImage: "memorychip")
            MetricCard(title: "Clients", value: latest.connectedClients.formatted(),
                       detail: latest.blockedClients > 0 ? "\(latest.blockedClients) blocked" : nil, systemImage: "person.2")
            MetricCard(title: "Keys", value: latest.totalKeys.formatted(), detail: "\(latest.expiringKeys.formatted()) expiring", systemImage: "key")
            MetricCard(title: "Hit Ratio", value: latest.hitRatio.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "—", systemImage: "target")
            MetricCard(title: "CPU", value: latest.cpuPercent.map { $0.formatted(.number.precision(.fractionLength(1))) + "%" } ?? "—", systemImage: "cpu")
            MetricCard(title: "Network", value: "↓ \(latest.inputKbps.formatted(.number.precision(.fractionLength(1)))) KB/s",
                       detail: "↑ \(latest.outputKbps.formatted(.number.precision(.fractionLength(1)))) KB/s", systemImage: "network")
            MetricCard(title: "Uptime", value: Duration.seconds(latest.uptimeSeconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2)),
                       detail: latest.version.isEmpty ? nil : "v\(latest.version)", systemImage: "clock")
        }
    }

    private var charts: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
            ChartCard(title: "Operations per second") {
                Chart(model.samples) { LineMark(x: .value("Time", $0.date), y: .value("Ops/s", $0.opsPerSecond)).interpolationMethod(.monotone) }
            }
            ChartCard(title: "Memory") {
                Chart(model.samples) {
                    AreaMark(x: .value("Time", $0.date), y: .value("Used", $0.usedMemory)).foregroundStyle(.purple.opacity(0.25))
                    LineMark(x: .value("Time", $0.date), y: .value("Used", $0.usedMemory)).foregroundStyle(.purple)
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let bytes = value.as(Int64.self) { Text(bytes.byteSize) } }
                    }
                }
            }
            ChartCard(title: "Connected clients") {
                Chart(model.samples) { LineMark(x: .value("Time", $0.date), y: .value("Clients", $0.connectedClients)).foregroundStyle(.green) }
            }
            ChartCard(title: "CPU (% of a core)") {
                Chart(model.samples.filter { $0.cpuPercent != nil }) {
                    LineMark(x: .value("Time", $0.date), y: .value("CPU", $0.cpuPercent ?? 0)).foregroundStyle(.orange)
                }
            }
            ChartCard(title: "Network (KB/s)") {
                Chart(model.samples) {
                    LineMark(x: .value("Time", $0.date), y: .value("KB/s", $0.inputKbps), series: .value("Direction", "In"))
                        .foregroundStyle(by: .value("Direction", "In"))
                    LineMark(x: .value("Time", $0.date), y: .value("KB/s", $0.outputKbps), series: .value("Direction", "Out"))
                        .foregroundStyle(by: .value("Direction", "Out"))
                }
            }
            ChartCard(title: "Hit ratio") {
                Chart(model.samples.filter { $0.hitRatio != nil }) {
                    LineMark(x: .value("Time", $0.date), y: .value("Hit ratio", $0.hitRatio ?? 0)).foregroundStyle(.teal)
                }
                .chartYScale(domain: 0...1)
                .chartYAxis { AxisMarks(format: FloatingPointFormatStyle<Double>.Percent()) }
            }
        }
    }

    @ViewBuilder
    private func keyspace(_ latest: InfoSnapshot) -> some View {
        if !latest.keyspace.isEmpty {
            GroupBox("Keyspace") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow {
                        Text("Database").bold()
                        Text("Keys").bold()
                        Text("Expiring").bold()
                    }
                    ForEach(latest.keyspace) { db in
                        GridRow {
                            Text("db\(db.database)").monospaced()
                            Text(db.keys.formatted()).monospacedDigit()
                            Text(db.expires.formatted()).monospacedDigit()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }
}

struct MetricCard: View {
    let title: LocalizedStringKey
    let value: String
    var detail: String?
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(detail ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct ChartCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content.frame(height: 160)
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }
}
