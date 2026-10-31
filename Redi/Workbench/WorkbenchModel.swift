import Foundation
import Observation
import RediCore
import RedisClient
import RedisWire

/// Multi-line command editor with a history of result cards. Runs on its own connection.
@Observable
final class WorkbenchModel {
    struct Result: Identifiable, Codable, Hashable {
        var id = UUID()
        var commands: [String]
        var date = Date()
        var durationMilliseconds: Double
        var node: String?
        /// `redis-cli`-style text of every reply.
        var text: String
        var isError: Bool
        /// Structured view of the last reply, when it's tabular.
        var table: ResultTable?
        /// Pretty JSON, when the last reply is a JSON document (e.g. JSON.GET).
        var json: String?
        var isCollapsed = false
    }

    struct ResultTable: Codable, Hashable {
        var columns: [String]
        var rows: [[String]]
    }

    var text: String {
        didSet { scheduleDraftSave() }
    }
    private(set) var results: [Result] = []
    private(set) var isRunning = false
    var usesPipeline = false
    var target: RedisSession.Target = .automatic
    var confirmation: CLIModel.Confirmation?

    @ObservationIgnored private unowned let workspace: WorkspaceModel
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var runTask: Task<Void, Never>?

    private static let maxResults = 100
    private static let maxResultText = 200_000

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        let directory = RediDirectories.connectionData(workspace.profile.id)
        text = (try? String(contentsOf: directory.appending(path: "workbench.txt"), encoding: .utf8))
            ?? "// Run with ⌘↩ (selection or everything) or ⇧⌘↩ (current line).\n// Prefix a command with a number to repeat it, e.g. 10 INCR counter\nINFO server\n"
        results = (try? JSONDecoder().decode([Result].self, from: Data(contentsOf: directory.appending(path: "workbench-results.json")))) ?? []
    }

    var catalog: CommandCatalog { workspace.commandCatalog }

    // MARK: - Running

    /// Parses runnable lines: blank lines and `//` / `#` comments are skipped; a leading number repeats.
    static func commands(in text: String) -> [(line: String, repeat: Int)] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("//"), !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, let count = Int(parts[0]), count > 0 {
                return (String(parts[1]), min(count, 10_000))
            }
            return (line, 1)
        }
    }

    enum Preflight: Equatable {
        case run
        case confirm(title: String, message: String)
        case reject(String)
    }

    /// Decides whether a batch runs. Streaming commands are always rejected: their replies arrive
    /// as pushes (or never stop), which the request/reply connection can't pair with commands.
    /// The confirmation setting, and confirming once, only cover the destructive/expensive prompt.
    static func preflight(_ batch: [[[UInt8]]], table: CommandTable, confirmed: Bool, confirmsDangerousCommands: Bool) -> Preflight {
        let classifications = batch.map { CommandSafety.classify($0, table: table) }
        if classifications.contains(where: { if case .streaming = $0 { true } else { false } }) {
            return .reject(String(localized: "SUBSCRIBE and MONITOR stream continuously; use Pub/Sub or the Profiler."))
        }
        guard !confirmed, confirmsDangerousCommands else { return .run }
        for (arguments, classification) in zip(batch, classifications) {
            switch classification {
            case .destructive(let reason), .expensive(let reason):
                let name = String(decoding: arguments[0], as: UTF8.self).uppercased()
                return .confirm(title: String(localized: "Run \(name)?"), message: reason)
            default: continue
            }
        }
        return .run
    }

    func run(_ source: String, confirmed: Bool = false) {
        let commands = Self.commands(in: source)
        guard !commands.isEmpty, let session = workspace.session, !isRunning else { return }
        runTask = Task {
            var parsed: [[[UInt8]]] = []
            for (line, count) in commands {
                do {
                    let arguments = try CommandLineParser.split(line)
                    parsed.append(contentsOf: Array(repeating: arguments, count: count))
                } catch {
                    record(commands: [line], text: String(describing: error), isError: true, duration: .zero, reply: nil)
                    return
                }
            }
            let table = (try? await session.commandTable()) ?? .empty
            let confirms = UserDefaults.standard.object(forKey: SettingsKey.confirmDangerousCommands) as? Bool ?? true
            switch Self.preflight(parsed, table: table, confirmed: confirmed, confirmsDangerousCommands: confirms) {
            case .run:
                break
            case .confirm(let title, let message):
                confirmation = .init(line: source, title: title, message: message, isDestructive: true)
                return
            case .reject(let message):
                record(commands: commands.map(\.line), text: message, isError: true, duration: .zero, reply: nil)
                return
            }
            isRunning = true
            defer { isRunning = false }
            let clock = ContinuousClock()
            let started = clock.now
            let display = commands.map { $0.repeat > 1 ? "\($0.repeat) \($0.line)" : $0.line }
            do {
                let redisCommands = parsed.map { RedisCommand(arguments: $0) }
                var replies: [RESPValue] = []
                if usesPipeline {
                    replies = try await session.pipeline(redisCommands, role: .workbench, target: target)
                } else {
                    for command in redisCommands {
                        try Task.checkCancellation()
                        replies.append(try await session.send(command, role: .workbench, target: target))
                    }
                }
                let text: String
                if replies.count == 1 {
                    text = ReplyFormatter.cliText(replies[0])
                } else {
                    text = zip(parsed, replies).map { arguments, reply in
                        "> " + arguments.map(CommandLineParser.quote).joined(separator: " ") + "\n" + ReplyFormatter.cliText(reply)
                    }.joined(separator: "\n\n")
                }
                record(commands: display, text: text, isError: replies.contains { $0.serverError != nil },
                       duration: clock.now - started, reply: replies.last)
            } catch is CancellationError {
                record(commands: display, text: String(localized: "(cancelled)"), isError: true, duration: clock.now - started, reply: nil)
            } catch {
                record(commands: display, text: "(error) \(error)", isError: true, duration: clock.now - started, reply: nil)
            }
        }
    }

    func cancel() {
        runTask?.cancel()
        Task { await workspace.session?.release(.workbench) }
    }

    private func record(commands: [String], text: String, isError: Bool, duration: Duration, reply: RESPValue?) {
        let milliseconds = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        var trimmed = text
        if trimmed.utf8.count > Self.maxResultText {
            trimmed = String(trimmed.prefix(Self.maxResultText)) + "\n… (truncated)"
        }
        let node: String? = if case .node(let endpoint) = target { endpoint.description } else { nil }
        let result = Result(commands: commands, durationMilliseconds: milliseconds, node: node, text: trimmed, isError: isError,
                            table: reply.flatMap(Self.table), json: reply.flatMap(Self.json))
        results.insert(result, at: 0)
        if results.count > Self.maxResults { results.removeLast(results.count - Self.maxResults) }
        saveResults()
    }

    func remove(_ id: Result.ID) {
        results.removeAll { $0.id == id }
        saveResults()
    }

    func toggle(_ id: Result.ID) {
        guard let index = results.firstIndex(where: { $0.id == id }) else { return }
        results[index].isCollapsed.toggle()
    }

    func clearResults() {
        results.removeAll()
        saveResults()
    }

    // MARK: - Structured views

    /// Tables for common shapes: FT.SEARCH (RESP2 and RESP3), arrays of maps, and maps.
    static func table(from reply: RESPValue) -> ResultTable? {
        let value = reply.unwrapped
        // RESP3 FT.SEARCH: {total_results, results: [{id, extra_attributes: {...}}]}
        if let results = value["results"]?.array, value["total_results"] != nil {
            let records = results.map { result -> (String, [RESPPair]) in
                (result["id"]?.string ?? "", result["extra_attributes"]?.pairs ?? [])
            }
            return makeTable(records)
        }
        // RESP2 FT.SEARCH: [total, id, [field, value, …], id, […], …]
        if let items = value.array, items.count >= 3, items.count % 2 == 1, items[0].int != nil,
           stride(from: 2, to: items.count, by: 2).allSatisfy({ items[$0].array != nil }) {
            let records = stride(from: 1, to: items.count, by: 2).map { (items[$0].string ?? "", items[$0 + 1].pairs ?? []) }
            return makeTable(records)
        }
        if let items = value.array, !items.isEmpty, items.allSatisfy({ if case .map = $0.unwrapped { true } else { false } }) {
            return makeTable(items.enumerated().map { (String($0.offset + 1), $0.element.pairs ?? []) })
        }
        if case .map(let pairs) = value, !pairs.isEmpty {
            return ResultTable(columns: [String(localized: "Field"), String(localized: "Value")],
                               rows: pairs.map { [$0.key.string ?? ReplyFormatter.cliText($0.key), cell($0.value)] })
        }
        return nil
    }

    private static func makeTable(_ records: [(String, [RESPPair])]) -> ResultTable? {
        guard !records.isEmpty else { return nil }
        var columns: [String] = []
        var seen = Set<String>()
        for (_, pairs) in records {
            for pair in pairs {
                let name = pair.key.string ?? "?"
                if seen.insert(name).inserted { columns.append(name) }
            }
        }
        let rows = records.map { id, pairs -> [String] in
            var values = Dictionary(pairs.map { ($0.key.string ?? "?", cell($0.value)) }, uniquingKeysWith: { first, _ in first })
            return [id] + columns.map { values.removeValue(forKey: $0) ?? "" }
        }
        return ResultTable(columns: [String(localized: "Key")] + columns, rows: rows)
    }

    private static func cell(_ value: RESPValue) -> String {
        switch value.unwrapped {
        case .bulkString(let bytes), .verbatimString(_, let bytes): ValueFormatter.preview(bytes, limit: 300)
        case .simpleString(let text): text
        default: ReplyFormatter.cliText(value).replacingOccurrences(of: "\n", with: " ")
        }
    }

    static func json(from reply: RESPValue) -> String? {
        guard let bytes = reply.unwrapped.bytes, ValueFormatter.detect(bytes) == .json else { return nil }
        return ValueFormatter.prettyJSON(String(decoding: bytes.prefix(maxResultText), as: UTF8.self))
    }

    // MARK: - Persistence

    private func scheduleDraftSave() {
        draftTask?.cancel()
        let text = self.text
        let url = RediDirectories.connectionData(workspace.profile.id).appending(path: "workbench.txt")
        draftTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func saveResults() {
        let results = self.results
        let url = RediDirectories.connectionData(workspace.profile.id).appending(path: "workbench-results.json")
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(results).write(to: url, options: .atomic)
        }
    }
}
