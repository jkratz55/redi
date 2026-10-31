import AppKit
import Foundation
import Observation
import os
import RediCore
import RedisClient
import RedisWire

/// State for the Key Browser. Keys live in a paged byte arena (`KeyIndex`) and a namespace tree.
/// Only visible rows ever get metadata or decoded strings.
@Observable
final class BrowserModel {
    enum Layout: String, CaseIterable, Identifiable {
        case list, tree
        var id: Self { self }
    }

    var filterText = ""
    var typeFilter: RedisKeyType? {
        didSet { if oldValue != typeFilter { reload() } }
    }
    var layout: Layout {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: SettingsKey.defaultBrowserLayout) }
    }

    private(set) var index = KeyIndex()
    @ObservationIgnored private(set) var tree: KeyTree
    /// Bumped when keys are appended or the scan is reset (drives table/outline reloads).
    private(set) var keysRevision = 0
    /// Bumped when metadata for some rows arrives.
    private(set) var metadataRevision = 0
    private(set) var isScanning = false
    private(set) var isScanComplete = false
    private(set) var approximateScanned = 0
    private(set) var databaseSize: Int?
    private(set) var error: String?
    private(set) var appliedFilter = ScanFilter()

    private(set) var selectedIndex: Int?
    private(set) var detail: KeyDetailModel?
    /// Keys deleted since the last reload (shown dimmed until the next refresh).
    @ObservationIgnored private(set) var deleted = Set<Int>()

    @ObservationIgnored private unowned let workspace: WorkspaceModel
    @ObservationIgnored private var cursor = ScanCursor()
    /// Bumped by `reload` (new filter, database or refresh). Row numbers from an older generation
    /// refer to different keys, so scan and metadata results from one are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var deduplicator = KeyDeduplicator()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var metadata: [Int: KeyMetadata] = [:]
    @ObservationIgnored private var pendingMetadata = Set<Int>()
    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    @ObservationIgnored private var scanner: KeyScanner?
    /// The window's undo manager, once a delete has registered an undo with it.
    @ObservationIgnored private weak var undoManager: UndoManager?
    @ObservationIgnored private let signposter = OSSignposter(subsystem: "com.github.jkratz55.Redi", category: "Browser")

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        tree = KeyTree(delimiter: workspace.keyDelimiter)
        layout = Layout(rawValue: UserDefaults.standard.string(forKey: SettingsKey.defaultBrowserLayout) ?? "") ?? .tree
    }

    var session: RedisSession? { workspace.session }
    var isReadOnly: Bool { workspace.profile.isReadOnly }
    var isProduction: Bool { workspace.profile.isProduction }
    var keyDelimiter: String { workspace.keyDelimiter }

    private var scanCount: Int {
        let stored = UserDefaults.standard.integer(forKey: SettingsKey.scanCount)
        return stored > 0 ? stored : 500
    }

    // MARK: - Scanning

    /// Clears everything and loads the first page with the current filter.
    func reload() {
        generation += 1
        scanTask?.cancel()
        metadataTask?.cancel()
        index = KeyIndex()
        tree = KeyTree(delimiter: workspace.keyDelimiter)
        deduplicator.removeAll()
        metadata.removeAll()
        pendingMetadata.removeAll()
        deleted.removeAll()
        cursor = ScanCursor()
        approximateScanned = 0
        isScanComplete = false
        error = nil
        appliedFilter = ScanFilter(pattern: filterText, type: typeFilter)
        keysRevision += 1
        selectedIndex = nil
        scan(target: scanCount, lookupExact: true)
    }

    func applyFilter() {
        reload()
    }

    func loadMore() {
        guard !isScanning, !isScanComplete else { return }
        scan(target: scanCount, lookupExact: false)
    }

    /// Scans until the whole keyspace has been visited (cancellable).
    func scanAll() {
        guard !isScanning, !isScanComplete else { return }
        scan(target: .max, lookupExact: false)
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func scan(target: Int, lookupExact: Bool) {
        guard let session else { return }
        isScanning = true
        let filter = appliedFilter
        let count = max(scanCount, 100)
        let scanning = generation
        scanTask = Task { [weak self] in
            // After a reload, `isScanning` belongs to the new scan.
            defer { if let self, self.generation == scanning { self.isScanning = false } }
            do {
                guard let self else { return }
                let scanner: KeyScanner
                if let existing = self.scanner {
                    scanner = existing
                } else {
                    scanner = await KeyScanner(session: session)
                    self.scanner = scanner
                }
                if self.databaseSize == nil || lookupExact {
                    let size = try? await scanner.databaseSize()
                    guard self.generation == scanning else { return }
                    self.databaseSize = size
                }
                if lookupExact, let exact = filter.exactKey, let type = try await scanner.lookup(exactKey: exact, type: filter.type) {
                    guard self.generation == scanning else { return }
                    self.append(keys: [Array(exact.utf8)], type: type)
                }
                var collected = 0
                while self.generation == scanning, !Task.isCancelled, !self.cursor.isComplete, collected < target {
                    let state = self.signposter.beginInterval("ScanPage")
                    let result = try await scanner.next(from: self.cursor, filter: filter, count: count,
                                                        target: min(target - collected, count * 4), maxIterations: 20)
                    self.signposter.endInterval("ScanPage", state)
                    guard self.generation == scanning, !Task.isCancelled else { break }
                    self.cursor = result.cursor
                    self.approximateScanned += result.iterations * count
                    collected += self.append(keys: result.keys, type: result.type)
                }
                guard self.generation == scanning else { return }
                self.isScanComplete = self.cursor.isComplete
                if self.isScanComplete, let size = self.databaseSize { self.approximateScanned = size }
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == scanning else { return }
                self.error = String(describing: error)
            }
        }
    }

    /// Adds new (deduplicated) keys as one page. Returns how many were new.
    @discardableResult
    private func append(keys: [[UInt8]], type: RedisKeyType?) -> Int {
        let fresh = keys.filter { deduplicator.insert($0) }
        guard !fresh.isEmpty else { return 0 }
        let state = signposter.beginInterval("AppendPage")
        let start = index.count
        index.append(KeyPage(keys: fresh, type: type))
        tree.insert(from: index, range: start..<index.count)
        signposter.endInterval("AppendPage", state)
        keysRevision += 1
        return fresh.count
    }

    var statusText: String {
        let loaded = index.count.formatted()
        guard let total = databaseSize else { return String(localized: "\(loaded) keys") }
        if appliedFilter.matchPattern == nil && appliedFilter.type == nil {
            return String(localized: "\(loaded) of \(total.formatted()) keys")
        }
        let scanned = min(approximateScanned, total)
        let matches = AttributedString(localized: "^[\(index.count) match](inflect: true)")
        return String(matches.characters) + String(localized: " · scanned \(scanned.formatted()) of \(total.formatted())")
    }

    // MARK: - Rows

    func key(at index: Int) -> ArraySlice<UInt8> { self.index.key(at: index) }

    func metadata(at index: Int) -> KeyMetadata? {
        if deleted.contains(index) { return KeyMetadata(type: .none, ttl: nil, memory: nil) }
        if let cached = metadata[index] { return cached }
        if let type = self.index.knownType(at: index) { return KeyMetadata(type: type, ttl: nil, memory: nil) }
        return nil
    }

    /// Called with the rows currently on screen. Fetches what's missing, coalescing scroll bursts.
    func requestMetadata(for rows: [Int]) {
        let missing = rows.filter { metadata[$0] == nil && !pendingMetadata.contains($0) && $0 < index.count }
        guard !missing.isEmpty, let session else { return }
        pendingMetadata.formUnion(missing)
        let keys = missing.map { Array(index.key(at: $0)) }
        let requesting = generation
        metadataTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, !Task.isCancelled, self.generation == requesting else { return }
            let state = self.signposter.beginInterval("Metadata", "\(keys.count) keys")
            defer { self.signposter.endInterval("Metadata", state) }
            let loaded = try? await KeyMetadata.load(keys, session: session)
            // Reloaded meanwhile: these row numbers now belong to other keys.
            guard self.generation == requesting else { return }
            for (row, meta) in zip(missing, loaded ?? []) { self.metadata[row] = meta }
            if self.metadata.count > 100_000 {
                // Bound memory when someone scrolls through millions of rows.
                self.metadata = self.metadata.filter { missing.contains($0.key) }
            }
            self.pendingMetadata.subtract(missing)
            self.metadataRevision += 1
        }
    }

    // MARK: - Selection and actions

    func select(index: Int?) {
        selectedIndex = index
        guard let index, let session else {
            detail = nil
            return
        }
        let key = Array(self.index.key(at: index))
        if detail?.key == key { return }
        detail = KeyDetailModel(key: key, session: session, browser: self, isReadOnly: isReadOnly)
    }

    func showDetail(forNewKey key: [UInt8], type: RedisKeyType) {
        if deduplicator.insert(key) {
            let start = index.count
            index.append(KeyPage(keys: [key], type: type))
            tree.insert(from: index, range: start..<index.count)
            keysRevision += 1
            if let size = databaseSize { databaseSize = size + 1 }
            select(index: start)
        } else if let session {
            detail = KeyDetailModel(key: key, session: session, browser: self, isReadOnly: isReadOnly)
        }
    }

    /// Marks rows whose key was deleted (from the detail pane or a context menu).
    func markDeleted(_ key: [UInt8]) {
        if let selected = selectedIndex, selected < index.count, index.key(at: selected).elementsEqual(key) {
            deleted.insert(selected)
        } else if let row = (0..<index.count).first(where: { index.key(at: $0).elementsEqual(key) }) {
            deleted.insert(row)
        }
        if detail?.key == key { detail = nil }
        metadataRevision += 1
    }

    func markRestored(_ key: [UInt8]) {
        if let row = deleted.first(where: { self.index.key(at: $0).elementsEqual(key) }) {
            deleted.remove(row)
            metadata[row] = nil
        }
        metadataRevision += 1
    }

    /// Deletes keys, with undo when every key is small enough to snapshot.
    func delete(rows: [Int], undoManager: UndoManager?) async {
        guard let session else { return }
        let keys = rows.map { Array(index.key(at: $0)) }
        let ops = KeyOperations(session: session)
        let limitKB = UserDefaults.standard.object(forKey: SettingsKey.undoDeleteSizeLimitKB) as? Int ?? 1024
        var snapshots: [KeyOperations.Snapshot] = []
        if limitKB > 0, keys.count <= 100 {
            let sizes = (try? await KeyMetadata.load(keys, session: session)) ?? []
            if sizes.count == keys.count, sizes.allSatisfy({ ($0.memory ?? .max) <= Int64(limitKB) * 1024 }) {
                for key in keys { if let snapshot = try? await ops.snapshot(key) { snapshots.append(snapshot) } }
            }
        }
        do {
            try await ops.delete(keys)
            for key in keys { markDeleted(key) }
            if snapshots.count == keys.count, let undoManager {
                registerUndo(snapshots, undoManager: undoManager)
            }
        } catch {
            workspace.show(notice: String(describing: error))
        }
    }

    func canUndoDelete(rows: [Int]) -> Bool {
        let limitKB = UserDefaults.standard.object(forKey: SettingsKey.undoDeleteSizeLimitKB) as? Int ?? 1024
        guard limitKB > 0, rows.count <= 100 else { return false }
        return rows.allSatisfy { (metadata[$0]?.memory ?? .max) <= Int64(limitKB) * 1024 }
    }

    private func registerUndo(_ snapshots: [KeyOperations.Snapshot], undoManager: UndoManager) {
        self.undoManager = undoManager
        undoManager.registerUndo(withTarget: self) { model in
            Task {
                guard let session = model.session else { return }
                let ops = KeyOperations(session: session)
                // Restore each key on its own, so one conflict doesn't stop the rest.
                var failures: [String] = []
                for snapshot in snapshots {
                    do {
                        try await ops.restore(snapshot)
                        model.markRestored(snapshot.key)
                    } catch {
                        failures.append(String(describing: error))
                    }
                }
                if let first = failures.first {
                    model.workspace.show(notice: failures.count == 1 ? first
                        : String(localized: "\(first) (and \(failures.count - 1) more)"))
                }
            }
        }
        undoManager.setActionName(snapshots.count == 1 ? String(localized: "Delete Key") : String(localized: "Delete Keys"))
    }

    /// Called after switching databases. Pending delete undos belong to the old database, so they're
    /// dropped rather than left to fail (`KeyOperations.restore` also refuses another database).
    func databaseDidChange() {
        undoManager?.removeAllActions(withTarget: self)
        reload()
    }

    func copyName(rows: [Int]) {
        let names = rows.map { String(decoding: index.key(at: $0), as: UTF8.self) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
    }

    func openInCLI(command: String) {
        workspace.bottomPanelTab = .cli
        workspace.isBottomPanelVisible = true
        workspace.pendingCLICommand = command
    }
}
