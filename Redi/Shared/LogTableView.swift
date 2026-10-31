import AppKit
import SwiftUI

/// High-rate log table (`NSTableView`) for Pub/Sub messages and MONITOR output. Only visible rows
/// are materialised. Follows the tail while scrolled to the bottom.
struct LogTableView: NSViewRepresentable {
    struct Column {
        var id: String
        var title: String
        var width: CGFloat
        var isFlexible = false
        var isMonospaced = true
        var isSecondary = false
    }

    let columns: [Column]
    let rowCount: Int
    /// Changes whenever the rows change (append, eviction, filter).
    let revision: Int
    let text: (_ row: Int, _ column: String) -> String
    var accessibilityLabel: String = ""

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 18
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel(accessibilityLabel)
        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 40
            tableColumn.resizingMask = column.isFlexible ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(tableColumn)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Copy"), action: #selector(Coordinator.copy(_:)), keyEquivalent: "c").target = context.coordinator
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        table.autoresizingMask = [.width]
        table.sizeLastColumnToFit()
        context.coordinator.table = table
        context.coordinator.parent = self
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: LogTableView?
        weak var table: NSTableView?
        private var revision = -1
        private let monospaced = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        private let proportional = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1)

        func sync() {
            guard let table, let parent, parent.revision != revision else { return }
            revision = parent.revision
            let atBottom = isAtBottom(table)
            table.reloadData()
            if atBottom, parent.rowCount > 0 { table.scrollRowToVisible(parent.rowCount - 1) }
        }

        private func isAtBottom(_ table: NSTableView) -> Bool {
            guard let clip = table.enclosingScrollView?.contentView else { return true }
            return clip.bounds.maxY >= table.bounds.maxY - table.rowHeight * 2
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent?.rowCount ?? 0 }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let parent, let id = tableColumn?.identifier, let column = parent.columns.first(where: { $0.id == id.rawValue }) else { return nil }
            let field = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = id
                field.lineBreakMode = .byTruncatingTail
                field.font = column.isMonospaced ? monospaced : proportional
                field.textColor = column.isSecondary ? .secondaryLabelColor : .labelColor
                return field
            }()
            field.stringValue = row < parent.rowCount ? parent.text(row, column.id) : ""
            return field
        }

        @objc func copy(_ sender: Any?) {
            guard let table, let parent else { return }
            let rows = table.clickedRow >= 0 && !table.selectedRowIndexes.contains(table.clickedRow)
                ? IndexSet(integer: table.clickedRow) : table.selectedRowIndexes
            let text = rows.map { row in parent.columns.map { parent.text(row, $0.id) }.joined(separator: "\t") }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
