import AppKit
import Foundation
import RediCore
import RedisClient
import RedisWire
import Testing
@testable import Redi

/// A key editor holds one database's value; after a database switch it must be gone, or saving it
/// writes that value into the newly selected database.
@MainActor
@Suite(.serialized, .enabled(if: RedisServerFixture.isAvailable))
struct DatabaseSwitchTests {
    @Test func switchingDatabasesClosesTheSelectedKeysEditor() async throws {
        let server = try await RedisServerFixture()
        let admin = try await RedisConnection.connect(server.configuration())
        try await admin.execute(RedisCommand("SET", "shared-key", "db0-value"))
        try await admin.execute(RedisCommand("SELECT", 1))
        try await admin.execute(RedisCommand("SET", "shared-key", "db1-value"))
        let profile = ConnectionProfile(port: server.port)
        defer { removeConnectionData(profile) }
        let workspace = WorkspaceModel(profile: profile, secrets: ConnectionSecrets())
        await workspace.connect()
        let browser = workspace.browser
        browser.filterText = "shared-key"
        browser.reload()
        try await waitUntil { !browser.isScanning }
        try #require(browser.index.count == 1)
        browser.select(index: 0)
        let detail = try #require(browser.detail)
        await detail.load()
        let value = try #require(detail.value.string)
        #expect(value.text == "db0-value")

        await workspace.selectDatabase(1)
        #expect(browser.detail == nil, "the db0 editor is closed")
        #expect(try await admin.send(RedisCommand("GET", "shared-key")).string == "db1-value")
        await workspace.disconnect()
        await admin.close()
    }

    /// Add Key shows the new key without selecting an outline row, so a reload of the tree has no
    /// selection to clear. The editor must still close.
    @Test func switchingDatabasesClosesAnEditorShownForANewKey() async throws {
        let server = try await RedisServerFixture()
        let admin = try await RedisConnection.connect(server.configuration(database: 1))
        try await admin.execute(RedisCommand("SET", "new-key", "db1-value"))
        let profile = ConnectionProfile(port: server.port)
        defer { removeConnectionData(profile) }
        let workspace = WorkspaceModel(profile: profile, secrets: ConnectionSecrets())
        await workspace.connect()
        let browser = workspace.browser
        browser.reload()
        try await waitUntil { !browser.isScanning }
        let coordinator = KeyTreeView.Coordinator(model: browser, onDelete: { _ in })
        let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        outline.addTableColumn(NSTableColumn(identifier: .init("key")))
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outline = outline
        coordinator.sync()

        let session = try #require(workspace.session)
        try await KeyOperations(session: session).create(Array("new-key".utf8), value: .string(Array("db0-value".utf8)), ttlSeconds: nil)
        browser.showDetail(forNewKey: Array("new-key".utf8), type: .string)
        coordinator.sync()
        let detail = try #require(browser.detail)
        await detail.load()
        #expect(outline.selectedRow == -1, "precondition: no outline row is selected")

        await workspace.selectDatabase(1)
        try await waitUntil { !browser.isScanning }
        coordinator.sync()
        #expect(browser.detail == nil)
        #expect(try await admin.send(RedisCommand("GET", "new-key")).string == "db1-value")
        await workspace.disconnect()
        await admin.close()
    }
}

/// Run Line must run the line the caret is on, found by position rather than by matching text.
@MainActor
struct CommandEditorCaretTests {
    private func context(_ text: String, caretAt marker: Character = "|") -> CommandEditor.CaretContext {
        let index = text.firstIndex(of: marker)!
        let location = text.utf16.distance(from: text.startIndex, to: index)
        var stripped = text
        stripped.remove(at: index)
        return CommandEditor.caretContext(in: stripped, selection: NSRange(location: location, length: 0))
    }

    @Test func linesWithTheSamePrefixAreNotConfused() {
        let caret = context("DEL important-key\nDEL |intended-key")
        #expect(caret.line == "DEL intended-key")
        #expect(caret.beforeCaret == "DEL ")
    }

    @Test func caretAtColumnZeroStillReportsItsLine() {
        let caret = context("GET a\n|GET b\nGET c")
        #expect(caret.line == "GET b")
        #expect(caret.beforeCaret == "")
    }

    @Test func lastLineWithoutTrailingNewline() {
        #expect(context("GET a\nGET b|").line == "GET b")
    }

    @Test func emptyLastLineAfterTrailingNewline() {
        let caret = context("GET a\n|")
        #expect(caret.line == "")
    }

    @Test func crlfLineEndingsAreTrimmed() {
        #expect(context("GET a\r\nGET |b\r\nGET c").line == "GET b")
    }

    @Test func selectionReportsItsTextAndTheLineWhereItStarts() {
        let text = "GET a\nGET b\nGET c"
        let caret = CommandEditor.caretContext(in: text, selection: NSRange(location: 8, length: 7))
        #expect(caret.selection == "T b\nGET")
        #expect(caret.line == "GET b")
    }

    @Test func outOfRangeSelectionIsClamped() {
        let caret = CommandEditor.caretContext(in: "GET a", selection: NSRange(location: 99, length: 5))
        #expect(caret.line == "GET a")
        #expect(caret.selection == "")
    }
}
