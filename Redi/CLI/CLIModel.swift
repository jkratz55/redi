import Foundation
import Observation
import RediCore
import RedisClient
import RedisWire

/// The interactive console. Runs on its own connection (`.cli`) so MULTI, blocking commands or
/// CLIENT settings typed here never affect the rest of the window.
@Observable
final class CLIModel {
    struct Entry: Identifiable, Equatable {
        enum Kind { case output, error, info }
        let id = UUID()
        var prompt: String
        var command: String
        var output: String
        var kind: Kind
        var duration: Duration?
    }

    struct Confirmation: Identifiable {
        let id = UUID()
        let line: String
        let title: String
        let message: String
        let isDestructive: Bool
    }

    private(set) var entries: [Entry] = []
    var input = "" {
        didSet { if !isApplyingCompletion { completionState = nil } }
    }
    private(set) var isRunning = false
    var target: RedisSession.Target = .automatic
    var confirmation: Confirmation?

    @ObservationIgnored private unowned let workspace: WorkspaceModel
    @ObservationIgnored private var history: [String] = []
    @ObservationIgnored private var historyIndex: Int?
    @ObservationIgnored private var draft = ""
    @ObservationIgnored private var runningTask: Task<Void, Never>?
    @ObservationIgnored private var completionState: (base: String, candidates: [String], index: Int)?
    @ObservationIgnored private var isApplyingCompletion = false

    private static let maxEntries = 500
    private static let maxHistory = 500

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        let saved = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: historyURL))) ?? []
        history = saved.filter { !CommandSafety.isSensitive(line: $0) }
        // Earlier versions saved password-bearing lines; rewrite the file without them.
        if history.count != saved.count { saveHistory() }
    }

    private var historyURL: URL {
        RediDirectories.connectionData(workspace.profile.id).appending(path: "cli-history.json")
    }

    var prompt: String {
        var prompt = workspace.primaryAddress
        if !workspace.isCluster, workspace.database != 0 { prompt += "[\(workspace.database)]" }
        if case .node(let node) = target { prompt = node.description }
        return prompt + ">"
    }

    var hint: String? {
        guard !input.isEmpty, completionState == nil else { return nil }
        return workspace.commandCatalog.hint(for: input)
    }

    // MARK: - Running commands

    func submit() {
        let line = input.trimmingCharacters(in: .whitespaces)
        input = ""
        historyIndex = nil
        guard !line.isEmpty else { return }
        // Like redis-cli, lines carrying a password are never added to history, in memory or on disk.
        if !CommandSafety.isSensitive(line: line) { remember(line) }
        run(line, confirmed: false)
    }

    func run(_ line: String, confirmed: Bool) {
        let prompt = self.prompt
        let arguments: [[UInt8]]
        do {
            arguments = try CommandLineParser.split(line)
        } catch {
            append(Entry(prompt: prompt, command: line, output: error.description, kind: .error))
            return
        }
        guard let first = arguments.first else { return }
        let name = String(decoding: first, as: UTF8.self).lowercased()
        if let command = CommandSafety.connectionCommand(arguments) {
            append(Entry(prompt: prompt, command: line, output: Self.unavailableMessage(for: command), kind: .info))
            return
        }

        switch name {
        case "clear":
            entries.removeAll()
            return
        case "help":
            append(Entry(prompt: prompt, command: line, output: help(for: arguments.dropFirst().map { String(decoding: $0, as: UTF8.self) }), kind: .info))
            return
        case "select" where arguments.count == 2:
            guard let index = Int(String(decoding: arguments[1], as: UTF8.self)) else { break }
            Task {
                do {
                    try await workspace.switchDatabase(index)
                    append(Entry(prompt: prompt, command: line, output: "OK", kind: .output))
                } catch {
                    append(Entry(prompt: prompt, command: line, output: "(error) \(error)", kind: .error))
                }
            }
            return
        default:
            break
        }

        Task {
            let table = (try? await workspace.session?.commandTable()) ?? .empty
            switch CommandSafety.classify(arguments, table: table) {
            case .streaming(.pubSub):
                append(Entry(prompt: prompt, command: line, output: String(localized: "Subscriptions stream messages continuously. Use Pub/Sub in the sidebar (⌘2) to subscribe."), kind: .info))
                return
            case .streaming(.monitor):
                append(Entry(prompt: prompt, command: line, output: String(localized: "MONITOR streams every command. Use the Profiler tab in this panel instead."), kind: .info))
                return
            case .destructive(let reason) where !confirmed && confirmsDangerousCommands:
                confirmation = Confirmation(line: line, title: String(localized: "Run \(name.uppercased())?"), message: reason, isDestructive: true)
                return
            case .expensive(let reason) where !confirmed && confirmsDangerousCommands:
                confirmation = Confirmation(line: line, title: String(localized: "Run \(name.uppercased())?"), message: reason, isDestructive: false)
                return
            default:
                break
            }
            execute(arguments, line: line, prompt: prompt)
        }
    }

    /// Why a `CommandSafety.connectionCommand` isn't run, shared with the Workbench.
    static func unavailableMessage(for command: String) -> String {
        String(localized: "\(command) isn't available here: Redi sets up each connection's login, protocol and replies from the connection settings.")
    }

    private var confirmsDangerousCommands: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.confirmDangerousCommands) as? Bool ?? true
    }

    private func execute(_ arguments: [[UInt8]], line: String, prompt: String) {
        guard let session = workspace.session else { return }
        isRunning = true
        let target = self.target
        runningTask = Task {
            defer { isRunning = false }
            let clock = ContinuousClock()
            let started = clock.now
            do {
                let reply = try await session.send(RedisCommand(arguments: arguments), role: .cli, target: target)
                append(Entry(prompt: prompt, command: line, output: ReplyFormatter.cliText(reply),
                             kind: reply.serverError == nil ? .output : .error, duration: clock.now - started))
            } catch is CancellationError {
                append(Entry(prompt: prompt, command: line, output: String(localized: "(cancelled)"), kind: .info))
            } catch {
                append(Entry(prompt: prompt, command: line, output: "(error) \(error)", kind: .error))
            }
        }
    }

    /// Stops a blocking command by closing the CLI's connection (the next command reconnects).
    func cancel() {
        runningTask?.cancel()
        Task { await workspace.session?.release(.cli) }
    }

    func clear() {
        entries.removeAll()
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    private func help(for words: [String]) -> String {
        let catalog = workspace.commandCatalog
        if words.isEmpty {
            return String(localized: "Type a command and press Return. ↑/↓ browse history, Tab completes, “help <command>” shows its syntax, “clear” clears the console. The Command Helper tab lists every command.")
        }
        guard let doc = catalog.doc(for: words) else { return String(localized: "No documentation for “\(words.joined(separator: " "))”.") }
        var lines = ["  \(doc.synopsis)", "  summary: \(doc.summary)"]
        if let since = doc.since { lines.append("  since: \(since)") }
        if let group = doc.group { lines.append("  group: \(group)") }
        if let complexity = doc.complexity { lines.append("  complexity: \(complexity)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - History

    private func remember(_ line: String) {
        if history.last != line { history.append(line) }
        if history.count > Self.maxHistory { history.removeFirst(history.count - Self.maxHistory) }
        saveHistory()
    }

    private func saveHistory() {
        let history = self.history
        let url = historyURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(history).write(to: url, options: .atomic)
        }
    }

    func historyUp() {
        guard !history.isEmpty else { return }
        if historyIndex == nil {
            draft = input
            historyIndex = history.count - 1
        } else if let index = historyIndex, index > 0 {
            historyIndex = index - 1
        }
        input = history[historyIndex ?? 0]
    }

    func historyDown() {
        guard let index = historyIndex else { return }
        if index + 1 < history.count {
            historyIndex = index + 1
            input = history[index + 1]
        } else {
            historyIndex = nil
            input = draft
        }
    }

    // MARK: - Completion

    /// Tab completes the current word; pressing Tab again cycles through the alternatives.
    func complete() {
        if var state = completionState {
            state.index = (state.index + 1) % state.candidates.count
            completionState = state
            apply(base: state.base, word: state.candidates[state.index])
            return
        }
        let candidates = workspace.commandCatalog.completions(for: input)
        guard !candidates.isEmpty else { return }
        var base = input
        if base.last != " ", let space = base.lastIndex(of: " ") {
            base = String(base[...space])
        } else if base.last != " " {
            base = ""
        }
        completionState = (base, candidates, 0)
        apply(base: base, word: candidates[0])
    }

    private func apply(base: String, word: String) {
        isApplyingCompletion = true
        input = base + word + " "
        isApplyingCompletion = false
    }

    func insert(_ text: String) {
        input = text
    }
}
