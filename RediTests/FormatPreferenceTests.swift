import Foundation
import RediCore
import RedisClient
import RedisWire
import Testing
@testable import Redi

/// A format the user picks stays as they move between keys; Automatic detects one per key.
@MainActor
struct FormatPreferenceTests {
    /// `{"sku": "A-1", "qty": 2}` as MessagePack.
    private static let item: [UInt8] = [0x82, 0xA3, 0x73, 0x6B, 0x75, 0xA3, 0x41, 0x2D, 0x31, 0xA3, 0x71, 0x74, 0x79, 0x02]

    private func pager(_ values: [[UInt8]], _ preference: FormatPreference) -> CollectionPager<ListEntry> {
        CollectionPager(supportsSearch: false, formatPreference: preference, report: { _ in }, formattedValues: { [$0.value] }) { _, _ in
            ValuePage(elements: values.enumerated().map { ListEntry(index: $0.offset, value: $0.element) }, next: nil)
        }
    }

    @Test func aPickedFormatCarriesToTheNextKey() async {
        let preference = FormatPreference()
        let first = pager([Self.item], preference)
        await first.reload()
        #expect(first.format == .messagePack && first.formatChoice == nil, "detected while Automatic")

        first.formatChoice = .hex
        #expect(first.format == .hex)
        let next = pager([Self.item], preference)
        await next.reload()
        #expect(next.format == .hex, "the pick overrides detection")
        #expect(next.detectedFormat == .messagePack, "while the picker can still name what Automatic would show")
    }

    @Test func automaticGoesBackToDetecting() async {
        let preference = FormatPreference()
        preference.choice = .hex
        let current = pager([Self.item], preference)
        await current.reload()
        current.formatChoice = nil
        #expect(current.format == .messagePack)
        let next = pager([Array("plain".utf8)], preference)
        await next.reload()
        #expect(next.format == .text)
    }

    @Test func automaticBeforeTheFirstPageStillDetects() async {
        let preference = FormatPreference()
        preference.choice = .hex
        let pager = pager([Self.item], preference)
        pager.formatChoice = nil
        await pager.reload()
        #expect(pager.format == .messagePack)
    }
}

/// The same through the key browser, against a real server: strings and a hash share the window's pick.
@MainActor
@Suite(.serialized, .enabled(if: RedisServerFixture.isAvailable))
struct FormatPreferenceBrowserTests {
    @Test func thePickFollowsTheUserAcrossKeysAndTypes() async throws {
        let server = try await RedisServerFixture()
        let admin = try await RedisConnection.connect(server.configuration())
        try await admin.execute(RedisCommand("SET", "json", #"{"a": 1}"#))
        try await admin.execute(RedisCommand("SET", "text", "hello"))
        try await admin.execute(RedisCommand("HSET", "hash", "f", "v"))
        let profile = ConnectionProfile(port: server.port)
        defer { removeConnectionData(profile) }
        let workspace = WorkspaceModel(profile: profile, secrets: ConnectionSecrets())
        defer { withExtendedLifetime(workspace) {} }
        await workspace.connect()
        let browser = workspace.browser
        browser.reload()
        try await waitUntil { !browser.isScanning && browser.index.count == 3 }

        func show(_ key: String) async throws -> KeyDetailModel.Value {
            let index = try #require((0..<browser.index.count).first { String(decoding: browser.index.key(at: $0), as: UTF8.self) == key })
            browser.select(index: index)
            let detail = try #require(browser.detail)
            await detail.load()
            return detail.value
        }

        let json = try #require(try await show("json").string)
        #expect(json.format == .json, "Automatic")
        json.formatChoice = .hex

        let text = try #require(try await show("text").string)
        #expect(text.format == .hex)
        #expect(text.detectedFormat == .text)
        let hash = try #require(try await show("hash").hash)
        #expect(hash.pager.format == .hex, "strings and collections share the pick")

        hash.pager.formatChoice = nil
        #expect(hash.pager.format == .text)
        #expect(try #require(try await show("json").string).format == .json, "Automatic again")

        await workspace.disconnect()
        await admin.close()
    }
}
