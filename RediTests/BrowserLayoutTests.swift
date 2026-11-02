import AppKit
import Foundation
import RediCore
import RedisClient
import RedisWire
import SwiftUI
import Testing
@testable import Redi

/// Each key gets a new editor; the layout the user set around it must survive moving to another key.
@MainActor
@Suite(.serialized, .enabled(if: RedisServerFixture.isAvailable))
struct BrowserLayoutTests {
    @MainActor private struct Window {
        let window: NSWindow
        let browser: BrowserModel
        let workspace: WorkspaceModel

        var split: NSSplitView? { views(NSSplitView.self).first { $0.isVertical } }
        var keyPaneWidth: CGFloat? { split?.arrangedSubviews.first?.frame.width }
        /// The value table's column widths by title (the key list is an `NSOutlineView` too, so it's found by title).
        func table(_ title: String) -> NSTableView? {
            views(NSTableView.self).first { $0.tableColumns.contains { $0.title == title } }
        }
        func columnWidths(_ title: String) -> [String: CGFloat]? {
            table(title).map { Dictionary(uniqueKeysWithValues: $0.tableColumns.map { ($0.title, $0.width) }) }
        }
        func column(_ title: String) -> NSTableColumn? {
            views(NSTableView.self).lazy.compactMap { $0.tableColumns.first { $0.title == title } }.first
        }

        func show(_ key: String) async throws {
            let index = try #require((0..<browser.index.count).first { String(decoding: browser.index.key(at: $0), as: UTF8.self) == key })
            browser.select(index: index)
            try await waitUntil { browser.detail.map { String(decoding: $0.key, as: UTF8.self) } == key }
            await browser.detail?.load()
            try await settle()
        }

        func settle() async throws {
            for _ in 0..<5 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
        }

        private func views<T: NSView>(_ type: T.Type) -> [T] {
            func walk(_ view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap(walk) }
            return window.contentView.map(walk) ?? []
        }
    }

    private func open(_ server: RedisServerFixture, keys: Int) async throws -> Window {
        let profile = ConnectionProfile(port: server.port)
        let workspace = WorkspaceModel(profile: profile, secrets: ConnectionSecrets())
        await workspace.connect()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserView(model: workspace.browser))
        let browser = workspace.browser
        browser.reload()
        try await waitUntil { !browser.isScanning && browser.index.count == keys }
        try #require(browser.index.count == keys)
        let result = Window(window: window, browser: browser, workspace: workspace)
        try await result.settle()
        return result
    }

    @Test func dividerStaysWhereTheUserPutIt() async throws {
        let server = try await RedisServerFixture()
        let admin = try await RedisConnection.connect(server.configuration())
        try await admin.execute(RedisCommand("HSET", "hash", "f", "v"))
        try await admin.execute(RedisCommand("SET", "string", "x"))
        let w = try await open(server, keys: 2)
        defer { removeConnectionData(w.workspace.profile) }

        try await w.show("hash")
        let split = try #require(w.split)
        split.setPosition(700, ofDividerAt: 0)
        try await w.settle()
        #expect(w.keyPaneWidth == 700)

        try await w.show("string")
        #expect(w.keyPaneWidth == 700, "a key of another type keeps the divider")
        w.browser.select(index: nil)
        try await w.settle()
        #expect(w.keyPaneWidth == 700, "so does clearing the selection")
        try await w.show("hash")
        #expect(w.keyPaneWidth == 700)

        w.window.close()
        await w.workspace.disconnect()
        await admin.close()
    }

    @Test func resizedValueColumnsCarryOverToTheNextKey() async throws {
        let server = try await RedisServerFixture()
        let admin = try await RedisConnection.connect(server.configuration())
        try await admin.execute(RedisCommand("HSET", "first", "f", "v"))
        try await admin.execute(RedisCommand("HSET", "second", "f", "v"))
        try await admin.execute(RedisCommand("RPUSH", "list", "a"))
        let w = try await open(server, keys: 3)
        defer { removeConnectionData(w.workspace.profile) }

        try await w.show("first")
        let before = try #require(w.columnWidths("Field"))
        try #require(w.column("Field")).width = (before["Field"] ?? 0) + 80
        try await w.settle()
        let resized = try #require(w.columnWidths("Field"))
        try #require(resized != before)

        try await w.show("second")
        #expect(w.columnWidths("Field") == resized)

        // Other value types keep their own widths, and the hash's survive a visit to them.
        try await w.show("list")
        let listColumns = try #require(w.columnWidths("Element"))
        try #require(w.column("Index")).width = (listColumns["Index"] ?? 0) + 40
        try await w.settle()
        let resizedList = try #require(w.columnWidths("Element"))
        try await w.show("first")
        #expect(w.columnWidths("Field") == resized)
        try await w.show("list")
        #expect(w.columnWidths("Element") == resizedList)

        w.window.close()
        await w.workspace.disconnect()
        await admin.close()
    }
}
