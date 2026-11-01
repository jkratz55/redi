import Foundation
import RediCore
import RedisClient
import RedisWire
import Testing
@testable import Redi

/// The key list and the detail pane share one delete policy: only a single small key that undo can
/// restore is deleted without asking, and never on a production connection.
@MainActor
struct DeletePolicyTests {
    @Test func smallSingleKeyIsDeletedWithoutAsking() {
        #expect(!BrowserModel.deleteNeedsConfirmation(sizes: [512], undoLimitKB: 1024, isProduction: false))
    }

    @Test func everythingElseIsConfirmed() {
        #expect(BrowserModel.deleteNeedsConfirmation(sizes: [512], undoLimitKB: 1024, isProduction: true), "production")
        #expect(BrowserModel.deleteNeedsConfirmation(sizes: [2 * 1024 * 1024], undoLimitKB: 1024, isProduction: false), "over the undo limit")
        #expect(BrowserModel.deleteNeedsConfirmation(sizes: [512], undoLimitKB: 0, isProduction: false), "undo disabled")
        #expect(BrowserModel.deleteNeedsConfirmation(sizes: [512, 512], undoLimitKB: 1024, isProduction: false), "more than one key")
        #expect(BrowserModel.deleteNeedsConfirmation(sizes: [nil], undoLimitKB: 1024, isProduction: false), "size unknown")
        #expect(BrowserModel.deleteNeedsConfirmation(sizes: [], undoLimitKB: 1024, isProduction: false))
    }

    @Test func undoAvailability() {
        #expect(BrowserModel.canUndoDelete(sizes: [512, 1024 * 1024], undoLimitKB: 1024))
        #expect(!BrowserModel.canUndoDelete(sizes: [512, nil], undoLimitKB: 1024))
        #expect(!BrowserModel.canUndoDelete(sizes: Array(repeating: 1, count: 101), undoLimitKB: 1024))
    }
}

@MainActor
@Suite(.serialized, .enabled(if: RedisServerFixture.isAvailable))
struct DetailDeleteTests {
    private func browse(_ server: RedisServerFixture, keys: [String], isProduction: Bool = false) async throws -> (WorkspaceModel, BrowserModel) {
        let admin = try await RedisConnection.connect(server.configuration())
        for key in keys { try await admin.execute(RedisCommand("SET", key, "value")) }
        await admin.close()
        var profile = ConnectionProfile(port: server.port)
        profile.isProduction = isProduction
        let workspace = WorkspaceModel(profile: profile, secrets: ConnectionSecrets())
        await workspace.connect()
        let browser = workspace.browser
        browser.reload()
        try await waitUntil { !browser.isScanning }
        try #require(browser.index.count == keys.count)
        return (workspace, browser)
    }

    private func row(of key: String, in browser: BrowserModel) throws -> Int {
        try #require((0..<browser.index.count).first { browser.key(at: $0).elementsEqual(Array(key.utf8)) })
    }

    private func loadMetadata(_ browser: BrowserModel) async throws {
        browser.requestMetadata(for: Array(0..<browser.index.count))
        try await waitUntil { (0..<browser.index.count).allSatisfy { browser.metadata(at: $0)?.memory != nil } }
    }

    /// The detail pane can show a key other than the selected row (Add Key for an existing name).
    /// Delete must remove the key on screen, not the selected one.
    @Test func detailDeleteTargetsTheShownKey() async throws {
        let server = try await RedisServerFixture()
        let (workspace, browser) = try await browse(server, keys: ["selected", "shown"])
        defer { removeConnectionData(workspace.profile) }
        browser.select(index: try row(of: "selected", in: browser))
        browser.showDetail(forNewKey: Array("shown".utf8), type: .string)
        let detail = try #require(browser.detail)
        #expect(detail.key == Array("shown".utf8))

        // No sizes loaded yet, so undo can't be promised: the delete is confirmed first.
        let request = try #require(browser.requestDelete(key: detail.key, undoManager: nil))
        #expect(request.keys == [Array("shown".utf8)])
        await browser.confirmDelete(request, undoManager: nil)
        let session = try #require(workspace.session)
        #expect(try await session.send(RedisCommand("EXISTS", "shown")).int == 0)
        #expect(try await session.send(RedisCommand("EXISTS", "selected")).int == 1)
        await workspace.disconnect()
    }

    @Test func smallKeyFromTheDetailPaneIsDeletedWithoutAsking() async throws {
        let server = try await RedisServerFixture()
        let (workspace, browser) = try await browse(server, keys: ["small"])
        defer { removeConnectionData(workspace.profile) }
        try await loadMetadata(browser)
        browser.select(index: 0)
        let detail = try #require(browser.detail)
        #expect(browser.requestDelete(key: detail.key, undoManager: nil) == nil)
        let session = try #require(workspace.session)
        try await waitUntil { browser.detail == nil }
        #expect(try await session.send(RedisCommand("EXISTS", "small")).int == 0)
        await workspace.disconnect()
    }

    @Test func productionDeletesFromTheDetailPaneAreConfirmed() async throws {
        let server = try await RedisServerFixture()
        let (workspace, browser) = try await browse(server, keys: ["prod"], isProduction: true)
        defer { removeConnectionData(workspace.profile) }
        try await loadMetadata(browser)
        browser.select(index: 0)
        let detail = try #require(browser.detail)
        let request = try #require(browser.requestDelete(key: detail.key, undoManager: nil))
        #expect(request.canUndo)
        let session = try #require(workspace.session)
        #expect(try await session.send(RedisCommand("EXISTS", "prod")).int == 1, "nothing deleted before confirming")
        await workspace.disconnect()
    }

    /// A confirmation left open across a database switch must not delete the same name in the new database.
    @Test func confirmationAfterADatabaseSwitchDeletesNothing() async throws {
        let server = try await RedisServerFixture()
        let admin = try await RedisConnection.connect(server.configuration(database: 1))
        try await admin.execute(RedisCommand("SET", "twin", "db1"))
        let (workspace, browser) = try await browse(server, keys: ["twin"])
        defer { removeConnectionData(workspace.profile) }
        let request = try #require(browser.requestDelete(rows: [0], undoManager: nil))
        await workspace.selectDatabase(1)
        await browser.confirmDelete(request, undoManager: nil)
        #expect(try await admin.send(RedisCommand("EXISTS", "twin")).int == 1)
        #expect(workspace.notice != nil)
        await workspace.disconnect()
        await admin.close()
    }
}
