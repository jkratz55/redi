import Charts
import Foundation
import Observation
import RediCore
import RedisClient
import SwiftUI

@Observable
final class AnalysisModel {
    private(set) var reports: [AnalysisReport] = []
    var selectedID: AnalysisReport.ID?
    private(set) var progress: MemoryAnalyzer.Progress?
    private(set) var error: String?
    var usesSample = true
    var sampleSize = 50_000
    var usesReplica = false
    private(set) var replica: RedisEndpoint?

    @ObservationIgnored private unowned let workspace: WorkspaceModel
    @ObservationIgnored private var task: Task<Void, Never>?

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        reports = Self.loadReports(from: directory)
        selectedID = reports.first?.id
    }

    var isRunning: Bool { progress != nil }
    var selected: AnalysisReport? { reports.first { $0.id == selectedID } }

    private var directory: URL {
        RediDirectories.connectionData(workspace.profile.id).appending(path: "Analysis", directoryHint: .isDirectory)
    }

    func detectReplica() async {
        guard let session = workspace.session, !workspace.isCluster else { return }
        replica = await MemoryAnalyzer.replica(of: session)
    }

    func run() {
        guard let session = workspace.session, !isRunning else { return }
        let analyzer = MemoryAnalyzer(session: session, delimiter: workspace.keyDelimiter,
                                      sampleLimit: usesSample ? sampleSize : nil,
                                      node: usesReplica ? replica : nil)
        let database = workspace.database
        progress = MemoryAnalyzer.Progress(scanned: 0, total: 0)
        error = nil
        task = Task {
            do {
                var report = try await analyzer.run { progress in
                    Task { @MainActor in
                        if self.isRunning { self.progress = progress }
                    }
                }
                report.database = database
                reports.insert(report, at: 0)
                selectedID = report.id
                save(report)
            } catch is CancellationError {
            } catch {
                self.error = String(describing: error)
            }
            progress = nil
        }
    }

    func cancel() {
        task?.cancel()
        progress = nil
    }

    func delete(_ id: AnalysisReport.ID) {
        reports.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: directory.appending(path: "\(id.uuidString).json"))
        if selectedID == id { selectedID = reports.first?.id }
    }

    private func save(_ report: AnalysisReport) {
        let url = directory.appending(path: "\(report.id.uuidString).json")
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(report).write(to: url, options: .atomic)
        }
    }

    private static func loadReports(from directory: URL) -> [AnalysisReport] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? JSONDecoder().decode(AnalysisReport.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }
}

struct DatabaseAnalysisView: View {
    @Bindable var model: AnalysisModel
    let workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let progress = model.progress {
                VStack(spacing: 10) {
                    ProgressView(value: Double(progress.scanned), total: Double(max(progress.total, 1))) {
                        Text("Analyzing \(progress.scanned.formatted()) of \(progress.total.formatted()) keys…")
                    }
                    .frame(maxWidth: 420)
                    Button("Cancel") { model.cancel() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report = model.selected {
                ReportView(report: report)
            } else {
                ContentUnavailableView {
                    Label("Database Analysis", systemImage: "chart.pie")
                } description: {
                    Text("Scan the keyspace to see memory by type and namespace, the biggest keys, TTL distribution and recommendations.")
                } actions: {
                    Button("Analyze") { model.run() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .task { await model.detectReplica() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button("Analyze", systemImage: "play.fill") { model.run() }
                .disabled(model.isRunning)
            Toggle("Sample", isOn: $model.usesSample).toggleStyle(.checkbox)
            if model.usesSample {
                Picker("Sample size", selection: $model.sampleSize) {
                    ForEach([10_000, 50_000, 100_000, 500_000], id: \.self) { Text($0.formatted()).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if let replica = model.replica {
                Toggle("Run on replica \(replica.description)", isOn: $model.usesReplica)
                    .toggleStyle(.checkbox)
                    .help("Scanning a replica keeps the load off the primary")
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            if !model.reports.isEmpty {
                Picker("Report", selection: $model.selectedID) {
                    ForEach(model.reports) { report in
                        Text(report.date.formatted(date: .abbreviated, time: .shortened)).tag(Optional(report.id))
                    }
                }
                .fixedSize()
                Button("Delete Report", systemImage: "trash") {
                    if let id = model.selectedID { model.delete(id) }
                }
                .labelStyle(.iconOnly)
            }
        }
        .padding(10)
    }
}

private struct ReportView: View {
    let report: AnalysisReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary
                if !report.recommendations.isEmpty { recommendations }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 12)], spacing: 12) {
                    ChartCard(title: "Memory by type") {
                        Chart(report.byType, id: \.type) { item in
                            SectorMark(angle: .value("Memory", item.memory), innerRadius: .ratio(0.55), angularInset: 1)
                                .foregroundStyle(by: .value("Type", item.type))
                        }
                    }
                    ChartCard(title: "Top namespaces by memory") {
                        Chart(Array(report.namespaces.prefix(10)), id: \.prefix) { item in
                            BarMark(x: .value("Memory", item.memory), y: .value("Namespace", item.prefix))
                                .foregroundStyle(.purple.gradient)
                        }
                        .chartXAxis {
                            AxisMarks { value in
                                AxisGridLine()
                                AxisValueLabel { if let bytes = value.as(Int64.self) { Text(bytes.byteSize) } }
                            }
                        }
                    }
                    ChartCard(title: "Keys by time to live") {
                        Chart(report.ttlBuckets, id: \.label) { bucket in
                            BarMark(x: .value("TTL", bucket.label), y: .value("Keys", bucket.keys)).foregroundStyle(.teal.gradient)
                        }
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    KeyTable(title: "Biggest keys", keys: report.topByMemory, showsLength: false)
                    KeyTable(title: "Longest collections", keys: report.topByLength, showsLength: true)
                }
                namespaceTable
            }
            .padding(16)
        }
    }

    private var summary: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            MetricCard(title: "Keys analyzed", value: report.scannedKeys.formatted(),
                       detail: report.isSample ? "sample of \(report.totalKeys.formatted())" : "all keys", systemImage: "key")
            MetricCard(title: "Memory", value: report.totalMemory.byteSize, detail: report.isSample ? "in the sample" : nil, systemImage: "memorychip")
            MetricCard(title: "Namespaces", value: report.namespaces.count.formatted(), systemImage: "folder")
            MetricCard(title: "Took", value: Duration.seconds(report.durationSeconds).formatted(.units(allowed: [.minutes, .seconds, .milliseconds], width: .narrow, maximumUnitCount: 2)),
                       detail: report.source, systemImage: "clock")
        }
    }

    private var recommendations: some View {
        GroupBox("Recommendations") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(report.recommendations, id: \.title) { item in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).bold()
                            Text(item.detail).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: item.severity == .warning ? "exclamationmark.triangle.fill" : "lightbulb")
                            .foregroundStyle(item.severity == .warning ? .orange : .yellow)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var namespaceTable: some View {
        GroupBox("Namespaces") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow {
                    Text("Namespace").bold()
                    Text("Keys").bold()
                    Text("Memory").bold()
                    Text("Share").bold()
                }
                ForEach(report.namespaces, id: \.prefix) { item in
                    GridRow {
                        Text(item.prefix).font(.body.monospaced())
                        Text(item.keys.formatted()).monospacedDigit()
                        Text(item.memory.byteSize).monospacedDigit()
                        Text((Double(item.memory) / Double(max(report.totalMemory, 1))).formatted(.percent.precision(.fractionLength(1))))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

private struct KeyTable: View {
    let title: LocalizedStringKey
    let keys: [AnalysisReport.KeyFigure]
    let showsLength: Bool

    var body: some View {
        GroupBox(title) {
            if keys.isEmpty {
                Text("None").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(keys, id: \.key) { key in
                        GridRow {
                            Text(key.key).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Text(key.type).foregroundStyle(.secondary)
                            Text(showsLength ? (key.length.map { $0.formatted() } ?? "—") : key.memory.byteSize)
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }
}
