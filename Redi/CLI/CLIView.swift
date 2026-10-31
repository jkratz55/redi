import AppKit
import RediCore
import RedisClient
import SwiftUI

struct CLIView: View {
    @Bindable var model: CLIModel
    let workspace: WorkspaceModel
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ConsoleTextView(entries: model.entries)
            Divider()
            inputBar
        }
        .onAppear {
            isInputFocused = true
            if let command = workspace.pendingCLICommand {
                model.insert(command)
                workspace.pendingCLICommand = nil
            }
        }
        .onChange(of: workspace.pendingCLICommand) { _, command in
            guard let command else { return }
            model.insert(command)
            workspace.pendingCLICommand = nil
            isInputFocused = true
        }
        .alert(model.confirmation?.title ?? "", isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }),
               presenting: model.confirmation) { confirmation in
            Button("Run", role: confirmation.isDestructive ? .destructive : nil) {
                model.run(confirmation.line, confirmed: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            if workspace.isCluster {
                Menu {
                    Picker("Target", selection: $model.target) {
                        Text("Route by Key").tag(RedisSession.Target.automatic)
                        Text("All Primaries").tag(RedisSession.Target.allPrimaries)
                        Divider()
                        ForEach(workspace.clusterNodes.filter { $0.role == .primary }) { node in
                            Text(node.endpoint.description).tag(RedisSession.Target.node(node.endpoint))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Where keyless commands run")
            }
            Text(model.prompt)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                if let hint = model.hint {
                    Text("\(Text(model.input).foregroundStyle(.clear))\(Text(hint).foregroundStyle(.tertiary))")
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: $model.input, prompt: Text("Enter a command, e.g. GET key"))
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    .focused($isInputFocused)
                    .autocorrectionDisabled()
                    .onSubmit { model.submit() }
                    .onKeyPress(.upArrow) { model.historyUp(); return .handled }
                    .onKeyPress(.downArrow) { model.historyDown(); return .handled }
                    .onKeyPress(.tab) { model.complete(); return .handled }
                    .accessibilityIdentifier("cli.input")
            }
            if model.isRunning {
                ProgressView().controlSize(.small)
                Button("Stop") { model.cancel() }.controlSize(.small)
            }
            Button("Clear", systemImage: "trash") { model.clear() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Clear Console")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

/// Append-only console output in an `NSTextView`. New entries are appended to the text storage
/// without re-rendering earlier ones.
struct ConsoleTextView: NSViewRepresentable {
    let entries: [CLIModel.Entry]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.backgroundColor = .textBackgroundColor
        textView.setAccessibilityLabel(String(localized: "Console output"))
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.render(entries)
    }

    final class Coordinator {
        weak var textView: NSTextView?
        private var rendered: [UUID] = []
        private let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        private let promptFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        func render(_ entries: [CLIModel.Entry]) {
            guard let textView, let storage = textView.textStorage else { return }
            let ids = entries.map(\.id)
            if ids.starts(with: rendered) {
                let fresh = entries.dropFirst(rendered.count)
                guard !fresh.isEmpty else { return }
                let wasAtBottom = isScrolledToBottom(textView)
                storage.beginEditing()
                for entry in fresh { storage.append(attributed(entry)) }
                storage.endEditing()
                rendered = ids
                if wasAtBottom { textView.scrollToEndOfDocument(nil) }
            } else {
                // Cleared or trimmed: rebuild.
                let text = NSMutableAttributedString()
                for entry in entries { text.append(attributed(entry)) }
                storage.setAttributedString(text)
                rendered = ids
                textView.scrollToEndOfDocument(nil)
            }
        }

        private func isScrolledToBottom(_ textView: NSTextView) -> Bool {
            guard let scroll = textView.enclosingScrollView else { return true }
            return scroll.contentView.bounds.maxY >= textView.bounds.maxY - 40
        }

        private func attributed(_ entry: CLIModel.Entry) -> NSAttributedString {
            let text = NSMutableAttributedString()
            text.append(NSAttributedString(string: entry.prompt + " ", attributes: [.font: promptFont, .foregroundColor: NSColor.secondaryLabelColor]))
            text.append(NSAttributedString(string: entry.command, attributes: [.font: promptFont, .foregroundColor: NSColor.labelColor]))
            if let duration = entry.duration {
                let ms = Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
                text.append(NSAttributedString(string: String(format: "   %.2f ms", ms),
                                               attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                                                            .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            text.append(NSAttributedString(string: "\n"))
            let color: NSColor = switch entry.kind {
            case .output: .labelColor
            case .error: .systemRed
            case .info: .secondaryLabelColor
            }
            text.append(NSAttributedString(string: entry.output + "\n\n", attributes: [.font: font, .foregroundColor: color]))
            return text
        }
    }
}

// MARK: - Command Helper

struct CommandHelperView: View {
    let workspace: WorkspaceModel
    @State private var search = ""
    @State private var selection: String?

    private var docs: [CommandDoc] {
        let all = workspace.commandCatalog.docs.values
        let query = search.trimmingCharacters(in: .whitespaces).uppercased()
        let filtered = query.isEmpty ? Array(all) : all.filter { $0.name.contains(query) || $0.summary.localizedCaseInsensitiveContains(query) }
        return filtered.sorted { ($0.groupTitle, $0.name) < ($1.groupTitle, $1.name) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Search commands", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List(selection: $selection) {
                    let grouped = Dictionary(grouping: docs, by: \.groupTitle)
                    ForEach(grouped.keys.sorted(), id: \.self) { group in
                        Section(group) {
                            ForEach(grouped[group] ?? []) { doc in
                                Text(doc.name).font(.callout.monospaced()).tag(doc.name)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 340)

            Group {
                if let name = selection, let doc = workspace.commandCatalog.docs[name] {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(doc.name).font(.title2.monospaced().bold())
                                Spacer()
                                Button("Use in CLI") {
                                    workspace.pendingCLICommand = doc.name + " "
                                    workspace.bottomPanelTab = .cli
                                }
                            }
                            Text(doc.summary)
                            Text(doc.synopsis)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                                if let since = doc.since { GridRow { Text("Since").foregroundStyle(.secondary); Text(since) } }
                                GridRow { Text("Group").foregroundStyle(.secondary); Text(doc.groupTitle) }
                                if let complexity = doc.complexity {
                                    GridRow { Text("Complexity").foregroundStyle(.secondary); Text(complexity) }
                                }
                                if let deprecated = doc.deprecatedSince {
                                    GridRow {
                                        Text("Deprecated").foregroundStyle(.secondary)
                                        Text("Since \(deprecated)" + (doc.replacedBy.map { "; use \($0)" } ?? "")).foregroundStyle(.orange)
                                    }
                                }
                            }
                            .font(.callout)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ContentUnavailableView("Select a Command", systemImage: "book",
                                           description: Text("\(workspace.commandCatalog.docs.count) commands available on this server."))
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
