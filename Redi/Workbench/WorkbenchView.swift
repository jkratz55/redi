import RediCore
import RedisClient
import SwiftUI

struct WorkbenchView: View {
    @Bindable var model: WorkbenchModel
    let workspace: WorkspaceModel
    @State private var caretPrefix = ""
    @State private var selectedText = ""

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                toolbar
                Divider()
                CommandEditor(text: $model.text, catalog: model.catalog) { prefix, selection in
                    caretPrefix = prefix
                    selectedText = selection
                }
                .frame(minHeight: 120)
                Divider()
                hintBar
            }
            .frame(minHeight: 180, idealHeight: 260)
            results
                .frame(minHeight: 160, maxHeight: .infinity)
        }
        .alert(model.confirmation?.title ?? "", isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }),
               presenting: model.confirmation) { confirmation in
            Button("Run", role: .destructive) { model.run(confirmation.line, confirmed: true) }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                model.run(selectedText.isEmpty ? model.text : selectedText)
            } label: {
                Label(selectedText.isEmpty ? "Run All" : "Run Selection", systemImage: "play.fill")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isRunning)
            .accessibilityIdentifier("workbench.run")

            Button {
                model.run(currentLine)
            } label: {
                Label("Run Line", systemImage: "arrow.right.to.line")
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(model.isRunning)

            if model.isRunning {
                ProgressView().controlSize(.small)
                Button("Stop") { model.cancel() }
            }
            Spacer()
            Toggle("Pipeline", isOn: $model.usesPipeline)
                .toggleStyle(.checkbox)
                .help("Send all commands in one round trip")
            if workspace.isCluster {
                Picker("Target", selection: $model.target) {
                    Text("Route by Key").tag(RedisSession.Target.automatic)
                    Text("All Primaries").tag(RedisSession.Target.allPrimaries)
                    ForEach(workspace.clusterNodes.filter { $0.role == .primary }) { node in
                        Text(node.endpoint.description).tag(RedisSession.Target.node(node.endpoint))
                    }
                }
                .fixedSize()
            }
        }
        .padding(8)
    }

    /// The full line under the caret (the editor reports only the part before the caret).
    private var currentLine: String {
        guard let line = model.text.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix(caretPrefix) && !caretPrefix.isEmpty }) else { return caretPrefix }
        return String(line)
    }

    private var hintBar: some View {
        HStack {
            if let doc = model.catalog.doc(for: caretPrefix.split(separator: " ").map(String.init).filter { Int($0) == nil }) {
                Text(doc.synopsis).font(.caption.monospaced()).lineLimit(1).truncationMode(.tail)
                Text("— \(doc.summary)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Esc or Tab completes commands · // starts a comment").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Results").font(.headline)
                Spacer()
                Button("Clear Results", systemImage: "trash") { model.clearResults() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(model.results.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if model.results.isEmpty {
                ContentUnavailableView("No Results", systemImage: "play.rectangle",
                                       description: Text("Write commands above and press ⌘↩."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.results) { result in
                            ResultCard(result: result,
                                       onToggle: { model.toggle(result.id) },
                                       onRemove: { model.remove(result.id) },
                                       onRerun: { model.run(result.commands.joined(separator: "\n")) })
                        }
                    }
                    .padding(10)
                }
            }
        }
    }
}

private struct ResultCard: View {
    enum Mode: String, CaseIterable, Identifiable {
        case raw, table, json
        var id: Self { self }
    }

    let result: WorkbenchModel.Result
    let onToggle: () -> Void
    let onRemove: () -> Void
    let onRerun: () -> Void
    @State private var mode: Mode = .raw

    private var availableModes: [Mode] {
        var modes: [Mode] = [.raw]
        if result.table != nil { modes.append(.table) }
        if result.json != nil { modes.append(.json) }
        return modes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onToggle) {
                    Image(systemName: result.isCollapsed ? "chevron.right" : "chevron.down")
                        .frame(width: 12)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(result.isCollapsed ? "Expand" : "Collapse")
                Image(systemName: result.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(result.isError ? .red : .green)
                Text(result.commands.joined(separator: " ⏎ "))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if availableModes.count > 1 {
                    Picker("View", selection: $mode) {
                        ForEach(availableModes) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
                if let node = result.node { Text(node).font(.caption).foregroundStyle(.secondary) }
                Text(String(format: "%.2f ms", result.durationMilliseconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(result.date, format: .dateTime.hour().minute().second()).font(.caption).foregroundStyle(.tertiary)
                Menu {
                    Button("Run Again", action: onRerun)
                    Button("Copy Result") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.text, forType: .string)
                    }
                    Divider()
                    Button("Remove", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(8)
            if !result.isCollapsed {
                Divider()
                content
                    .padding(8)
            }
        }
        .background(.background, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .raw:
            Text(result.text)
                .font(.body.monospaced())
                .foregroundStyle(result.isError ? .red : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(400)
        case .json:
            Text(result.json ?? "")
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .table:
            if let table = result.table {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            ForEach(table.columns.indices, id: \.self) { Text(table.columns[$0]).font(.caption.bold()).foregroundStyle(.secondary) }
                        }
                        Divider()
                        ForEach(table.rows.prefix(500).indices, id: \.self) { row in
                            GridRow {
                                ForEach(table.rows[row].indices, id: \.self) { column in
                                    Text(table.rows[row][column]).font(.callout.monospaced()).lineLimit(2).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
