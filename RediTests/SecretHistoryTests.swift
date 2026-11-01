import Foundation
import RediCore
import RedisClient
import RedisWire
import Testing
@testable import Redi

/// Commands carrying a password stay out of CLI history and saved Workbench results, as in
/// redis-cli. Run with `TEST_RUNNER_REDI_DATA_DIR` so nothing touches the real data directory.
@MainActor
@Suite(.serialized)
struct SecretHistoryTests {
    private func directory(_ profile: ConnectionProfile) -> URL { RediDirectories.connectionData(profile.id) }

    private func waitForFile(_ url: URL, containing text: String) async throws -> String {
        var contents = ""
        try await waitUntil {
            contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return contents.contains(text)
        }
        return contents
    }

    @Test(.enabled(if: RedisServerFixture.isAvailable))
    func cliDoesNotRememberPasswords() async throws {
        let server = try await RedisServerFixture()
        let profile = ConnectionProfile(port: server.port)
        defer { removeConnectionData(profile) }
        let workspace = WorkspaceModel(profile: profile, secrets: ConnectionSecrets())
        await workspace.connect()
        let cli = workspace.cli
        // ACL SETUSER and CONFIG SET are covered by CommandSafety's tests; these lines finish
        // without a confirmation, so the test can wait for all of them.
        for line in ["AUTH hunter2-auth", "HELLO 3 AUTH default hunter2-hello", "GET after"] {
            cli.input = line
            cli.submit()
        }
        try await waitUntil { cli.entries.count == 3 }
        #expect(cli.entries.map(\.command).last == "GET after")
        let history = try await waitForFile(directory(profile).appending(path: "cli-history.json"), containing: "GET after")
        #expect(!history.contains("hunter2"))
        cli.historyUp()
        #expect(cli.input == "GET after", "not recallable with ↑ either")
        cli.historyUp()
        #expect(cli.input == "GET after")
        await workspace.disconnect()
    }

    @Test func cliScrubsPasswordsSavedByEarlierVersions() async throws {
        let profile = ConnectionProfile(name: "History scrub test")
        defer { removeConnectionData(profile) }
        let url = directory(profile).appending(path: "cli-history.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(["GET a", "AUTH hunter2-old", "GET b"]).write(to: url)

        let workspace = WorkspaceModel(profile: profile, secrets: ConnectionSecrets())
        defer { withExtendedLifetime(workspace) {} }  // models hold their workspace unowned
        let cli = workspace.cli
        try await waitUntil { !((try? String(contentsOf: url, encoding: .utf8)) ?? "hunter2").contains("hunter2") }
        let history = try String(contentsOf: url, encoding: .utf8)
        #expect(!history.contains("hunter2"))
        #expect(history.contains("GET a") && history.contains("GET b"))
        cli.historyUp()
        #expect(cli.input == "GET b")
        cli.historyUp()
        #expect(cli.input == "GET a")
    }

    @Test func workbenchSavedLinesHidePasswords() {
        #expect(WorkbenchModel.savedLine("AUTH hunter2") == "AUTH ••••")
        #expect(WorkbenchModel.savedLine("3 CONFIG SET requirepass hunter2") == "3 CONFIG SET ••••")
        #expect(WorkbenchModel.savedLine("ACL SETUSER bob on >hunter2") == "ACL SETUSER ••••")
        #expect(WorkbenchModel.savedLine("10 INCR counter") == "10 INCR counter")
        #expect(WorkbenchModel.savedLine("GET k") == "GET k")
    }

    @Test(.enabled(if: RedisServerFixture.isAvailable))
    func workbenchResultsHidePasswords() async throws {
        let server = try await RedisServerFixture()
        let profile = ConnectionProfile(port: server.port)
        defer { removeConnectionData(profile) }
        let workspace = WorkspaceModel(profile: profile, secrets: ConnectionSecrets())
        await workspace.connect()
        let workbench = workspace.workbench
        // Refused before it's sent, but the refusal is still a saved result.
        workbench.run("AUTH hunter2-refused")
        try await waitUntil { workbench.results.count == 1 }
        // Run (confirmed) in a batch, so the reply text echoes each command.
        workbench.run("ACL SETUSER bob on >hunter2-acl\nACL WHOAMI", confirmed: true)
        try await waitUntil { workbench.results.count == 2 }
        #expect(workbench.results[0].commands == ["ACL SETUSER ••••", "ACL WHOAMI"])
        #expect(workbench.results[0].text.contains("> ACL SETUSER ••••"))
        #expect(workbench.results[1].commands == ["AUTH ••••"])
        let saved = try await waitForFile(directory(profile).appending(path: "workbench-results.json"), containing: "WHOAMI")
        #expect(!saved.contains("hunter2"))
        await workspace.disconnect()
    }

    @Test func workbenchScrubsResultsSavedByEarlierVersions() async throws {
        let profile = ConnectionProfile(name: "Workbench scrub test")
        defer { removeConnectionData(profile) }
        let url = directory(profile).appending(path: "workbench-results.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = WorkbenchModel.Result(commands: ["AUTH hunter2-old", "GET k"], durationMilliseconds: 1,
                                        text: "> AUTH hunter2-old\nOK\n\n> GET k\n\"v\"", isError: false)
        try JSONEncoder().encode([old]).write(to: url)

        let workspace = WorkspaceModel(profile: profile, secrets: ConnectionSecrets())
        defer { withExtendedLifetime(workspace) {} }  // models hold their workspace unowned
        let workbench = workspace.workbench
        #expect(workbench.results.first?.commands == ["AUTH ••••", "GET k"])
        #expect(workbench.results.first?.text == "> AUTH ••••\nOK\n\n> GET k\n\"v\"")
        try await waitUntil { !((try? String(contentsOf: url, encoding: .utf8)) ?? "hunter2").contains("hunter2") }
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("hunter2"))
    }
}
