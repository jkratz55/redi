/// Parsed output of the `INFO` command: `# Section` headers followed by `key:value` lines.
public struct RedisInfo: Sendable, Hashable {
    public struct Section: Sendable, Hashable {
        public var name: String
        public var fields: [Field]
    }

    public struct Field: Sendable, Hashable {
        public var key: String
        public var value: String
    }

    /// Sections in server order (for display).
    public private(set) var sections: [Section] = []
    /// Flattened lookup across all sections.
    private var values: [String: String] = [:]

    public init(parsing text: String) {
        var current: Section?
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.trimmingSuffix { $0 == "\r" }
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if let current { sections.append(current) }
                current = Section(name: line.dropFirst().trimmingPrefix(" ").description, fields: [])
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
            if current == nil { current = Section(name: "", fields: []) }
            current?.fields.append(Field(key: key, value: value))
            values[key] = value
        }
        if let current { sections.append(current) }
    }

    public subscript(key: String) -> String? { values[key] }

    public func int(_ key: String) -> Int64? { values[key].flatMap { Int64($0) } }

    public func double(_ key: String) -> Double? { values[key].flatMap { Double($0) } }

    /// Sections from `other` are appended; on duplicate keys `other` wins.
    public mutating func merge(_ other: RedisInfo) {
        sections.append(contentsOf: other.sections)
        values.merge(other.values) { _, new in new }
    }

    /// Parses `k1=v1,k2=v2` values such as `db0:keys=10,expires=0,avg_ttl=0`.
    public static func parseList(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for item in value.split(separator: ",") {
            guard let equals = item.firstIndex(of: "=") else { continue }
            result[String(item[..<equals])] = String(item[item.index(after: equals)...])
        }
        return result
    }
}

private extension Substring {
    func trimmingSuffix(while predicate: (Character) -> Bool) -> Substring {
        var end = endIndex
        while end > startIndex, predicate(self[index(before: end)]) { end = index(before: end) }
        return self[startIndex..<end]
    }
}
