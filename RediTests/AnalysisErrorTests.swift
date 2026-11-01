import Foundation
import RediCore
import RedisClient
import RedisWire
import Testing
@testable import Redi

/// A command the server refuses (an ACL denial) must show as an error, not as zero metrics or an
/// empty log.
@MainActor
@Suite(.serialized, .enabled(if: RedisServerFixture.isAvailable))
struct AnalysisErrorTests {
    @Test func deniedInfoAndSlowLogAreReported() async throws {
        let server = try await RedisServerFixture()
        let admin = try await RedisConnection.connect(server.configuration())
        try await admin.execute(RedisCommand("ACL", "SETUSER", "review", "on", ">review", "~*", "&*", "+@all", "-info", "-slowlog"))
        var profile = ConnectionProfile(port: server.port)
        profile.username = "review"
        defer { removeConnectionData(profile) }
        let workspace = WorkspaceModel(profile: profile, secrets: ConnectionSecrets(password: "review"))
        await workspace.connect()
        #expect(workspace.isConnected)

        let overview = workspace.overview
        overview.setVisible(true)
        try await waitUntil { overview.latest != nil || overview.error != nil }
        overview.setVisible(false)
        #expect(overview.error?.contains("NOPERM") == true)
        #expect(overview.latest == nil)

        await workspace.slowLog.load()
        #expect(workspace.slowLog.error?.contains("NOPERM") == true)
        await workspace.disconnect()
        await admin.close()
    }
}
