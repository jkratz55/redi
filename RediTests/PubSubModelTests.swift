import Foundation
import RediCore
import RedisClient
import RedisWire
import Testing
@testable import Redi

@MainActor
@Suite(.serialized, .enabled(if: RedisServerFixture.isAvailable))
struct PubSubModelTests {
    /// Unsubscribing ends the old listener's event stream, so subscribing again must start a new one.
    @Test func resubscribingAfterUnsubscribeDeliversMessagesAgain() async throws {
        let server = try await RedisServerFixture()
        let profile = ConnectionProfile(port: server.port)
        defer { removeConnectionData(profile) }
        let workspace = WorkspaceModel(profile: profile, secrets: ConnectionSecrets())
        await workspace.connect()
        let session = try #require(workspace.session)
        let model = workspace.pubSub
        model.subscriptionText = "news"

        await model.subscribe()
        try await waitUntil { model.status == String(localized: "Subscribed (1)") }
        _ = try await session.execute(RedisCommand("PUBLISH", "news", "first"))
        try await waitUntil { model.totalReceived == 1 }
        #expect(model.totalReceived == 1)

        await model.unsubscribe()
        #expect(!model.isSubscribed)
        await model.subscribe()
        try await waitUntil { model.status == String(localized: "Subscribed (1)") }
        #expect(try await session.execute(RedisCommand("PUBLISH", "news", "second")).int == 1)
        try await waitUntil { model.totalReceived == 2 }
        #expect(model.totalReceived == 2)
        await workspace.disconnect()
    }

    @Test func refusedSubscriptionIsReportedAndCanBeRetried() async throws {
        let server = try await RedisServerFixture()
        let admin = try await RedisConnection.connect(server.configuration())
        try await admin.execute(RedisCommand("ACL", "SETUSER", "review", "on", ">review", "~*", "&*", "+@all", "-subscribe"))
        var profile = ConnectionProfile(port: server.port)
        profile.username = "review"
        defer { removeConnectionData(profile) }
        let workspace = WorkspaceModel(profile: profile, secrets: ConnectionSecrets(password: "review"))
        await workspace.connect()
        let model = workspace.pubSub
        model.subscriptionText = "news"

        await model.subscribe()
        #expect(model.status == String(localized: "Subscribing…"), "not reported as subscribed before the server confirms")
        try await waitUntil { !model.isSubscribed }
        #expect(!model.isSubscribed)
        #expect(model.status?.contains("NOPERM") == true)

        try await admin.execute(RedisCommand("ACL", "SETUSER", "review", "+subscribe"))
        await model.subscribe()
        try await waitUntil { model.status == String(localized: "Subscribed (1)") }
        #expect(model.isSubscribed)
        #expect(try await admin.send(RedisCommand("PUBLISH", "news", "hello")).int == 1)
        try await waitUntil { model.totalReceived == 1 }
        #expect(model.totalReceived == 1)
        await workspace.disconnect()
        await admin.close()
    }
}
