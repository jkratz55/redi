import AppKit
import RediCore
import SwiftUI

// MARK: - Cells

/// Key cell: type badge + name. Reused by both the list and the tree.
final class KeyNameCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("KeyNameCell")
    let badge = TypeBadgeView()
    let label = NSTextField(labelWithString: "")
    let icon = NSImageView()
    private var labelAfterBadge: NSLayoutConstraint!
    private var labelAfterIcon: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        badge.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Namespace")
        icon.contentTintColor = .secondaryLabelColor
        addSubview(badge)
        addSubview(label)
        addSubview(icon)
        textField = label
        labelAfterBadge = label.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8)
        labelAfterIcon = label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)
        NSLayoutConstraint.activate([
            labelAfterBadge,
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 44),
            badge.heightAnchor.constraint(equalToConstant: 16),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configureKey(name: String, type: RedisKeyType, isDeleted: Bool) {
        badge.isHidden = false
        icon.isHidden = true
        labelAfterIcon.isActive = false
        labelAfterBadge.isActive = true
        badge.type = type
        label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        if isDeleted {
            label.attributedStringValue = NSAttributedString(string: name, attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular),
            ])
        } else {
            label.stringValue = name
            label.textColor = .labelColor
        }
        toolTip = name
    }

    func configureNamespace(name: String, count: Int) {
        badge.isHidden = true
        icon.isHidden = false
        labelAfterBadge.isActive = false
        labelAfterIcon.isActive = true
        label.font = .systemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        let attributed = NSMutableAttributedString(string: name.isEmpty ? "(empty)" : name, attributes: [.foregroundColor: NSColor.labelColor])
        attributed.append(NSAttributedString(string: "  \(count.formatted())", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        label.attributedStringValue = attributed
        toolTip = nil
    }
}

/// Right-aligned secondary text (TTL, size).
final class DetailTextCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("DetailTextCell")
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private enum Column {
    static let key = NSUserInterfaceItemIdentifier("key")
    static let ttl = NSUserInterfaceItemIdentifier("ttl")
    static let size = NSUserInterfaceItemIdentifier("size")

    static func make(_ table: NSTableView) {
        let key = NSTableColumn(identifier: Column.key)
        key.title = String(localized: "Key")
        key.minWidth = 140
        key.width = 200
        key.resizingMask = [.autoresizingMask, .userResizingMask]
        let ttl = NSTableColumn(identifier: Column.ttl)
        ttl.title = String(localized: "TTL")
        ttl.width = 64
        ttl.minWidth = 44
        ttl.headerCell.alignment = .right
        let size = NSTableColumn(identifier: Column.size)
        size.title = String(localized: "Size")
        size.width = 70
        size.minWidth = 50
        size.headerCell.alignment = .right
        table.addTableColumn(key)
        table.addTableColumn(ttl)
        table.addTableColumn(size)
    }
}

private func configureTable(_ table: NSTableView) {
    table.style = .inset
    table.usesAlternatingRowBackgroundColors = false
    table.rowHeight = 22
    table.allowsMultipleSelection = true
    table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
    table.usesAutomaticRowHeights = false
    table.setAccessibilityLabel(String(localized: "Keys"))
}

private func detailCell(_ table: NSTableView, text: String) -> DetailTextCell {
    let cell = table.makeView(withIdentifier: DetailTextCell.identifier, owner: nil) as? DetailTextCell ?? DetailTextCell()
    cell.label.stringValue = text
    return cell
}

private func ttlText(_ meta: KeyMetadata?) -> String {
    guard let meta else { return "" }
    if meta.isMissing { return "—" }
    return meta.ttl.map { $0.ttlDescription } ?? "∞"
}

private func sizeText(_ meta: KeyMetadata?) -> String {
    guard let memory = meta?.memory else { return "" }
    return memory.byteSize
}

// MARK: - List

/// Flat list of every loaded key (SCAN order), backed by `NSTableView`.
struct KeyListView: NSViewRepresentable {
    let model: BrowserModel
    var onDelete: ([Int]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, onDelete: onDelete) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyTableView()
        configureTable(table)
        Column.make(table)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.menu = context.coordinator.makeMenu()
        table.onDeleteKey = { [weak coordinator = context.coordinator] in coordinator?.deleteSelection() }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // Track the clip view's width so the Key column absorbs resizing and TTL/Size stay visible.
        table.autoresizingMask = [.width]
        table.sizeLastColumnToFit()
        context.coordinator.table = table
        context.coordinator.observeScrolling(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onDelete = onDelete
        context.coordinator.sync()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: BrowserModel
        var onDelete: ([Int]) -> Void
        weak var table: NSTableView?
        private var keysRevision = -1
        private var metadataRevision = -1
        private var rowCount = 0

        init(model: BrowserModel, onDelete: @escaping ([Int]) -> Void) {
            self.model = model
            self.onDelete = onDelete
        }

        /// Applies model changes with the cheapest table update that's correct.
        func sync() {
            guard let table else { return }
            let count = model.index.count
            if model.keysRevision != keysRevision {
                if count >= rowCount, rowCount > 0, keysRevision >= 0 {
                    table.noteNumberOfRowsChanged()
                } else {
                    table.reloadData()
                }
                rowCount = count
                keysRevision = model.keysRevision
                requestVisible()
            }
            if model.metadataRevision != metadataRevision {
                metadataRevision = model.metadataRevision
                let visible = table.rows(in: table.visibleRect)
                if visible.length > 0 {
                    table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                                     columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                }
            }
            let selected = model.selectedIndex.map { IndexSet(integer: $0) } ?? IndexSet()
            if table.selectedRowIndexes.count <= 1, table.selectedRowIndexes != selected, model.selectedIndex != nil {
                table.selectRowIndexes(selected, byExtendingSelection: false)
            }
        }

        func observeScrolling(_ scroll: NSScrollView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }

        @objc private func boundsChanged() { requestVisible() }

        private func requestVisible() {
            guard let table else { return }
            let range = table.rows(in: table.visibleRect)
            guard range.length > 0 else { return }
            model.requestMetadata(for: Array(range.location..<NSMaxRange(range)))
            // Near the end of what's loaded: fetch the next page, like infinite scrolling.
            if NSMaxRange(range) >= model.index.count - 20 { model.loadMore() }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { model.index.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < model.index.count, let column = tableColumn?.identifier else { return nil }
            let meta = model.metadata(at: row)
            switch column {
            case Column.key:
                let cell = tableView.makeView(withIdentifier: KeyNameCell.identifier, owner: nil) as? KeyNameCell ?? KeyNameCell()
                cell.configureKey(name: model.key(at: row).displayText, type: meta?.type ?? .unknown, isDeleted: meta?.isMissing == true)
                return cell
            case Column.ttl: return detailCell(tableView, text: ttlText(meta))
            default: return detailCell(tableView, text: sizeText(meta))
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            let rows = table.selectedRowIndexes
            model.select(index: rows.count == 1 ? rows.first : nil)
        }

        // MARK: Menu

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard !targetRows.isEmpty else { return }
            menu.addItem(withTitle: targetRows.count == 1 ? String(localized: "Copy Key Name") : String(localized: "Copy Key Names"),
                         action: #selector(copyNames), keyEquivalent: "").target = self
            if !model.isReadOnly {
                menu.addItem(.separator())
                menu.addItem(withTitle: String(localized: "Delete…"), action: #selector(deleteFromMenu), keyEquivalent: "").target = self
            }
        }

        private var targetRows: [Int] {
            guard let table else { return [] }
            let clicked = table.clickedRow
            if clicked >= 0, !table.selectedRowIndexes.contains(clicked) { return [clicked] }
            return Array(table.selectedRowIndexes)
        }

        @objc private func copyNames() { model.copyName(rows: targetRows) }
        @objc private func deleteFromMenu() { onDelete(targetRows) }

        func deleteSelection() {
            guard let table, !model.isReadOnly else { return }
            let rows = Array(table.selectedRowIndexes)
            if !rows.isEmpty { onDelete(rows) }
        }
    }
}

/// Table view that forwards ⌫ to a delete handler and ⌘C to copy.
final class KeyTableView: NSTableView {
    var onDeleteKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { // delete / forward delete
            onDeleteKey?()
        } else {
            super.keyDown(with: event)
        }
    }
}

final class KeyOutlineView: NSOutlineView {
    var onDeleteKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            onDeleteKey?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Tree

/// Leaf item for the outline (NSOutlineView items need stable object identity).
final class KeyLeaf {
    let index: Int
    init(index: Int) { self.index = index }
}

/// Namespace tree backed by `NSOutlineView`; children are produced lazily on expansion.
struct KeyTreeView: NSViewRepresentable {
    let model: BrowserModel
    var onDelete: ([Int]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, onDelete: onDelete) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = KeyOutlineView()
        configureTable(outline)
        Column.make(outline)
        outline.outlineTableColumn = outline.tableColumns.first
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.menu = context.coordinator.makeMenu()
        outline.onDeleteKey = { [weak coordinator = context.coordinator] in coordinator?.deleteSelection() }
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        outline.autoresizingMask = [.width]
        outline.sizeLastColumnToFit()
        context.coordinator.outline = outline
        context.coordinator.observeScrolling(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onDelete = onDelete
        context.coordinator.sync()
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        let model: BrowserModel
        var onDelete: ([Int]) -> Void
        weak var outline: NSOutlineView?
        private var keysRevision = -1
        private var metadataRevision = -1
        private var lastReload = ContinuousClock.now - .seconds(1)
        private var pendingReload: Task<Void, Never>?
        private var leaves: [Int: KeyLeaf] = [:]
        private var root: KeyTreeNode?

        init(model: BrowserModel, onDelete: @escaping ([Int]) -> Void) {
            self.model = model
            self.onDelete = onDelete
        }

        private func leaf(_ index: Int) -> KeyLeaf {
            if let existing = leaves[index] { return existing }
            let leaf = KeyLeaf(index: index)
            leaves[index] = leaf
            return leaf
        }

        func sync() {
            guard let outline else { return }
            if model.keysRevision != keysRevision {
                keysRevision = model.keysRevision
                if root !== model.tree.root {
                    // New scan: new tree, drop cached leaves.
                    root = model.tree.root
                    leaves.removeAll()
                    outline.reloadData()
                    lastReload = .now
                } else {
                    scheduleReload()
                }
            }
            if model.metadataRevision != metadataRevision {
                metadataRevision = model.metadataRevision
                let visible = outline.rows(in: outline.visibleRect)
                if visible.length > 0 {
                    outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                                       columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
                }
            }
        }

        /// While a big scan streams in, rebuild at most a few times a second.
        private func scheduleReload() {
            guard pendingReload == nil else { return }
            let elapsed = ContinuousClock.now - lastReload
            let delay = elapsed > .milliseconds(250) ? Duration.zero : .milliseconds(250) - elapsed
            pendingReload = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, let outline = self.outline else { return }
                self.pendingReload = nil
                self.lastReload = .now
                outline.reloadItem(nil, reloadChildren: true)
                self.autoExpand(outline)
                self.requestVisible()
            }
        }

        /// Filter results are shown expanded when there are few enough; a lone top-level
        /// namespace is opened so the first screen isn't a single folder.
        private func autoExpand(_ outline: NSOutlineView) {
            let root = model.tree.root
            if model.appliedFilter.matchPattern != nil, root.totalKeyCount <= 500 {
                outline.expandItem(nil, expandChildren: true)
            } else if root.childCount == 1, root.keyIndices.isEmpty, let only = root.sortedChildren.first, !outline.isItemExpanded(only) {
                outline.expandItem(only)
            }
        }

        func observeScrolling(_ scroll: NSScrollView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }

        @objc private func boundsChanged() { requestVisible() }

        private func requestVisible() {
            guard let outline else { return }
            let range = outline.rows(in: outline.visibleRect)
            guard range.length > 0 else { return }
            let rows = (range.location..<NSMaxRange(range)).compactMap { (outline.item(atRow: $0) as? KeyLeaf)?.index }
            model.requestMetadata(for: rows)
        }

        private func node(_ item: Any?) -> KeyTreeNode? {
            item == nil ? model.tree.root : item as? KeyTreeNode
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = node(item) else { return 0 }
            return node.childCount + node.keyIndices.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let node = node(item)!
            if index < node.childCount { return node.sortedChildren[index] }
            return leaf(Int(node.keyIndices[index - node.childCount]))
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            item is KeyTreeNode
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let column = tableColumn?.identifier else { return nil }
            if let node = item as? KeyTreeNode {
                guard column == Column.key else { return nil }
                let cell = outlineView.makeView(withIdentifier: KeyNameCell.identifier, owner: nil) as? KeyNameCell ?? KeyNameCell()
                cell.configureNamespace(name: node.name, count: node.totalKeyCount)
                return cell
            }
            guard let leaf = item as? KeyLeaf, leaf.index < model.index.count else { return nil }
            let meta = model.metadata(at: leaf.index)
            switch column {
            case Column.key:
                let cell = outlineView.makeView(withIdentifier: KeyNameCell.identifier, owner: nil) as? KeyNameCell ?? KeyNameCell()
                cell.configureKey(name: model.key(at: leaf.index).displayText, type: meta?.type ?? .unknown, isDeleted: meta?.isMissing == true)
                return cell
            case Column.ttl: return detailCell(outlineView, text: ttlText(meta))
            default: return detailCell(outlineView, text: sizeText(meta))
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) { requestVisible() }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline else { return }
            let leaves = selectedLeaves
            if leaves.count == 1 {
                model.select(index: leaves[0])
            } else if outline.selectedRowIndexes.count != 1 || leaves.isEmpty {
                model.select(index: nil)
            }
        }

        private var selectedLeaves: [Int] {
            guard let outline else { return [] }
            return outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? KeyLeaf)?.index }
        }

        // MARK: Menu

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        private var clickedNode: KeyTreeNode? {
            guard let outline, outline.clickedRow >= 0 else { return nil }
            return outline.item(atRow: outline.clickedRow) as? KeyTreeNode
        }

        private var targetRows: [Int] {
            guard let outline else { return [] }
            let clicked = outline.clickedRow
            if clicked >= 0, !outline.selectedRowIndexes.contains(clicked) {
                return (outline.item(atRow: clicked) as? KeyLeaf).map { [$0.index] } ?? []
            }
            return selectedLeaves
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if let node = clickedNode {
                let pattern = ScanFilterEscaping.escape(String(decoding: node.prefix, as: UTF8.self))
                menu.addItem(withTitle: String(localized: "Filter to “\(String(decoding: node.prefix, as: UTF8.self))*”"),
                             action: #selector(filterToNamespace(_:)), keyEquivalent: "").representedObject = pattern + "*"
                menu.items.last?.target = self
                menu.addItem(withTitle: String(localized: "Copy Namespace"), action: #selector(copyNamespace(_:)), keyEquivalent: "")
                    .representedObject = String(decoding: node.prefix, as: UTF8.self)
                menu.items.last?.target = self
                return
            }
            guard !targetRows.isEmpty else { return }
            menu.addItem(withTitle: targetRows.count == 1 ? String(localized: "Copy Key Name") : String(localized: "Copy Key Names"),
                         action: #selector(copyNames), keyEquivalent: "").target = self
            if !model.isReadOnly {
                menu.addItem(.separator())
                menu.addItem(withTitle: String(localized: "Delete…"), action: #selector(deleteFromMenu), keyEquivalent: "").target = self
            }
        }

        @objc private func filterToNamespace(_ sender: NSMenuItem) {
            guard let pattern = sender.representedObject as? String else { return }
            model.filterText = pattern
            model.applyFilter()
        }

        @objc private func copyNamespace(_ sender: NSMenuItem) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(sender.representedObject as? String ?? "", forType: .string)
        }

        @objc private func copyNames() { model.copyName(rows: targetRows) }
        @objc private func deleteFromMenu() { onDelete(targetRows) }

        func deleteSelection() {
            guard !model.isReadOnly else { return }
            let rows = selectedLeaves
            if !rows.isEmpty { onDelete(rows) }
        }
    }
}

enum ScanFilterEscaping {
    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if "*?[]\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
