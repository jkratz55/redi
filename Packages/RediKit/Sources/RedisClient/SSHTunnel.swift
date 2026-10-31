import Foundation
import Synchronization

/// An SSH tunnel run by the system `/usr/bin/ssh`, so the user's `~/.ssh/config`, agents
/// (1Password, Secretive, ssh-agent), ProxyJump and FIDO keys all work unchanged.
///
/// One *control master* connection is opened. Each Redis node is then forwarded on demand with
/// `ssh -O forward` to a Unix socket in a private temporary directory, so there are no local-port
/// races, and cluster or sentinel topologies can add nodes without reconnecting.
public final class SSHTunnel: Sendable {
    public enum Authentication: Sendable, Hashable {
        /// Keys from the agent or `~/.ssh/config`. Never prompts.
        case agent
        /// A specific private key file; `secret` is its passphrase, if any.
        case privateKey(path: String)
        /// Password (or keyboard-interactive) authentication; `secret` is the password.
        case password
    }

    public struct Configuration: Sendable, Hashable {
        public var host: String
        public var port: Int
        public var username: String?
        public var authentication: Authentication
        public var secret: String?
        public var connectTimeout: Duration
        public var sshPath: String
        /// Overrides `~/.ssh/known_hosts` (tests use a throwaway file).
        public var knownHostsFile: String?

        public init(host: String, port: Int = 22, username: String? = nil, authentication: Authentication = .agent,
                    secret: String? = nil, connectTimeout: Duration = .seconds(15), sshPath: String = "/usr/bin/ssh",
                    knownHostsFile: String? = nil) {
            self.host = host
            self.port = port
            self.username = username
            self.authentication = authentication
            self.secret = secret
            self.connectTimeout = connectTimeout
            self.sshPath = sshPath
            self.knownHostsFile = knownHostsFile
        }
    }

    public enum Error: Swift.Error, Sendable, Hashable, CustomStringConvertible {
        case launchFailed(String)
        case connectionFailed(String)
        case timedOut
        case forwardFailed(String)
        case closed

        public var description: String {
            switch self {
            case .launchFailed(let reason): "Couldn't start ssh: \(reason)"
            case .connectionFailed(let reason): "SSH connection failed: \(reason)"
            case .timedOut: "SSH connection timed out."
            case .forwardFailed(let reason): "SSH port forwarding failed: \(reason)"
            case .closed: "SSH tunnel is closed."
            }
        }
    }

    private struct State {
        var forwards: [String: String] = [:]
        var nextSocket = 0
        var closed = false
    }

    public let configuration: Configuration
    private let directory: String
    private let controlPath: String
    private let master: ProcessBox
    private let state = Mutex(State())
    private let errorOutput = OutputBuffer()

    /// Opens the control master and waits until it's authenticated.
    public static func open(_ configuration: Configuration) async throws -> SSHTunnel {
        let tunnel = try SSHTunnel(configuration: configuration)
        do {
            try await tunnel.waitUntilReady()
        } catch {
            tunnel.close()
            throw error
        }
        tunnel.discardSecret()
        return tunnel
    }

    private init(configuration: Configuration) throws {
        self.configuration = configuration
        guard FileManager.default.isExecutableFile(atPath: configuration.sshPath) else {
            throw Error.launchFailed("\(configuration.sshPath) not found")
        }
        // Unix socket paths are limited to 104 bytes, so keep the directory name short.
        let random = String(UInt32.random(in: .min ... .max), radix: 36)
        directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("redi-\(random)")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        controlPath = (directory as NSString).appendingPathComponent("ctl")

        var arguments = ["-N", "-M", "-S", controlPath,
                         "-o", "ControlPersist=no",
                         "-o", "ExitOnForwardFailure=yes",
                         "-o", "ServerAliveInterval=30",
                         "-o", "ServerAliveCountMax=3",
                         "-o", "StreamLocalBindUnlink=yes",
                         "-o", "StrictHostKeyChecking=accept-new",
                         "-o", "ConnectTimeout=\(max(1, Int(configuration.connectTimeout.components.seconds)))",
                         "-p", String(configuration.port)]
        if let knownHostsFile = configuration.knownHostsFile {
            arguments += ["-o", "UserKnownHostsFile=\(knownHostsFile)"]
        }
        var environment = ProcessInfo.processInfo.environment

        switch configuration.authentication {
        case .agent:
            arguments += ["-o", "BatchMode=yes"]
        case .privateKey(let path):
            arguments += ["-i", (path as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
            if configuration.secret == nil { arguments += ["-o", "BatchMode=yes"] }
        case .password:
            arguments += ["-o", "PreferredAuthentications=password,keyboard-interactive",
                          "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1"]
        }

        if let secret = configuration.secret, !secret.isEmpty {
            try Self.installAskpass(secret: secret, in: directory, environment: &environment)
        }
        if let username = configuration.username, !username.isEmpty {
            arguments += ["-l", username]
        }
        arguments.append(configuration.host)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.sshPath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        master = ProcessBox(process)

        let errorOutput = self.errorOutput
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            errorOutput.append(String(decoding: data, as: UTF8.self))
        }

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(atPath: directory)
            throw Error.launchFailed(error.localizedDescription)
        }
        Self.registry.withLock { $0[ObjectIdentifier(self)] = WeakTunnel(self) }
    }

    deinit {
        close()
    }

    /// A local Unix-socket endpoint forwarding to `host:port` as seen from the SSH server.
    public func forward(to host: String, port: Int) async throws -> RedisEndpoint {
        let key = "\(host):\(port)"
        let socket: String? = try state.withLock { state in
            if state.closed { throw Error.closed }
            if let existing = state.forwards[key] { return existing }
            return nil
        }
        if let socket { return .unix(path: socket) }

        let path = state.withLock { state -> String in
            state.nextSocket += 1
            return (directory as NSString).appendingPathComponent("f\(state.nextSocket).sock")
        }
        let target = host.contains(":") ? "[\(host)]" : host
        let result = await run(["-S", controlPath, "-O", "forward", "-L", "\(path):\(target):\(port)", configuration.host])
        guard result.status == 0 else {
            throw Error.forwardFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // The master creates the socket synchronously, but allow for a slow filesystem.
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        state.withLock { $0.forwards[key] = path }
        return .unix(path: path)
    }

    /// Whether the master connection is still alive.
    public var isRunning: Bool { master.process.isRunning }

    /// Stops the master (which tears down every forward) and removes the temporary directory.
    public func close() {
        let alreadyClosed = state.withLock { state -> Bool in
            defer { state.closed = true }
            return state.closed
        }
        guard !alreadyClosed else { return }
        discardSecret()
        if master.process.isRunning { master.process.terminate() }
        try? FileManager.default.removeItem(atPath: directory)
        Self.registry.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(self)) }
    }

    /// Terminates every open tunnel. Call on app termination so no `ssh` processes outlive Redi.
    public static func closeAll() {
        let tunnels = registry.withLock { registry in registry.values.compactMap(\.tunnel) }
        for tunnel in tunnels { tunnel.close() }
    }

    // MARK: - Private

    private static let registry = Mutex<[ObjectIdentifier: WeakTunnel]>([:])

    private func waitUntilReady() async throws {
        let deadline = ContinuousClock.now + configuration.connectTimeout + .seconds(2)
        while ContinuousClock.now < deadline {
            if !master.process.isRunning {
                // Give the stderr reader a moment to drain the final message.
                try? await Task.sleep(for: .milliseconds(50))
                throw Error.connectionFailed(Self.summarize(errorOutput.contents))
            }
            if FileManager.default.fileExists(atPath: controlPath) {
                let check = await run(["-S", controlPath, "-O", "check", configuration.host])
                if check.status == 0 { return }
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw Error.timedOut
    }

    /// Runs a short-lived `ssh` control command.
    private func run(_ arguments: [String]) async -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.sshPath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe
        let box = ProcessBox(process)
        return await withCheckedContinuation { continuation in
            box.process.terminationHandler = { finished in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: (finished.terminationStatus, output))
            }
            do {
                try box.process.run()
            } catch {
                box.process.terminationHandler = nil
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }

    /// Hands the secret to ssh through a FIFO read by an askpass script, so it never touches disk
    /// or the process environment.
    private static func installAskpass(secret: String, in directory: String, environment: inout [String: String]) throws {
        let fifo = (directory as NSString).appendingPathComponent("secret")
        let script = (directory as NSString).appendingPathComponent("askpass")
        guard mkfifo(fifo, 0o600) == 0 else { throw Error.launchFailed("mkfifo failed (\(errno))") }
        let body = "#!/bin/sh\nexec /bin/cat '\(fifo)'\n"
        guard FileManager.default.createFile(atPath: script, contents: Data(body.utf8), attributes: [.posixPermissions: 0o700]) else {
            throw Error.launchFailed("couldn't create askpass helper")
        }
        let payload = Array((secret + "\n").utf8)
        Thread.detachNewThread {
            // Blocks until askpass opens the FIFO, or until `discardSecret` opens it to release us.
            let fd = Darwin.open(fifo, O_WRONLY)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            payload.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
            Darwin.close(fd)
        }
        environment["SSH_ASKPASS"] = script
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
    }

    /// Unblocks the FIFO writer (if askpass never ran) and removes the secret plumbing.
    private func discardSecret() {
        let fifo = (directory as NSString).appendingPathComponent("secret")
        guard FileManager.default.fileExists(atPath: fifo) else { return }
        let fd = Darwin.open(fifo, O_RDONLY | O_NONBLOCK)
        if fd >= 0 {
            var scratch = [UInt8](repeating: 0, count: 256)
            usleep(20_000)
            _ = read(fd, &scratch, scratch.count)
            Darwin.close(fd)
        }
        unlink(fifo)
        unlink((directory as NSString).appendingPathComponent("askpass"))
    }

    /// The most useful line of ssh's stderr, e.g. "Permission denied (publickey)".
    static func summarize(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        return lines.last ?? "ssh exited unexpectedly"
    }
}

/// Accumulates the master's stderr from its readability handler.
private final class OutputBuffer: Sendable {
    private let storage = Mutex("")
    func append(_ text: String) { storage.withLock { $0 += text } }
    var contents: String { storage.withLock { $0 } }
}

/// `Process` isn't Sendable; it's only mutated before `run()` and read (thread-safely) afterwards.
private struct ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

private struct WeakTunnel: @unchecked Sendable {
    weak var tunnel: SSHTunnel?
    init(_ tunnel: SSHTunnel) { self.tunnel = tunnel }
}
