/// Redis data types, including the common module types.
public enum RedisKeyType: UInt8, Sendable, Hashable, CaseIterable, Codable {
    case unknown = 0
    case string, hash, list, set, zset, stream
    case json, timeSeries, bloom, cuckoo, countMinSketch, topK, tDigest, vectorSet
    case other
    /// The key no longer exists.
    case none

    public init(typeReply: String) {
        switch typeReply {
        case "string": self = .string
        case "hash": self = .hash
        case "list": self = .list
        case "set": self = .set
        case "zset": self = .zset
        case "stream": self = .stream
        case "ReJSON-RL": self = .json
        case "TSDB-TYPE": self = .timeSeries
        case "MBbloom--": self = .bloom
        case "MBbloomCF": self = .cuckoo
        case "CMSk-TYPE": self = .countMinSketch
        case "TopK-TYPE": self = .topK
        case "TDIS-TYPE": self = .tDigest
        case "vectorset": self = .vectorSet
        case "none": self = .none
        default: self = .other
        }
    }

    /// Value for `SCAN … TYPE`, where the server supports filtering by this type.
    public var scanTypeName: String? {
        switch self {
        case .string: "string"
        case .hash: "hash"
        case .list: "list"
        case .set: "set"
        case .zset: "zset"
        case .stream: "stream"
        case .json: "ReJSON-RL"
        case .timeSeries: "TSDB-TYPE"
        case .vectorSet: "vectorset"
        default: nil
        }
    }

    /// Short badge label, as in Redis Insight.
    public var badge: String {
        switch self {
        case .unknown: "…"
        case .string: "STR"
        case .hash: "HASH"
        case .list: "LIST"
        case .set: "SET"
        case .zset: "ZSET"
        case .stream: "STREAM"
        case .json: "JSON"
        case .timeSeries: "TS"
        case .bloom: "BF"
        case .cuckoo: "CF"
        case .countMinSketch: "CMS"
        case .topK: "TOPK"
        case .tDigest: "TDIG"
        case .vectorSet: "VSET"
        case .other: "?"
        case .none: "—"
        }
    }

    public var displayName: String {
        switch self {
        case .unknown: "Unknown"
        case .string: "String"
        case .hash: "Hash"
        case .list: "List"
        case .set: "Set"
        case .zset: "Sorted Set"
        case .stream: "Stream"
        case .json: "JSON"
        case .timeSeries: "Time Series"
        case .bloom: "Bloom Filter"
        case .cuckoo: "Cuckoo Filter"
        case .countMinSketch: "Count-Min Sketch"
        case .topK: "Top-K"
        case .tDigest: "t-digest"
        case .vectorSet: "Vector Set"
        case .other: "Other"
        case .none: "Deleted"
        }
    }

    /// Types offered in the browser's type filter.
    public static let filterable: [RedisKeyType] = [.string, .hash, .list, .set, .zset, .stream, .json, .timeSeries, .vectorSet]
}

/// An immutable batch of keys stored contiguously: one byte arena plus offsets. Keys are binary
/// safe; decoding to `String` happens only for rows that are on screen.
public final class KeyPage: Sendable {
    public let bytes: [UInt8]
    /// `count + 1` offsets into `bytes`.
    public let offsets: [UInt32]
    /// Known type per key (from a `SCAN … TYPE` filter), or `nil`.
    public let type: RedisKeyType?

    public init(keys: [[UInt8]], type: RedisKeyType? = nil) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(keys.reduce(0) { $0 + $1.count })
        var offsets: [UInt32] = [0]
        offsets.reserveCapacity(keys.count + 1)
        for key in keys {
            bytes.append(contentsOf: key)
            offsets.append(UInt32(bytes.count))
        }
        self.bytes = bytes
        self.offsets = offsets
        self.type = type
    }

    public var count: Int { offsets.count - 1 }

    public func key(at index: Int) -> ArraySlice<UInt8> {
        bytes[Int(offsets[index])..<Int(offsets[index + 1])]
    }
}

/// All keys loaded by the browser, as a sequence of pages. Appending a page copies only a
/// reference, so the index can be handed to the UI cheaply after every scan page.
public struct KeyIndex: Sendable {
    public private(set) var pages: [KeyPage] = []
    private var starts: [Int] = []
    public private(set) var count = 0

    public init() {}

    public mutating func append(_ page: KeyPage) {
        guard page.count > 0 else { return }
        pages.append(page)
        starts.append(count)
        count += page.count
    }

    public func key(at index: Int) -> ArraySlice<UInt8> {
        let (page, offset) = locate(index)
        return pages[page].key(at: offset)
    }

    public func knownType(at index: Int) -> RedisKeyType? {
        pages[locate(index).page].type
    }

    /// Binary search for the page holding `index`.
    private func locate(_ index: Int) -> (page: Int, offset: Int) {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return (low, index - starts[low])
    }
}

/// Order-independent duplicate filter for SCAN results (SCAN may return a key more than once
/// while the server rehashes). Stores 64-bit hashes, not keys.
public struct KeyDeduplicator: Sendable {
    private var seen = Set<UInt64>()

    public init() {}

    public var count: Int { seen.count }

    /// Returns true the first time a key is seen.
    public mutating func insert(_ key: some Collection<UInt8>) -> Bool {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in key {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return seen.insert(hash).inserted
    }

    public mutating func removeAll() { seen.removeAll(keepingCapacity: false) }
}
