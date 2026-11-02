import RediCore
import SwiftUI

/// Column widths for the value tables, shared by every key a window shows. Each key gets a new
/// editor, so without this a column the user resized snapped back when another key was selected.
@Observable final class ValueTableColumns {
    var hash = TableColumnCustomization<HashEntry>()
    var list = TableColumnCustomization<ListEntry>()
    var sortedSet = TableColumnCustomization<SortedSetEntry>()
    var streamEntries = TableColumnCustomization<StreamEntry>()
    var streamGroups = TableColumnCustomization<StreamGroup>()
    var streamConsumers = TableColumnCustomization<StreamConsumer>()
    var streamPending = TableColumnCustomization<PendingMessage>()
}

extension EnvironmentValues {
    /// Provided by `BrowserView` for its window.
    @Entry var valueTableColumns = ValueTableColumns()
}

extension TableColumnContent {
    /// Remembers the column's width in `ValueTableColumns`. Moving and hiding columns stay off, as before.
    func remembersWidth(_ id: String) -> some TableColumnContent<TableRowValue, TableColumnSortComparator> {
        customizationID(id).disabledCustomizationBehavior([.reorder, .visibility])
    }
}

// MARK: - String

struct StringValueView: View {
    @Bindable var model: StringValueModel
    let isReadOnly: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FormatPicker(choice: $model.formatChoice, detected: model.detectedFormat)
                if model.isTruncated {
                    Label("Showing the first \(Int64(StringValueModel.previewLimit).byteSize)", systemImage: "scissors")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Load Full Value") { Task { await model.load(full: true) } }
                }
                Spacer()
                if model.isDirty {
                    Button("Revert") { model.revert() }
                    Button("Save") { Task { await model.save() } }
                        .keyboardShortcut("s")
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(8)
            Divider()
            PlainTextView(text: $model.text, isEditable: model.canEdit && !isReadOnly, wrapsLines: model.format != .hex)
        }
    }
}

// MARK: - JSON

struct JSONValueView: View {
    @Bindable var model: JSONValueModel
    let isReadOnly: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("RedisJSON document", systemImage: "curlybraces").foregroundStyle(.secondary)
                Spacer()
                if model.isDirty {
                    Button("Revert") { model.text = model.original }
                    Button("Save") { Task { await model.save() } }
                        .keyboardShortcut("s")
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(8)
            Divider()
            PlainTextView(text: $model.text, isEditable: !isReadOnly)
        }
    }
}

// MARK: - Hash

struct HashValueView: View {
    let model: HashValueModel
    let isReadOnly: Bool
    @State private var selection = Set<HashEntry.ID>()
    @State private var editing: HashEntry?
    @State private var isAdding = false
    @Environment(\.valueTableColumns) private var columnWidths

    var body: some View {
        @Bindable var pager = model.pager
        VStack(spacing: 0) {
            CollectionToolbar(search: $pager.search, supportsSearch: true, formatChoice: $pager.formatChoice, detectedFormat: pager.detectedFormat, onSearch: { Task { await model.reload() } }) {
                Button("Add Field", systemImage: "plus") { isAdding = true }.disabled(isReadOnly)
                Button("Delete", systemImage: "minus") { delete(selection) }.disabled(isReadOnly || selection.isEmpty)
            }
            Table(pager.elements, selection: $selection, columnCustomization: Bindable(columnWidths).hash) {
                TableColumn("Field") { Text($0.field.displayText).font(.body.monospaced()).lineLimit(1) }
                    .remembersWidth("field")
                TableColumn("Value") { Text(ValueFormatter.cellText($0.value, as: pager.format)).font(.body.monospaced()).lineLimit(1) }
                    .remembersWidth("value")
                if model.supportsFieldTTL {
                    TableColumn("TTL") { entry in
                        Text(entry.ttl.map { ($0 * 1000).ttlDescription } ?? "∞").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .width(70)
                    .remembersWidth("ttl")
                }
            }
            .contextMenu(forSelectionType: HashEntry.ID.self) { ids in
                Button("Copy Value") { copy(ids) }
                if !isReadOnly {
                    Button("Edit…") { editing = pager.elements.first { ids.contains($0.id) } }
                    Divider()
                    Button("Delete", role: .destructive) { delete(ids) }
                }
            } primaryAction: { ids in
                if !isReadOnly { editing = pager.elements.first { ids.contains($0.id) } }
            }
            Divider()
            LoadMoreFooter(count: pager.elements.count, hasMore: pager.next != nil, isLoading: pager.isLoading) {
                Task { await pager.loadMore() }
            }
        }
        .sheet(item: $editing) { entry in
            ElementEditorSheet(title: "Edit Field",
                               fields: [.init(label: "Field", value: BinaryText(entry.field), isEditable: false),
                                        .init(label: "Value", value: BinaryText(entry.value, format: model.pager.format), isMultiline: true)],
                               extraLabel: model.supportsFieldTTL ? "Field TTL (seconds)" : nil,
                               extra: entry.ttl.map(String.init) ?? "", extraPrompt: "No expiry") { values, ttl in
                await model.set(field: entry.field, value: values[1], ttl: model.supportsFieldTTL ? (Int64(ttl) ?? 0) : nil)
            }
        }
        .sheet(isPresented: $isAdding) {
            ElementEditorSheet(title: "Add Field",
                               fields: [.init(label: "Field", value: BinaryText()), .init(label: "Value", value: BinaryText(), isMultiline: true)],
                               extraLabel: model.supportsFieldTTL ? "Field TTL (seconds)" : nil, extraPrompt: "No expiry") { values, ttl in
                await model.set(field: values[0], value: values[1], ttl: Int64(ttl))
            }
        }
    }

    private func copy(_ ids: Set<HashEntry.ID>) {
        let format = model.pager.format
        let text = model.pager.elements.filter { ids.contains($0.id) }.map { ValueFormatter.elementText($0.value, as: format) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func delete(_ ids: Set<HashEntry.ID>) {
        let fields = Array(ids)
        selection.subtract(ids)
        Task { await model.delete(fields: fields) }
    }
}

// MARK: - List

struct ListValueView: View {
    let model: ListValueModel
    let isReadOnly: Bool
    @State private var selection = Set<ListEntry.ID>()
    @Environment(\.valueTableColumns) private var columnWidths
    @State private var editing: ListEntry?
    @State private var addingAtHead: Bool?

    var body: some View {
        @Bindable var pager = model.pager
        VStack(spacing: 0) {
            CollectionToolbar(search: .constant(""), supportsSearch: false, formatChoice: $pager.formatChoice, detectedFormat: pager.detectedFormat, onSearch: {}) {
                Menu {
                    Button("Insert at Head (LPUSH)") { addingAtHead = true }
                    Button("Append to Tail (RPUSH)") { addingAtHead = false }
                } label: {
                    Label("Add Element", systemImage: "plus")
                }
                .fixedSize()
                .disabled(isReadOnly)
                Button("Remove", systemImage: "minus") { remove() }.disabled(isReadOnly || selection.count != 1)
            }
            Table(pager.elements, selection: $selection, columnCustomization: Bindable(columnWidths).list) {
                TableColumn("Index") { Text($0.index, format: .number).foregroundStyle(.secondary).monospacedDigit() }
                    .width(70)
                    .remembersWidth("index")
                TableColumn("Element") { Text(ValueFormatter.cellText($0.value, as: pager.format)).font(.body.monospaced()).lineLimit(1) }
                    .remembersWidth("element")
            }
            .contextMenu(forSelectionType: ListEntry.ID.self) { ids in
                if !isReadOnly, ids.count == 1 {
                    Button("Edit…") { editing = pager.elements.first { ids.contains($0.id) } }
                    Button("Remove", role: .destructive) { selection = ids; remove() }
                }
            } primaryAction: { ids in
                if !isReadOnly { editing = pager.elements.first { ids.contains($0.id) } }
            }
            Divider()
            LoadMoreFooter(count: pager.elements.count, hasMore: pager.next != nil, isLoading: pager.isLoading) {
                Task { await pager.loadMore() }
            }
        }
        .sheet(item: $editing) { entry in
            ElementEditorSheet(title: "Edit Element \(entry.index)",
                               fields: [.init(label: "Element", value: BinaryText(entry.value, format: model.pager.format), isMultiline: true)]) { values, _ in
                await model.set(index: entry.index, value: values[0])
            }
        }
        .sheet(isPresented: Binding(get: { addingAtHead != nil }, set: { if !$0 { addingAtHead = nil } })) {
            let atHead = addingAtHead ?? false
            ElementEditorSheet(title: atHead ? "Insert at Head" : "Append to Tail",
                               fields: [.init(label: "Element", value: BinaryText(), isMultiline: true)]) { values, _ in
                await model.push(values[0], atHead: atHead)
            }
        }
    }

    private func remove() {
        guard let index = selection.first else { return }
        selection = []
        Task { await model.remove(index: index) }
    }
}

// MARK: - Set

struct SetValueView: View {
    let model: SetValueModel
    let isReadOnly: Bool
    @State private var selection = Set<SetMember.ID>()
    @State private var isAdding = false

    var body: some View {
        @Bindable var pager = model.pager
        VStack(spacing: 0) {
            CollectionToolbar(search: $pager.search, supportsSearch: true, formatChoice: $pager.formatChoice, detectedFormat: pager.detectedFormat, onSearch: { Task { await model.reload() } }) {
                Button("Add Member", systemImage: "plus") { isAdding = true }.disabled(isReadOnly)
                Button("Remove", systemImage: "minus") { remove(selection) }.disabled(isReadOnly || selection.isEmpty)
            }
            Table(pager.elements, selection: $selection) {
                TableColumn("Member") { Text(ValueFormatter.cellText($0.value, as: pager.format)).font(.body.monospaced()).lineLimit(1) }
            }
            .contextMenu(forSelectionType: SetMember.ID.self) { ids in
                Button("Copy") {
                    let format = pager.format
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ids.map { ValueFormatter.elementText($0, as: format) }.joined(separator: "\n"), forType: .string)
                }
                if !isReadOnly { Button("Remove", role: .destructive) { remove(ids) } }
            }
            Divider()
            LoadMoreFooter(count: pager.elements.count, hasMore: pager.next != nil, isLoading: pager.isLoading) {
                Task { await pager.loadMore() }
            }
        }
        .sheet(isPresented: $isAdding) {
            ElementEditorSheet(title: "Add Member", fields: [.init(label: "Member", value: BinaryText())]) { values, _ in
                await model.add(values[0])
            }
        }
    }

    private func remove(_ ids: Set<SetMember.ID>) {
        selection.subtract(ids)
        let members = Array(ids)
        Task { await model.remove(members) }
    }
}

// MARK: - Sorted set

struct SortedSetValueView: View {
    @Bindable var model: SortedSetValueModel
    let isReadOnly: Bool
    @State private var selection = Set<SortedSetEntry.ID>()
    @Environment(\.valueTableColumns) private var columnWidths
    @State private var editing: SortedSetEntry?
    @State private var isAdding = false

    var body: some View {
        @Bindable var pager = model.pager
        VStack(spacing: 0) {
            CollectionToolbar(search: $pager.search, supportsSearch: true, formatChoice: $pager.formatChoice, detectedFormat: pager.detectedFormat, onSearch: { Task { await model.reload() } }) {
                Picker("Order", selection: $model.descending) {
                    Text("Lowest First").tag(false)
                    Text("Highest First").tag(true)
                }
                .fixedSize()
                .disabled(pager.searchPattern != nil)
                Button("Add Member", systemImage: "plus") { isAdding = true }.disabled(isReadOnly)
                Button("Remove", systemImage: "minus") { remove(selection) }.disabled(isReadOnly || selection.isEmpty)
            }
            Table(pager.elements, selection: $selection, columnCustomization: Bindable(columnWidths).sortedSet) {
                TableColumn("Score") { Text($0.score, format: .number).monospacedDigit() }.width(110)
                    .remembersWidth("score")
                TableColumn("Member") { Text(ValueFormatter.cellText($0.member, as: pager.format)).font(.body.monospaced()).lineLimit(1) }
                    .remembersWidth("member")
            }
            .contextMenu(forSelectionType: SortedSetEntry.ID.self) { ids in
                if !isReadOnly {
                    Button("Edit Score…") { editing = pager.elements.first { ids.contains($0.id) } }
                    Button("Remove", role: .destructive) { remove(ids) }
                }
            } primaryAction: { ids in
                if !isReadOnly { editing = pager.elements.first { ids.contains($0.id) } }
            }
            Divider()
            LoadMoreFooter(count: pager.elements.count, hasMore: pager.next != nil, isLoading: pager.isLoading) {
                Task { await pager.loadMore() }
            }
        }
        .sheet(item: $editing) { entry in
            ElementEditorSheet(title: "Edit Score", fields: [.init(label: "Member", value: BinaryText(entry.member, format: model.pager.format, style: .compact), isEditable: false)],
                               extraLabel: "Score", extra: String(entry.score)) { _, score in
                if let value = Double(score) { await model.add(member: entry.member, score: value) }
            }
        }
        .sheet(isPresented: $isAdding) {
            ElementEditorSheet(title: "Add Member", fields: [.init(label: "Member", value: BinaryText())],
                               extraLabel: "Score", extra: "0") { values, score in
                await model.add(member: values[0], score: Double(score) ?? 0)
            }
        }
    }

    private func remove(_ ids: Set<SortedSetEntry.ID>) {
        selection.subtract(ids)
        let members = Array(ids)
        Task { await model.remove(members) }
    }
}

// MARK: - Stream

struct StreamValueView: View {
    let model: StreamValueModel
    let isReadOnly: Bool
    @State private var tab = 0
    @State private var selection = Set<StreamEntry.ID>()
    @State private var pendingSelection = Set<PendingMessage.ID>()
    @State private var isAdding = false
    @State private var isCreatingGroup = false
    @Environment(\.valueTableColumns) private var columnWidths

    var body: some View {
        @Bindable var pager = model.pager
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $tab) {
                    Text("Entries").tag(0)
                    Text("Consumer Groups").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if tab == 0 { FormatPicker(choice: $pager.formatChoice, detected: pager.detectedFormat) }
                Spacer()
                if tab == 0 {
                    Button("Add Entry", systemImage: "plus") { isAdding = true }.disabled(isReadOnly)
                    Button("Delete", systemImage: "minus") {
                        let ids = Array(selection)
                        selection = []
                        Task { await model.delete(ids: ids) }
                    }
                    .disabled(isReadOnly || selection.isEmpty)
                } else {
                    Button("New Group", systemImage: "plus") { isCreatingGroup = true }.disabled(isReadOnly)
                }
            }
            .labelStyle(.iconOnly)
            .padding(8)
            Divider()
            if tab == 0 { entries } else { groups }
        }
        .sheet(isPresented: $isAdding) {
            ElementEditorSheet(title: "Add Entry", fields: [.init(label: "Field", value: BinaryText()), .init(label: "Value", value: BinaryText())],
                               extraLabel: "Entry ID", extra: "*") { values, id in
                await model.add(id: id, fields: [(values[0], values[1])])
            }
        }
        .sheet(isPresented: $isCreatingGroup) {
            ElementEditorSheet(title: "New Consumer Group", fields: [.init(label: "Group Name", value: BinaryText())],
                               extraLabel: "Start ID", extra: "$", extraPrompt: "$ (new entries only) or 0 (all)") { values, start in
                await model.createGroup(name: String(decoding: values[0], as: UTF8.self), startID: start)
            }
        }
    }

    private var entries: some View {
        let pager = model.pager
        let columns = Array(model.fieldNames.prefix(12))
        return VStack(spacing: 0) {
            Table(pager.elements, selection: $selection, columnCustomization: Bindable(columnWidths).streamEntries) {
                TableColumn("ID") { Text($0.id).font(.body.monospaced()) }.width(min: 150, ideal: 170)
                    .remembersWidth("id")
                TableColumn("Time") { entry in
                    Text(entry.date.map { $0.formatted(date: .numeric, time: .standard) } ?? "").foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 150)
                .remembersWidth("time")
                TableColumnForEach(columns, id: \.self) { name in
                    TableColumn(name) { entry in
                        Text(entry.fields.first { $0.name.displayText == name }.map { ValueFormatter.cellText($0.value, as: pager.format) } ?? "")
                            .font(.body.monospaced()).lineLimit(1)
                    }
                    .remembersWidth("field:" + name)
                }
            }
            Divider()
            LoadMoreFooter(count: pager.elements.count, hasMore: pager.next != nil, isLoading: pager.isLoading) {
                Task { await pager.loadMore() }
            }
        }
    }

    private var groups: some View {
        VStack(spacing: 0) {
            Table(model.groups, selection: Binding(get: { model.selectedGroup.map { Set([$0]) } ?? [] },
                                                   set: { model.selectedGroup = $0.first }),
                  columnCustomization: Bindable(columnWidths).streamGroups) {
                TableColumn("Group") { Text($0.name).font(.body.monospaced()) }.remembersWidth("group")
                TableColumn("Consumers") { Text($0.consumers, format: .number) }.width(80).remembersWidth("consumers")
                TableColumn("Pending") { Text($0.pending, format: .number) }.width(70).remembersWidth("pending")
                TableColumn("Last Delivered") { Text($0.lastDeliveredID).font(.body.monospaced()) }.remembersWidth("lastDelivered")
                TableColumn("Lag") { Text($0.lag.map { $0.formatted() } ?? "—") }.width(60).remembersWidth("lag")
            }
            .contextMenu(forSelectionType: String.self) { names in
                if !isReadOnly, let name = names.first {
                    Button("Delete Group “\(name)”", role: .destructive) { Task { await model.deleteGroup(name) } }
                }
            }
            .frame(minHeight: 110)
            Divider()
            HSplitView {
                Table(model.consumers, columnCustomization: Bindable(columnWidths).streamConsumers) {
                    TableColumn("Consumer") { Text($0.name) }.remembersWidth("consumer")
                    TableColumn("Pending") { Text($0.pending, format: .number) }.width(70).remembersWidth("pending")
                    TableColumn("Idle") { Text($0.idleMilliseconds.ttlDescription).foregroundStyle(.secondary) }.width(70).remembersWidth("idle")
                }
                .frame(minWidth: 200)
                VStack(spacing: 0) {
                    Table(model.pending, selection: $pendingSelection, columnCustomization: Bindable(columnWidths).streamPending) {
                        TableColumn("Pending ID") { Text($0.id).font(.body.monospaced()) }.remembersWidth("id")
                        TableColumn("Consumer") { Text($0.consumer) }.remembersWidth("consumer")
                        TableColumn("Idle") { Text($0.idleMilliseconds.ttlDescription).foregroundStyle(.secondary) }.width(70).remembersWidth("idle")
                        TableColumn("Deliveries") { Text($0.deliveryCount, format: .number) }.width(70).remembersWidth("deliveries")
                    }
                    HStack {
                        Spacer()
                        Button("Acknowledge") {
                            let ids = Array(pendingSelection)
                            pendingSelection = []
                            Task { await model.acknowledge(ids) }
                        }
                        .disabled(isReadOnly || pendingSelection.isEmpty)
                        .controlSize(.small)
                    }
                    .padding(6)
                }
                .frame(minWidth: 260)
            }
        }
        .task { await model.loadGroups() }
    }
}
