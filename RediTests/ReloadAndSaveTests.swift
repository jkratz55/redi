import Foundation
import RediCore
import RedisWire
import Testing
@testable import Redi

@MainActor
struct CollectionPagerReloadTests {
    @Test func reloadSupersedesALoadInFlight() async {
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        let pager = CollectionPager<ListEntry>(supportsSearch: true, report: { _ in }, formattedValues: { [$0.value] }) { _, pattern in
            calls += 1
            if calls == 1 { await withCheckedContinuation { release = $0 } }
            // The old, unfiltered load would leave more to fetch; the search finds everything at once.
            return ValuePage(elements: [ListEntry(index: 0, value: Array((pattern ?? "old").utf8))], next: pattern == nil ? "5" : nil)
        }
        let first = Task { await pager.loadMore() }
        while release == nil { await Task.yield() }

        pager.search = "new"
        await pager.reload()
        #expect(calls == 2, "the reload fetches instead of waiting for the old load")
        #expect(pager.elements.map(\.value) == [Array("*new*".utf8)])

        release?.resume()
        await first.value
        #expect(pager.elements.map(\.value) == [Array("*new*".utf8)], "the old page is dropped")
        #expect(pager.next == nil)
        #expect(!pager.isLoading)
    }

    @Test func supersededFailureIsIgnored() async {
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        var reported: [String] = []
        let pager = CollectionPager<ListEntry>(supportsSearch: false, report: { reported.append(String(describing: $0)) },
                                               formattedValues: { [$0.value] }) { _, _ in
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { release = $0 }
                throw RedisServerError("ERR old load failed")
            }
            return ValuePage(elements: [ListEntry(index: 0, value: [1])], next: "200")
        }
        let first = Task { await pager.loadMore() }
        while release == nil { await Task.yield() }
        await pager.reload()
        release?.resume()
        await first.value
        #expect(reported.isEmpty)
        #expect(pager.elements.count == 1 && pager.next == "200")
    }
}

@MainActor
struct WorkbenchPreflightTests {
    private func preflight(_ lines: String..., confirmed: Bool = false, confirms: Bool = true) throws -> WorkbenchModel.Preflight {
        WorkbenchModel.preflight(try lines.map(CommandLineParser.split), table: .empty, confirmed: confirmed, confirmsDangerousCommands: confirms)
    }

    private func isRejected(_ preflight: WorkbenchModel.Preflight) -> Bool {
        if case .reject = preflight { true } else { false }
    }

    @Test func streamingIsRejectedWhateverTheConfirmationSetting() throws {
        for confirms in [true, false] {
            for confirmed in [true, false] {
                #expect(isRejected(try preflight("SUBSCRIBE ch", confirmed: confirmed, confirms: confirms)))
                #expect(isRejected(try preflight("GET k", "MONITOR", confirmed: confirmed, confirms: confirms)))
                #expect(isRejected(try preflight("UNSUBSCRIBE", confirmed: confirmed, confirms: confirms)))
            }
        }
        // Confirming a destructive command doesn't wave through a stream later in the batch.
        #expect(isRejected(try preflight("FLUSHDB", "SUBSCRIBE ch", confirmed: true)))
    }

    @Test func confirmationCoversOnlyDangerousCommands() throws {
        #expect(try preflight("GET k", "FLUSHDB") == .confirm(title: "Run FLUSHDB?", message: "Deletes every key in the current database."))
        #expect(try preflight("GET k", "FLUSHDB", confirmed: true) == .run)
        #expect(try preflight("GET k", "FLUSHDB", confirms: false) == .run)
        #expect(try preflight("GET k", "SET k v") == .run)
    }

    /// SELECT on the Workbench's own connection would leave the toolbar and browser in another
    /// database; a lone SELECT switches the window instead, and SELECT inside a batch is refused.
    @Test func selectSwitchesTheWindowOrIsRejected() throws {
        #expect(try preflight("SELECT 3") == .selectDatabase(3))
        #expect(try preflight("select 0", confirmed: true) == .selectDatabase(0))
        #expect(isRejected(try preflight("SELECT 1", "SET k v")))
        #expect(isRejected(try preflight("MULTI", "SELECT 1", "EXEC")))
        #expect(isRejected(try preflight("SELECT 1", "SELECT 1")), "a repeated SELECT (2 SELECT 1) is a batch too")
        // Malformed: the server answers with its own error and switches nothing.
        #expect(try preflight("SELECT one") == .run)
    }

    @Test func connectionCommandsAreRejectedWhateverTheConfirmationSetting() throws {
        for confirmed in [true, false] {
            for line in ["AUTH secret", "auth user secret", "HELLO 2", "RESET", "QUIT", "CLIENT REPLY OFF", "client reply skip"] {
                #expect(isRejected(try preflight(line, confirmed: confirmed)), "\(line)")
                #expect(isRejected(try preflight("GET k", line, confirmed: confirmed)), "\(line) in a batch")
            }
        }
        #expect(try preflight("CLIENT LIST") == .run)
        #expect(try preflight("CLIENT SETNAME me") == .run)
    }
}

/// Stores secrets in memory; `failNextWrite` makes one write store only the password and then
/// fail, like the Keychain store failing partway through its per-secret items.
private nonisolated final class FlakySecretStore: SecretStore, @unchecked Sendable {
    struct Failure: Error {}
    var stored: [UUID: ConnectionSecrets] = [:]
    var failNextWrite = false

    func secrets(for profileID: UUID) throws -> ConnectionSecrets { stored[profileID] ?? ConnectionSecrets() }

    func setSecrets(_ secrets: ConnectionSecrets, for profileID: UUID) throws {
        if failNextWrite {
            failNextWrite = false
            stored[profileID, default: ConnectionSecrets()].password = secrets.password
            throw Failure()
        }
        stored[profileID] = secrets
    }

    func deleteSecrets(for profileID: UUID) throws { stored[profileID] = nil }
}

@MainActor
struct ConnectionStoreSaveTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "redi-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func failedSecretWriteChangesNothing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ProfileRepository(fileURL: directory.appending(path: "connections.json"))
        let secrets = FlakySecretStore()
        let store = ConnectionStore(repository: repository, secretStore: secrets)

        var profile = ConnectionProfile(name: "original")
        try store.save(profile, secrets: ConnectionSecrets(password: "old", sshSecret: "old-ssh"))

        profile.name = "renamed"
        secrets.failNextWrite = true
        #expect(throws: ConnectionStore.SaveError.self) {
            try store.save(profile, secrets: ConnectionSecrets(password: "new", sshSecret: "new-ssh"))
        }
        #expect(store.profiles.map(\.name) == ["original"])
        #expect(secrets.stored[profile.id] == ConnectionSecrets(password: "old", sshSecret: "old-ssh"), "the partial write is undone")
        #expect(try repository.load().map(\.name) == ["original"])

        // Duplicating hits the same failure: no copy, and the error is shown in the window.
        secrets.failNextWrite = true
        #expect(store.duplicate(id: profile.id) == nil)
        #expect(store.profiles.count == 1 && store.lastError != nil)
        #expect(secrets.stored.values.filter { $0 != ConnectionSecrets() }.count == 1, "the copy's partly written secrets are removed")
    }

    @Test func failedProfileWriteChangesNothing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A file where the repository needs a directory, so every save fails.
        let blocker = directory.appending(path: "blocker")
        try Data().write(to: blocker)
        let secrets = FlakySecretStore()
        let store = ConnectionStore(repository: ProfileRepository(fileURL: blocker.appending(path: "connections.json")), secretStore: secrets)

        let profile = ConnectionProfile(name: "new")
        #expect(throws: ConnectionStore.SaveError.self) { try store.save(profile, secrets: ConnectionSecrets(password: "pw")) }
        #expect(store.profiles.isEmpty)
        #expect(secrets.stored[profile.id] == ConnectionSecrets(), "secrets for a profile that wasn't saved are removed")
    }
}
