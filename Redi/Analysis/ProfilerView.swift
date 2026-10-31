import AppKit
import Foundation
import Observation
import RediCore
import SwiftUI
import UniformTypeIdentifiers

/// Profiler: live MONITOR output on a dedicated connection.
@Observable
final class ProfilerModel {
    private(set) var isRunning = false
    private(set) var error: String?
    private(set) var revision = 0
    private(set) var total = 0
    var filter = "" {
        didSet { refreshVisible() }
    }

    @ObservationIgnored private(set) var buffer = RingBuffer<MonitorEntry>(capacity: 50_000)
    @ObservationIgnored private(set) var visible: [Int]?
    @ObservationIgnored private unowned let workspace: WorkspaceModel
    @ObservationIgnored private var listener: MonitorListener?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
    }

    var rowCount: Int { visible?.count ?? buffer.count }
    func entry(at row: Int) -> MonitorEntry { buffer[visible?[row] ?? row] }

    func start() async {
        guard let session = workspace.session else { return }
        let listener = MonitorListener(session: session)
        self.listener = listener
        do {
            try await listener.start()
            isRunning = true
            error = nil
            task = Task { [weak self] in
                for await batch in listener.entries {
                    guard let self else { return }
                    self.total += batch.count
                    self.buffer.append(contentsOf: batch)
                    self.refreshVisible()
                }
            }
        } catch {
            self.error = String(describing: error)
            await listener.stop()
        }
    }

    func stop() async {
        task?.cancel()
        await listener?.stop()
        listener = nil
        isRunning = false
    }

    func clear() {
        buffer.removeAll()
        total = 0
        refreshVisible()
    }

    private func refreshVisible() {
        let query = filter.trimmingCharacters(in: .whitespaces)
        visible = query.isEmpty ? nil : (0..<buffer.count).filter {
            let entry = buffer[$0]
            return entry.command.localizedCaseInsensitiveContains(query) || entry.arguments.localizedCaseInsensitiveContains(query)
                || entry.client.contains(query)
        }
        revision += 1
    }

    func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "redis-monitor.log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let lines = (0..<buffer.count).map { index -> String in
            let entry = buffer[index]
            return String(format: "%.6f", entry.timestamp) + " [\(entry.database) \(entry.client)]" + (entry.node.map { " {\($0)}" } ?? "")
                + " \"\(entry.command)\" \(entry.arguments)"
        }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ProfilerView: View {
    @Bindable var model: ProfilerModel
    let isCluster: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if model.isRunning {
                    Button("Stop", systemImage: "stop.fill") { Task { await model.stop() } }
                } else {
                    Button("Start Profiler", systemImage: "record.circle") { Task { await model.start() } }
                }
                Text("MONITOR reports every command the server runs and can reduce throughput noticeably. Use it briefly.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Spacer()
                Text("\(model.total.formatted()) commands").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                TextField("Filter", text: $model.filter).textFieldStyle(.roundedBorder).frame(width: 140)
                Button("Save Log…", systemImage: "square.and.arrow.down") { model.save() }
                    .labelStyle(.iconOnly)
                    .disabled(model.buffer.isEmpty)
                Button("Clear", systemImage: "trash") { model.clear() }.labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout).padding(.horizontal, 10)
            }
            Divider()
            LogTableView(columns: columns, rowCount: model.rowCount, revision: model.revision, text: { row, column in
                let entry = model.entry(at: row)
                switch column {
                case "time": return entry.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
                case "node": return entry.node ?? ""
                case "db": return String(entry.database)
                case "client": return entry.client
                case "command": return entry.command
                default: return entry.arguments
                }
            }, accessibilityLabel: String(localized: "Monitored commands"))
        }
    }

    private var columns: [LogTableView.Column] {
        var columns: [LogTableView.Column] = [.init(id: "time", title: String(localized: "Time"), width: 100, isMonospaced: false, isSecondary: true)]
        if isCluster { columns.append(.init(id: "node", title: String(localized: "Node"), width: 120, isSecondary: true)) }
        columns += [
            .init(id: "db", title: String(localized: "DB"), width: 30, isSecondary: true),
            .init(id: "client", title: String(localized: "Client"), width: 130, isSecondary: true),
            .init(id: "command", title: String(localized: "Command"), width: 110),
            .init(id: "args", title: String(localized: "Arguments"), width: 400, isFlexible: true),
        ]
        return columns
    }
}
