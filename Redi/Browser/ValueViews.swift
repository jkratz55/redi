import RediCore
import SwiftUI

// MARK: - String

struct StringValueView: View {
    @Bindable var model: StringValueModel
    let isReadOnly: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Format", selection: $model.format) {
                    ForEach(ValueFormat.allCases) { Text($0.displayName).tag($0) }
                }
                .fixedSize()
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

    var body: some View {
        @Bindable var pager = model.pager
        VStack(spacing: 0) {
            CollectionToolbar(search: $pager.search, supportsSearch: true, onSearch: { Task { await model.reload() } }) {
                Button("Add Field", systemImage: "plus") { isAdding = true }.disabled(isReadOnly)
                Button("Delete", systemImage: "minus") { delete(selection) }.disabled(isReadOnly || selection.isEmpty)
            }
            Table(pager.elements, selection: $selection) {
                TableColumn("Field") { Text($0.field.displayText).font(.body.monospaced()).lineLimit(1) }
                TableColumn("Value") { Text($0.value.displayText).font(.body.monospaced()).lineLimit(1) }
                if model.supportsFieldTTL {
                    TableColumn("TTL") { entry in
                        Text(entry.ttl.map { ($0 * 1000).ttlDescription } ?? "∞").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .width(70)
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
                                        .init(label: "Value", value: BinaryText(entry.value), isMultiline: true)],
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
        let text = model.pager.elements.filter { ids.contains($0.id) }.map { String(decoding: $0.value, as: UTF8.self) }.joined(separator: "\n")
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
    @State private var editing: ListEntry?
    @State private var addingAtHead: Bool?

    var body: some View {
        let pager = model.pager
        VStack(spacing: 0) {
            CollectionToolbar(search: .constant(""), supportsSearch: false, onSearch: {}) {
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
            Table(pager.elements, selection: $selection) {
                TableColumn("Index") { Text($0.index, format: .number).foregroundStyle(.secondary).monospacedDigit() }
                    .width(70)
                TableColumn("Element") { Text($0.value.displayText).font(.body.monospaced()).lineLimit(1) }
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
                               fields: [.init(label: "Element", value: BinaryText(entry.value), isMultiline: true)]) { values, _ in
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
            CollectionToolbar(search: $pager.search, supportsSearch: true, onSearch: { Task { await model.reload() } }) {
                Button("Add Member", systemImage: "plus") { isAdding = true }.disabled(isReadOnly)
                Button("Remove", systemImage: "minus") { remove(selection) }.disabled(isReadOnly || selection.isEmpty)
            }
            Table(pager.elements, selection: $selection) {
                TableColumn("Member") { Text($0.value.displayText).font(.body.monospaced()).lineLimit(1) }
            }
            .contextMenu(forSelectionType: SetMember.ID.self) { ids in
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ids.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n"), forType: .string)
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
    @State private var editing: SortedSetEntry?
    @State private var isAdding = false

    var body: some View {
        @Bindable var pager = model.pager
        VStack(spacing: 0) {
            CollectionToolbar(search: $pager.search, supportsSearch: true, onSearch: { Task { await model.reload() } }) {
                Picker("Order", selection: $model.descending) {
                    Text("Lowest First").tag(false)
                    Text("Highest First").tag(true)
                }
                .fixedSize()
                .disabled(pager.searchPattern != nil)
                Button("Add Member", systemImage: "plus") { isAdding = true }.disabled(isReadOnly)
                Button("Remove", systemImage: "minus") { remove(selection) }.disabled(isReadOnly || selection.isEmpty)
            }
            Table(pager.elements, selection: $selection) {
                TableColumn("Score") { Text($0.score, format: .number).monospacedDigit() }.width(110)
                TableColumn("Member") { Text($0.member.displayText).font(.body.monospaced()).lineLimit(1) }
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
            ElementEditorSheet(title: "Edit Score", fields: [.init(label: "Member", value: BinaryText(entry.member), isEditable: false)],
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $tab) {
                    Text("Entries").tag(0)
                    Text("Consumer Groups").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
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
            Table(pager.elements, selection: $selection) {
                TableColumn("ID") { Text($0.id).font(.body.monospaced()) }.width(min: 150, ideal: 170)
                TableColumn("Time") { entry in
                    Text(entry.date.map { $0.formatted(date: .numeric, time: .standard) } ?? "").foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 150)
                TableColumnForEach(columns, id: \.self) { name in
                    TableColumn(name) { entry in
                        Text(entry.fields.first { $0.name.displayText == name }?.value.displayText ?? "")
                            .font(.body.monospaced()).lineLimit(1)
                    }
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
                                                   set: { model.selectedGroup = $0.first })) {
                TableColumn("Group") { Text($0.name).font(.body.monospaced()) }
                TableColumn("Consumers") { Text($0.consumers, format: .number) }.width(80)
                TableColumn("Pending") { Text($0.pending, format: .number) }.width(70)
                TableColumn("Last Delivered") { Text($0.lastDeliveredID).font(.body.monospaced()) }
                TableColumn("Lag") { Text($0.lag.map { $0.formatted() } ?? "—") }.width(60)
            }
            .contextMenu(forSelectionType: String.self) { names in
                if !isReadOnly, let name = names.first {
                    Button("Delete Group “\(name)”", role: .destructive) { Task { await model.deleteGroup(name) } }
                }
            }
            .frame(minHeight: 110)
            Divider()
            HSplitView {
                Table(model.consumers) {
                    TableColumn("Consumer") { Text($0.name) }
                    TableColumn("Pending") { Text($0.pending, format: .number) }.width(70)
                    TableColumn("Idle") { Text($0.idleMilliseconds.ttlDescription).foregroundStyle(.secondary) }.width(70)
                }
                .frame(minWidth: 200)
                VStack(spacing: 0) {
                    Table(model.pending, selection: $pendingSelection) {
                        TableColumn("Pending ID") { Text($0.id).font(.body.monospaced()) }
                        TableColumn("Consumer") { Text($0.consumer) }
                        TableColumn("Idle") { Text($0.idleMilliseconds.ttlDescription).foregroundStyle(.secondary) }.width(70)
                        TableColumn("Deliveries") { Text($0.deliveryCount, format: .number) }.width(70)
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
