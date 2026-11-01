import Foundation
import RediCore

/// Polls `predicate` on the main actor until it holds or `timeout` passes. Callers `#expect` the
/// condition afterwards, so a timeout fails the test with a useful message instead of hanging.
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
}

/// Removes the per-connection data directory (CLI history, Workbench drafts and results) a test's
/// workspace wrote. Run tests with `TEST_RUNNER_REDI_DATA_DIR` set so nothing lands in the real one.
func removeConnectionData(_ profile: ConnectionProfile) {
    try? FileManager.default.removeItem(at: RediDirectories.connectionData(profile.id))
}
