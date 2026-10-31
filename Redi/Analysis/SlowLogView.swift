import Foundation
import Observation
import RediCore
import RedisClient
import RedisWire
import SwiftUI

@Observable
final class SlowLogModel {
    private(set) var entries: [SlowLogEntry] = []
    private(set) var threshold: Int64?
    private(set) var maxLength: Int64?
    private(set) var isLoading = false
    var error: String?
    var count = 128

    @ObservationIgnored private unowned let workspace: WorkspaceModel

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
    }

    func load() async {
        guard let session = workspace.session else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let replies = try await session.fanOut(RedisCommand("SLOWLOG", "GET", count))
            let isCluster = replies.count > 1
            entries = replies.flatMap { SlowLogEntry.parse($0.reply, node: isCluster ? $0.node.description : nil) }
                .sorted { $0.date > $1.date }
            if let config = try? await session.send(RedisCommand("CONFIG", "GET", "slowlog-*")), let pairs = config.pairs {
                for pair in pairs {
                    switch pair.key.string {
                    case "slowlog-log-slower-than": threshold = pair.value.int
                    case "slowlog-max-len": maxLength = pair.value.int
                    default: break
                    }
                }
            }
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    func configure(threshold: Int64, maxLength: Int64) async {
        guard let session = workspace.session else { return }
        do {
            for reply in try await session.fanOut(RedisCommand("CONFIG", "SET", "slowlog-log-slower-than", threshold, "slowlog-max-len", maxLength)) {
                try reply.reply.throwIfError()
            }
            await load()
        } catch {
            self.error = String(describing: error)
        }
    }

    func reset() async {
        guard let session = workspace.session else { return }
        do {
            for reply in try await session.fanOut(RedisCommand("SLOWLOG", "RESET")) { try reply.reply.throwIfError() }
            await load()
        } catch {
            self.error = String(describing: error)
        }
    }
}

struct SlowLogView: View {
    @Bindable var model: SlowLogModel
    let isReadOnly: Bool
    @State private var isConfiguring = false
    @State private var thresholdText = ""
    @State private var maxLengthText = ""
    @State private var isConfirmingReset = false
    @State private var sortOrder = [KeyPathComparator(\SlowLogEntry.date, order: .reverse)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let threshold = model.threshold {
                    Label(threshold < 0 ? String(localized: "Logging disabled") : String(localized: "Logs commands slower than \((Double(threshold) / 1000).formatted()) ms"),
                          systemImage: "tortoise")
                        .foregroundStyle(.secondary)
                }
                if let maxLength = model.maxLength {
                    Text("· keeps \(maxLength.formatted())").foregroundStyle(.secondary)
                }
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Button("Configure…") {
                    thresholdText = model.threshold.map(String.init) ?? "10000"
                    maxLengthText = model.maxLength.map(String.init) ?? "128"
                    isConfiguring = true
                }
                .disabled(isReadOnly || model.threshold == nil)
                .popover(isPresented: $isConfiguring) { configureForm }
                Button("Reset Log…") { isConfirmingReset = true }.disabled(isReadOnly)
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .labelStyle(.iconOnly)
            }
            .padding(10)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout).padding(.horizontal, 10)
            }
            Divider()
            if model.entries.isEmpty && !model.isLoading {
                ContentUnavailableView("No Slow Commands", systemImage: "tortoise",
                                       description: Text("Nothing has exceeded the slow log threshold."))
            } else {
                Table(model.entries.sorted(using: sortOrder), sortOrder: $sortOrder) {
                    TableColumn("Time", value: \.date) { Text($0.date.formatted(date: .abbreviated, time: .standard)) }
                        .width(min: 140, ideal: 170)
                    TableColumn("Duration", value: \.durationMicroseconds) { entry in
                        Text("\((Double(entry.durationMicroseconds) / 1000).formatted(.number.precision(.fractionLength(2)))) ms")
                            .monospacedDigit()
                            .foregroundStyle(entry.durationMicroseconds > 100_000 ? .red : .primary)
                    }
                    .width(90)
                    TableColumn("Command") { Text($0.command).font(.body.monospaced()).lineLimit(1).textSelection(.enabled) }
                    TableColumn("Client") { entry in
                        Text(entry.clientName.isEmpty ? entry.client : "\(entry.clientName) (\(entry.client))").foregroundStyle(.secondary)
                    }
                    .width(min: 120, ideal: 160)
                    TableColumn("Node") { Text($0.node ?? "").foregroundStyle(.secondary) }.width(min: 0, ideal: 110)
                }
            }
        }
        .task { await model.load() }
        .confirmationDialog("Reset the slow log?", isPresented: $isConfirmingReset) {
            Button("Reset", role: .destructive) { Task { await model.reset() } }
        } message: {
            Text("Every slow log entry on the server is discarded.")
        }
    }

    private var configureForm: some View {
        Form {
            TextField("Threshold (µs)", text: $thresholdText)
            TextField("Max entries", text: $maxLengthText)
            HStack {
                Spacer()
                Button("Apply") {
                    isConfiguring = false
                    if let threshold = Int64(thresholdText), let maxLength = Int64(maxLengthText) {
                        Task { await model.configure(threshold: threshold, maxLength: maxLength) }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}
