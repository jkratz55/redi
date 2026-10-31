import RediCore
import SwiftUI

/// The Key Browser: filterable list/tree of keys beside the selected key's details.
struct BrowserView: View {
    @Bindable var model: BrowserModel
    @Environment(\.undoManager) private var undoManager
    @FocusState private var isFilterFocused: Bool
    @State private var pendingDelete: [Int] = []
    @State private var isAddingKey = false
    @State private var isBulkDeleting = false

    var body: some View {
        HSplitView {
            keyPane
                .frame(minWidth: 300, idealWidth: 420, maxWidth: 800, maxHeight: .infinity)
            detailPane
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if model.index.count == 0, !model.isScanning { model.reload() }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            Button("Delete", role: .destructive) {
                let rows = pendingDelete
                pendingDelete = []
                Task { await model.delete(rows: rows, undoManager: undoManager) }
            }
        } message: {
            Text(model.canUndoDelete(rows: pendingDelete) ? "You can undo this with ⌘Z." : "This can't be undone.")
        }
        .sheet(isPresented: $isAddingKey) {
            AddKeySheet(model: model)
        }
        .sheet(isPresented: $isBulkDeleting) {
            BulkDeleteSheet(model: model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusKeyFilter)) { _ in isFilterFocused = true }
    }

    private var deleteTitle: String {
        if pendingDelete.count == 1, let row = pendingDelete.first, row < model.index.count {
            return String(localized: "Delete “\(model.key(at: row).displayText)”?")
        }
        return String(localized: "Delete \(pendingDelete.count) keys?")
    }

    /// Small, undoable deletes skip the confirmation (HIG: prefer undo over alerts).
    private func requestDelete(_ rows: [Int]) {
        if model.canUndoDelete(rows: rows) && rows.count == 1 && !model.workspaceIsProduction {
            Task { await model.delete(rows: rows, undoManager: undoManager) }
        } else {
            pendingDelete = rows
        }
    }

    // MARK: - Key pane

    private var keyPane: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            ZStack {
                Color.clear
                switch model.layout {
                case .list: KeyListView(model: model, onDelete: requestDelete)
                case .tree: KeyTreeView(model: model, onDelete: requestDelete)
                }
                if model.index.count == 0 {
                    emptyState
                }
            }
            Divider()
            footer
        }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by key name or pattern", text: $model.filterText)
                    .textFieldStyle(.plain)
                    .focused($isFilterFocused)
                    .onSubmit { model.applyFilter() }
                    .accessibilityIdentifier("browser.filter")
                if !model.filterText.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") {
                        model.filterText = ""
                        model.applyFilter()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
            .help("Plain text matches keys starting with it (and the exact key). Use * ? [ ] for glob patterns.")

            Menu {
                Picker("Type", selection: $model.typeFilter) {
                    Text("All Types").tag(RedisKeyType?.none)
                    Divider()
                    ForEach(RedisKeyType.filterable, id: \.self) { type in
                        Text(type.displayName).tag(RedisKeyType?.some(type))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                if let type = model.typeFilter {
                    TypeBadge(type: type)
                } else {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Filter by type")

            Picker("Layout", selection: $model.layout) {
                Image(systemName: "list.bullet").tag(BrowserModel.Layout.list).help("List")
                Image(systemName: "list.bullet.indent").tag(BrowserModel.Layout.tree).help("Tree")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Menu {
                Button("Add Key…") { isAddingKey = true }
                    .disabled(model.isReadOnly)
                Button("Refresh") { model.reload() }
                Divider()
                Button("Delete Matching Keys…", role: .destructive) { isBulkDeleting = true }
                    .disabled(model.isReadOnly)
            } label: {
                Image(systemName: "ellipsis.circle")
            } primaryAction: {
                isAddingKey = true
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add Key")
        }
        .padding(8)
    }

    @ViewBuilder private var emptyState: some View {
        if model.isScanning {
            ProgressView("Scanning…").controlSize(.small)
        } else if let error = model.error {
            ContentUnavailableView("Scan Failed", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if !model.isScanComplete {
            EmptyView()
        } else if model.appliedFilter.matchPattern != nil || model.appliedFilter.type != nil {
            ContentUnavailableView.search(text: model.appliedFilter.pattern)
        } else {
            ContentUnavailableView {
                Label("No Keys", systemImage: "key")
            } description: {
                Text("This database is empty.")
            } actions: {
                if !model.isReadOnly { Button("Add Key…") { isAddingKey = true } }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.mini)
                Button("Stop") { model.cancelScan() }
                    .controlSize(.small)
            } else if !model.isScanComplete {
                Button("Scan More") { model.loadMore() }
                    .controlSize(.small)
                Button("Scan All") { model.scanAll() }
                    .controlSize(.small)
                    .help("Scan the whole keyspace (can take a while on large databases)")
            }
            Button("Refresh", systemImage: "arrow.clockwise") { model.reload() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Refresh (⌘R)")
                .keyboardShortcut("r")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    // MARK: - Detail pane

    @ViewBuilder private var detailPane: some View {
        if let detail = model.detail {
            KeyDetailView(model: detail)
                .id(detail.key)
        } else {
            ContentUnavailableView("No Key Selected", systemImage: "key",
                                   description: Text("Select a key to see and edit its value."))
        }
    }
}

extension Notification.Name {
    static let focusKeyFilter = Notification.Name("com.github.jkratz55.Redi.focusKeyFilter")
}

extension BrowserModel {
    var workspaceIsProduction: Bool { isProduction }
}

// MARK: - Add key

struct AddKeySheet: View {
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var type: RedisKeyType = .string
    @State private var name = ""
    @State private var ttl = ""
    @State private var first = ""
    @State private var second = ""
    @State private var error: String?
    @State private var isSaving = false

    private static let types: [RedisKeyType] = [.string, .hash, .list, .set, .zset, .stream, .json]

    var body: some View {
        Form {
            Picker("Type", selection: $type) {
                ForEach(Self.types, id: \.self) { Text($0.displayName).tag($0) }
            }
            TextField("Key Name", text: $name)
            TextField("TTL (seconds)", text: $ttl, prompt: Text("No expiry"))
            switch type {
            case .string:
                LabeledContent("Value") { TextEditor(text: $first).font(.body.monospaced()).frame(height: 120) }
            case .json:
                LabeledContent("JSON") { TextEditor(text: $first).font(.body.monospaced()).frame(height: 120) }
            case .hash:
                TextField("Field", text: $first)
                TextField("Value", text: $second)
            case .list:
                TextField("Element", text: $first)
            case .set:
                TextField("Member", text: $first)
            case .zset:
                TextField("Member", text: $first)
                TextField("Score", text: $second, prompt: Text(verbatim: "0"))
            case .stream:
                TextField("Field", text: $first)
                TextField("Value", text: $second)
            default:
                EmptyView()
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { Task { await save() } }
                    .disabled(name.isEmpty || isSaving)
            }
        }
        .navigationTitle("Add Key")
    }

    private func save() async {
        guard let session = model.session else { return }
        let value: KeyOperations.NewValue
        switch type {
        case .hash: value = .hash(field: Array(first.utf8), value: Array(second.utf8))
        case .list: value = .list(Array(first.utf8))
        case .set: value = .set(Array(first.utf8))
        case .zset:
            guard let score = Double(second.isEmpty ? "0" : second) else { error = String(localized: "Score must be a number."); return }
            value = .sortedSet(member: Array(first.utf8), score: score)
        case .stream: value = .stream(id: "*", fields: [(Array(first.utf8), Array(second.utf8))])
        case .json:
            guard (try? ValueFormatter.parse(first, as: .json)) != nil else { error = String(localized: "The value isn't valid JSON."); return }
            value = .json(first)
        default: value = .string(Array(first.utf8))
        }
        let ttlSeconds = Int64(ttl.trimmingCharacters(in: .whitespaces))
        if !ttl.isEmpty, ttlSeconds == nil { error = String(localized: "TTL must be a whole number of seconds."); return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await KeyOperations(session: session).create(Array(name.utf8), value: value, ttlSeconds: ttlSeconds)
            model.showDetail(forNewKey: Array(name.utf8), type: type)
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}

// MARK: - Bulk delete

struct BulkDeleteSheet: View {
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var pattern: String
    @State private var type: RedisKeyType?
    @State private var deleted = 0
    @State private var state: State = .confirm
    @State private var task: Task<Void, Never>?

    enum State: Equatable { case confirm, running, done, failed(String) }

    init(model: BrowserModel) {
        self.model = model
        _pattern = .init(initialValue: model.appliedFilter.pattern)
        _type = .init(initialValue: model.appliedFilter.type)
    }

    private var filter: ScanFilter { ScanFilter(pattern: pattern, type: type) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Delete Matching Keys", systemImage: "trash").font(.headline)
            Form {
                TextField("Pattern", text: $pattern, prompt: Text(verbatim: "user:*"))
                    .disabled(state != .confirm)
                Picker("Type", selection: $type) {
                    Text("All Types").tag(RedisKeyType?.none)
                    ForEach(RedisKeyType.filterable, id: \.self) { Text($0.displayName).tag(RedisKeyType?.some($0)) }
                }
                .disabled(state != .confirm)
            }
            switch state {
            case .confirm:
                Text(filter.matchPattern == nil && type == nil
                     ? "This deletes every key in the database and can't be undone."
                     : "Every key matching “\(filter.matchPattern ?? "*")” is deleted. This can't be undone.")
                    .foregroundStyle(.secondary)
            case .running:
                ProgressView { Text("Deleted \(deleted.formatted()) keys…") }
            case .done:
                Label("Deleted \(deleted.formatted()) keys.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message):
                Label("Stopped after deleting \(deleted.formatted()) keys: \(message)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                switch state {
                case .confirm:
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Delete", role: .destructive) { start() }.keyboardShortcut(.defaultAction)
                case .running:
                    Button("Stop") { task?.cancel() }
                case .done, .failed:
                    Button("Done") {
                        model.reload()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func start() {
        guard let session = model.session else { return }
        state = .running
        let filter = self.filter
        task = Task {
            do {
                for try await count in KeyOperations(session: session).bulkDelete(filter: filter) { deleted = count }
                state = .done
            } catch is CancellationError {
                state = .done
            } catch {
                state = .failed(String(describing: error))
            }
        }
    }
}
