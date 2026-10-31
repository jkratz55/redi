import Foundation
import RedisClient

/// Launches a throwaway local `redis-server` on a free port for integration tests.
///
/// The binary is taken from `REDI_REDIS_SERVER`, or the usual Homebrew locations. Tests should be
/// gated with `.enabled(if: RedisServerFixture.isAvailable)`.
public final class RedisServerFixture: @unchecked Sendable {
    // Process isn't Sendable; this class only touches it in init/stop/deinit.
    private let process = Process()
    /// Signalled from `terminationHandler`. `Process.waitUntilExit()` spins the current run loop
    /// and can hang forever on Swift concurrency's cooperative threads, so it isn't used.
    private let exited = DispatchSemaphore(value: 0)
    public let port: Int

    public static var serverPath: String? {
        let candidates = [ProcessInfo.processInfo.environment["REDI_REDIS_SERVER"],
                          "/opt/homebrew/bin/redis-server",
                          "/usr/local/bin/redis-server"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static var isAvailable: Bool { serverPath != nil }

    /// - Parameter arguments: Extra `redis-server` arguments, e.g. `["--requirepass", "secret"]`.
    public init(arguments: [String] = []) async throws {
        guard let path = Self.serverPath else { throw FixtureError.serverNotFound }
        port = try Self.freePort()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--port", String(port), "--bind", "127.0.0.1", "--save", "", "--appendonly", "no",
                             "--protected-mode", "no", "--daemonize", "no", "--loglevel", "warning"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = self.exited
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let deadline = ContinuousClock.now + .seconds(5)
        while !Self.canConnect(port: port) {
            guard ContinuousClock.now < deadline, process.isRunning else {
                stop()
                throw FixtureError.serverDidNotStart
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    public var endpoint: RedisEndpoint { .tcp(host: "127.0.0.1", port: port) }

    public func configuration(username: String? = nil, password: String? = nil, database: Int = 0) -> RedisConnectionConfiguration {
        RedisConnectionConfiguration(endpoint: endpoint, username: username, password: password,
                                     database: database, connectTimeout: .seconds(3))
    }

    public func stop() {
        guard process.isRunning else { return }
        process.terminate()
        if exited.wait(timeout: .now() + 3) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
        }
        // Let other waiters (deinit after an explicit stop) pass straight through.
        exited.signal()
    }

    deinit { stop() }

    public enum FixtureError: Error { case serverNotFound, serverDidNotStart, noFreePort }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FixtureError.noFreePort }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw FixtureError.noFreePort }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
