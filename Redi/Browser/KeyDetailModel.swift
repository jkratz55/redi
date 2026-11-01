import Foundation
import Observation
import RediCore
import RedisClient
import RedisWire

/// The selected key: header details plus a type-specific value model.
@Observable
final class KeyDetailModel {
    enum Value {
        case loading
        case string(StringValueModel)
        case hash(HashValueModel)
        case list(ListValueModel)
        case set(SetValueModel)
        case zset(SortedSetValueModel)
        case stream(StreamValueModel)
        case json(JSONValueModel)
        case unsupported(RedisKeyType)
        case missing
    }

    let key: [UInt8]
    let ops: KeyOperations
    let isReadOnly: Bool
    private(set) var details: KeyDetails?
    private(set) var value: Value = .loading
    private(set) var isLoading = false
    var error: String?

    @ObservationIgnored private weak var browser: BrowserModel?

    init(key: [UInt8], session: RedisSession, browser: BrowserModel, isReadOnly: Bool) {
        self.key = key
        ops = KeyOperations(session: session)
        self.browser = browser
        self.isReadOnly = isReadOnly
    }

    var name: String { key.displayText }
    var session: RedisSession { ops.session }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let details = try await ops.details(key)
            self.details = details
            await loadValue(type: details.type)
        } catch {
            report(error)
        }
    }

    /// Re-reads the header (after edits that change length or TTL).
    func refreshHeader() async {
        if let details = try? await ops.details(key) { self.details = details }
    }

    private func loadValue(type: RedisKeyType) async {
        let report: (any Error) -> Void = { [weak self] in self?.report($0) }
        let onChange: () -> Void = { [weak self] in Task { await self?.refreshHeader() } }
        switch type {
        case .none:
            value = .missing
            browser?.markDeleted(key)
        case .string:
            let model = reuse(\.string) ?? StringValueModel(key: key, ops: ops, report: report, onChange: onChange)
            value = .string(model)
            await model.load()
        case .hash:
            let fieldTTL = await session.hello?.version ?? ServerVersion(0) >= ServerVersion(7, 4)
            let model = reuse(\.hash) ?? HashValueModel(key: key, ops: ops, supportsFieldTTL: fieldTTL, report: report, onChange: onChange)
            value = .hash(model)
            await model.reload()
        case .list:
            let model = reuse(\.list) ?? ListValueModel(key: key, ops: ops, report: report, onChange: onChange)
            value = .list(model)
            await model.reload()
        case .set:
            let model = reuse(\.set) ?? SetValueModel(key: key, ops: ops, report: report, onChange: onChange)
            value = .set(model)
            await model.reload()
        case .zset:
            let model = reuse(\.zset) ?? SortedSetValueModel(key: key, ops: ops, report: report, onChange: onChange)
            value = .zset(model)
            await model.reload()
        case .stream:
            let model = reuse(\.stream) ?? StreamValueModel(key: key, ops: ops, report: report, onChange: onChange)
            value = .stream(model)
            await model.reload()
        case .json:
            let model = reuse(\.json) ?? JSONValueModel(key: key, ops: ops, report: report)
            value = .json(model)
            await model.load()
        default:
            value = .unsupported(type)
        }
    }

    private func reuse<T>(_ path: KeyPath<Value, T?>) -> T? { value[keyPath: path] }

    func report(_ error: any Error) {
        self.error = String(describing: error)
    }

    // MARK: - Key actions

    func rename(to newName: String) async -> Bool {
        let bytes = Array(newName.utf8)
        guard !bytes.isEmpty, bytes != key else { return false }
        do {
            try await ops.rename(key, to: bytes)
            browser?.markDeleted(key)
            browser?.showDetail(forNewKey: bytes, type: details?.type ?? .unknown)
            return true
        } catch {
            report(error)
            return false
        }
    }

    func setTTL(seconds: Int64?) async {
        do {
            try await ops.setTTL(key, seconds: seconds)
            await refreshHeader()
        } catch {
            report(error)
        }
    }

    func openInCLI(_ command: String) {
        browser?.openInCLI(command: command)
    }
}

extension KeyDetailModel.Value {
    var string: StringValueModel? { if case .string(let model) = self { model } else { nil } }
    var hash: HashValueModel? { if case .hash(let model) = self { model } else { nil } }
    var list: ListValueModel? { if case .list(let model) = self { model } else { nil } }
    var set: SetValueModel? { if case .set(let model) = self { model } else { nil } }
    var zset: SortedSetValueModel? { if case .zset(let model) = self { model } else { nil } }
    var stream: StreamValueModel? { if case .stream(let model) = self { model } else { nil } }
    var json: JSONValueModel? { if case .json(let model) = self { model } else { nil } }
}

// MARK: - Value models

/// Paging state for a collection value (HSCAN/SSCAN/ZSCAN cursors or LRANGE/ZRANGE offsets).
@Observable
final class CollectionPager<Element: Identifiable & Sendable> {
    private(set) var elements: [Element] = []
    private(set) var isLoading = false
    /// Cursor or offset for the next page; `nil` when everything is loaded.
    private(set) var next: String? = "0"
    var search = ""
    /// How element values are shown. Chosen from the first page that has elements, unless set first.
    var format: ValueFormat = .text {
        didSet { hasFormat = true }
    }
    let supportsSearch: Bool
    let pageSize = 200

    @ObservationIgnored private let fetch: (_ cursor: String, _ pattern: String?) async throws -> ValuePage<Element>
    @ObservationIgnored private let report: (any Error) -> Void
    /// The values of an element that `format` applies to, for picking the initial format.
    @ObservationIgnored private let formattedValues: (Element) -> [[UInt8]]
    @ObservationIgnored private(set) var hasFormat = false
    /// Bumped by `reload`. A load that finds it changed after a fetch was superseded, and drops its page.
    @ObservationIgnored private var generation = 0

    init(supportsSearch: Bool, report: @escaping (any Error) -> Void, formattedValues: @escaping (Element) -> [[UInt8]],
         fetch: @escaping (_ cursor: String, _ pattern: String?) async throws -> ValuePage<Element>) {
        self.supportsSearch = supportsSearch
        self.report = report
        self.formattedValues = formattedValues
        self.fetch = fetch
    }

    /// Glob for server-side search; plain text means "contains".
    var searchPattern: String? {
        guard supportsSearch else { return nil }
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.contains(where: { "*?[".contains($0) }) ? trimmed : "*\(ScanFilterEscaping.escape(trimmed))*"
    }

    /// Starts over from the first page with the current search. A load still in flight is
    /// superseded: its results are dropped, and this one runs instead of waiting for it.
    func reload() async {
        generation += 1
        elements = []
        next = "0"
        isLoading = false
        await loadMore()
    }

    func loadMore() async {
        guard let start = next, !isLoading else { return }
        let loading = generation
        isLoading = true
        // A superseding reload owns `isLoading` now.
        defer { if generation == loading { isLoading = false } }
        do {
            // A sparse MATCH can return empty pages; keep going until something arrives.
            var cursor: String? = start
            var collected: [Element] = []
            var rounds = 0
            let pattern = searchPattern
            while let current = cursor, collected.count < pageSize, rounds < 50 {
                let page = try await fetch(current, pattern)
                guard generation == loading else { return }
                collected.append(contentsOf: page.elements)
                cursor = page.next
                rounds += 1
                if pattern == nil { break }
            }
            elements.append(contentsOf: collected)
            next = cursor
            if !hasFormat, !collected.isEmpty {
                format = ValueFormatter.detect(elements: collected.prefix(32).flatMap(formattedValues))
            }
        } catch {
            guard generation == loading else { return }
            report(error)
            next = nil
        }
    }

    func update(_ transform: (inout [Element]) -> Void) {
        transform(&elements)
    }
}

/// Runs a mutation, reporting failures and refreshing the header on success.
private func perform(_ report: (any Error) -> Void, _ onChange: () -> Void, _ action: () async throws -> Void) async {
    do {
        try await action()
        onChange()
    } catch {
        report(error)
    }
}

@Observable
final class StringValueModel {
    let key: [UInt8]
    let ops: KeyOperations
    private(set) var bytes: [UInt8] = []
    private(set) var isTruncated = false
    private(set) var isLoading = false
    var format: ValueFormat = .text {
        didSet { if oldValue != format { text = rendered() } }
    }
    var text = ""
    @ObservationIgnored private let report: (any Error) -> Void
    @ObservationIgnored private let onChange: () -> Void

    static let previewLimit = 1_048_576

    init(key: [UInt8], ops: KeyOperations, report: @escaping (any Error) -> Void, onChange: @escaping () -> Void) {
        self.key = key
        self.ops = ops
        self.report = report
        self.onChange = onChange
    }

    var isDirty: Bool { text != rendered() }
    var canEdit: Bool { format.isEditable && !isTruncated }

    func rendered() -> String {
        if format == .messagePack, isTruncated, !MessagePack.isSingleValue(bytes) {
            return String(localized: "MessagePack is decoded from the whole value, and only the first \(Int64(Self.previewLimit).byteSize) is loaded. Click Load Full Value to decode it.")
        }
        return ValueFormatter.render(bytes, as: format)
    }

    func load(full: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let (value, truncated) = try await ops.string(key, limit: full ? Int.max : Self.previewLimit)
            bytes = value
            isTruncated = truncated
            format = ValueFormatter.detect(value)
            text = rendered()
        } catch {
            report(error)
        }
    }

    func save() async {
        do {
            let newBytes = try ValueFormatter.parse(text, as: format)
            try await ops.setString(key, value: newBytes)
            bytes = newBytes
            text = rendered()
            onChange()
        } catch {
            report(error)
        }
    }

    func revert() { text = rendered() }
}

@Observable
final class HashValueModel {
    let key: [UInt8]
    let ops: KeyOperations
    let supportsFieldTTL: Bool
    let pager: CollectionPager<HashEntry>
    @ObservationIgnored private let report: (any Error) -> Void
    @ObservationIgnored private let onChange: () -> Void

    init(key: [UInt8], ops: KeyOperations, supportsFieldTTL: Bool, report: @escaping (any Error) -> Void, onChange: @escaping () -> Void) {
        self.key = key
        self.ops = ops
        self.supportsFieldTTL = supportsFieldTTL
        self.report = report
        self.onChange = onChange
        pager = CollectionPager(supportsSearch: true, report: report, formattedValues: { [$0.value] }) { cursor, pattern in
            try await ops.hashPage(key, cursor: cursor, match: pattern, count: 200, withFieldTTL: supportsFieldTTL)
        }
    }

    func reload() async { await pager.reload() }

    func set(field: [UInt8], value: [UInt8], ttl: Int64?) async {
        await perform(report, onChange) {
            try await ops.setHashField(key, field: field, value: value)
            if supportsFieldTTL, let ttl { try await ops.setHashFieldTTL(key, field: field, seconds: ttl > 0 ? ttl : nil) }
            pager.update { elements in
                let newTTL = ttl.flatMap { $0 > 0 ? $0 : nil }
                if let index = elements.firstIndex(where: { $0.field == field }) {
                    elements[index].value = value
                    if ttl != nil { elements[index].ttl = newTTL }
                } else {
                    elements.insert(HashEntry(field: field, value: value, ttl: newTTL), at: 0)
                }
            }
        }
    }

    func delete(fields: [[UInt8]]) async {
        await perform(report, onChange) {
            try await ops.deleteHashFields(key, fields: fields)
            pager.update { $0.removeAll { fields.contains($0.field) } }
        }
    }
}

@Observable
final class ListValueModel {
    let key: [UInt8]
    let ops: KeyOperations
    let pager: CollectionPager<ListEntry>
    @ObservationIgnored private let report: (any Error) -> Void
    @ObservationIgnored private let onChange: () -> Void

    init(key: [UInt8], ops: KeyOperations, report: @escaping (any Error) -> Void, onChange: @escaping () -> Void) {
        self.key = key
        self.ops = ops
        self.report = report
        self.onChange = onChange
        pager = CollectionPager(supportsSearch: false, report: report, formattedValues: { [$0.value] }) { cursor, _ in
            let start = Int(cursor) ?? 0
            let entries = try await ops.listRange(key, start: start, count: 200)
            return ValuePage(elements: entries, next: entries.count == 200 ? String(start + entries.count) : nil)
        }
    }

    func reload() async { await pager.reload() }

    func set(index: Int, value: [UInt8]) async {
        await perform(report, onChange) {
            try await ops.setListElement(key, index: index, value: value)
            pager.update { elements in
                if let position = elements.firstIndex(where: { $0.index == index }) { elements[position].value = value }
            }
        }
    }

    func push(_ value: [UInt8], atHead: Bool) async {
        await perform(report, onChange) { try await ops.pushList(key, values: [value], atHead: atHead) }
        await reload()
    }

    func remove(index: Int) async {
        guard let expected = pager.elements.first(where: { $0.index == index })?.value else { return }
        await perform(report, onChange) { try await ops.removeListElement(key, index: index, expected: expected) }
        await reload()
    }
}

nonisolated struct SetMember: Identifiable, Sendable, Hashable {
    var value: [UInt8]
    var id: [UInt8] { value }
}

@Observable
final class SetValueModel {
    let key: [UInt8]
    let ops: KeyOperations
    let pager: CollectionPager<SetMember>
    @ObservationIgnored private let report: (any Error) -> Void
    @ObservationIgnored private let onChange: () -> Void

    init(key: [UInt8], ops: KeyOperations, report: @escaping (any Error) -> Void, onChange: @escaping () -> Void) {
        self.key = key
        self.ops = ops
        self.report = report
        self.onChange = onChange
        pager = CollectionPager(supportsSearch: true, report: report, formattedValues: { [$0.value] }) { cursor, pattern in
            let page = try await ops.setPage(key, cursor: cursor, match: pattern, count: 200)
            return ValuePage(elements: page.elements.map(SetMember.init), next: page.next)
        }
    }

    func reload() async { await pager.reload() }

    func add(_ member: [UInt8]) async {
        await perform(report, onChange) {
            try await ops.addSetMembers(key, members: [member])
            pager.update { elements in
                if !elements.contains(where: { $0.value == member }) { elements.insert(SetMember(value: member), at: 0) }
            }
        }
    }

    func remove(_ members: [[UInt8]]) async {
        await perform(report, onChange) {
            try await ops.removeSetMembers(key, members: members)
            pager.update { $0.removeAll { members.contains($0.value) } }
        }
    }
}

@Observable
final class SortedSetValueModel {
    let key: [UInt8]
    let ops: KeyOperations
    private(set) var pager: CollectionPager<SortedSetEntry>
    var descending = false {
        didSet {
            guard oldValue != descending else { return }
            let previous = pager
            pager = makePager()
            if previous.hasFormat { pager.format = previous.format }
            Task { await reload() }
        }
    }
    @ObservationIgnored private let report: (any Error) -> Void
    @ObservationIgnored private let onChange: () -> Void

    init(key: [UInt8], ops: KeyOperations, report: @escaping (any Error) -> Void, onChange: @escaping () -> Void) {
        self.key = key
        self.ops = ops
        self.report = report
        self.onChange = onChange
        pager = CollectionPager(supportsSearch: true, report: report, formattedValues: { _ in [] }) { _, _ in ValuePage(elements: [], next: nil) }
        pager = makePager()
    }

    private func makePager() -> CollectionPager<SortedSetEntry> {
        let (key, ops, descending) = (self.key, self.ops, self.descending)
        return CollectionPager(supportsSearch: true, report: report, formattedValues: { [$0.member] }) { cursor, pattern in
            if let pattern {
                return try await ops.sortedSetPage(key, cursor: cursor, match: pattern, count: 200)
            }
            let start = Int(cursor) ?? 0
            let entries = try await ops.sortedSetRange(key, start: start, count: 200, descending: descending)
            return ValuePage(elements: entries, next: entries.count == 200 ? String(start + entries.count) : nil)
        }
    }

    func reload() async { await pager.reload() }

    func add(member: [UInt8], score: Double) async {
        await perform(report, onChange) { try await ops.addSortedSetMember(key, member: member, score: score) }
        await reload()
    }

    func remove(_ members: [[UInt8]]) async {
        await perform(report, onChange) {
            try await ops.removeSortedSetMembers(key, members: members)
            pager.update { $0.removeAll { members.contains($0.member) } }
        }
    }
}

@Observable
final class StreamValueModel {
    let key: [UInt8]
    let ops: KeyOperations
    let pager: CollectionPager<StreamEntry>
    private(set) var groups: [StreamGroup] = []
    private(set) var consumers: [StreamConsumer] = []
    private(set) var pending: [PendingMessage] = []
    var selectedGroup: String? {
        didSet { if oldValue != selectedGroup { Task { await loadGroupDetails() } } }
    }
    @ObservationIgnored private let report: (any Error) -> Void
    @ObservationIgnored private let onChange: () -> Void

    init(key: [UInt8], ops: KeyOperations, report: @escaping (any Error) -> Void, onChange: @escaping () -> Void) {
        self.key = key
        self.ops = ops
        self.report = report
        self.onChange = onChange
        pager = CollectionPager(supportsSearch: false, report: report, formattedValues: { $0.fields.map(\.value) }) { cursor, _ in
            try await ops.streamPage(key, before: cursor == "0" ? nil : cursor, count: 200)
        }
    }

    func reload() async { await pager.reload() }

    /// Field names across loaded entries, in first-seen order (table columns).
    var fieldNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for entry in pager.elements.prefix(500) {
            for field in entry.fields {
                let name = field.name.displayText
                if seen.insert(name).inserted { names.append(name) }
            }
        }
        return names
    }

    func loadGroups() async {
        do {
            groups = try await ops.streamGroups(key)
            if selectedGroup == nil || !groups.contains(where: { $0.name == selectedGroup }) { selectedGroup = groups.first?.name }
            await loadGroupDetails()
        } catch {
            report(error)
        }
    }

    private func loadGroupDetails() async {
        guard let group = selectedGroup else {
            consumers = []
            pending = []
            return
        }
        do {
            consumers = try await ops.streamConsumers(key, group: group)
            pending = try await ops.pendingMessages(key, group: group)
        } catch {
            report(error)
        }
    }

    func add(id: String, fields: [(name: [UInt8], value: [UInt8])]) async {
        await perform(report, onChange) { _ = try await ops.addStreamEntry(key, id: id, fields: fields) }
        await reload()
    }

    func delete(ids: [String]) async {
        await perform(report, onChange) {
            try await ops.deleteStreamEntries(key, ids: ids)
            pager.update { $0.removeAll { ids.contains($0.id) } }
        }
    }

    func createGroup(name: String, startID: String) async {
        await perform(report, onChange) { try await ops.createStreamGroup(key, name: name, startID: startID) }
        await loadGroups()
    }

    func deleteGroup(_ name: String) async {
        await perform(report, onChange) { try await ops.deleteStreamGroup(key, name: name) }
        await loadGroups()
    }

    func acknowledge(_ ids: [String]) async {
        guard let group = selectedGroup else { return }
        await perform(report, onChange) { try await ops.acknowledge(key, group: group, ids: ids) }
        await loadGroups()
    }
}

@Observable
final class JSONValueModel {
    let key: [UInt8]
    let ops: KeyOperations
    var text = ""
    private(set) var original = ""
    private(set) var isLoading = false
    @ObservationIgnored private let report: (any Error) -> Void

    init(key: [UInt8], ops: KeyOperations, report: @escaping (any Error) -> Void) {
        self.key = key
        self.ops = ops
        self.report = report
    }

    var isDirty: Bool { text != original }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            original = ValueFormatter.prettyJSON(try await ops.json(key))
            text = original
        } catch {
            report(error)
        }
    }

    func save() async {
        do {
            _ = try ValueFormatter.parse(text, as: .json)
            try await ops.setJSON(key, json: text)
            await load()
        } catch {
            report(error)
        }
    }
}
