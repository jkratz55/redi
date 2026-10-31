import Foundation

/// A namespace in the tree view (e.g. `user` for keys `user:1`, `user:2`).
///
/// Not thread-safe: owned by whichever actor builds the tree (the browser model, on the main actor).
/// Children are keyed by raw byte slices, so insertion doesn't allocate a `String` per segment.
public final class KeyTreeNode {
    public let name: String
    /// Full namespace prefix including the trailing delimiter (e.g. `user:`), for `SCAN MATCH`.
    public let prefix: [UInt8]
    public private(set) weak var parent: KeyTreeNode?
    public let depth: Int
    /// Keys whose last delimiter is in this namespace, as indices into the `KeyIndex`.
    public private(set) var keyIndices: [Int32] = []
    /// Keys in this namespace and every namespace below it.
    public private(set) var totalKeyCount = 0

    private var children: [ArraySlice<UInt8>: KeyTreeNode] = [:]
    private var sortedChildrenCache: [KeyTreeNode]?

    init(name: String, prefix: [UInt8], parent: KeyTreeNode?, depth: Int) {
        self.name = name
        self.prefix = prefix
        self.parent = parent
        self.depth = depth
    }

    public var childCount: Int { children.count }

    /// Child namespaces sorted with natural (numeric-aware) ordering. Cached until a child is added.
    public var sortedChildren: [KeyTreeNode] {
        if let sortedChildrenCache { return sortedChildrenCache }
        let sorted = children.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        sortedChildrenCache = sorted
        return sorted
    }

    fileprivate func child(for segment: ArraySlice<UInt8>, delimiter: [UInt8]) -> KeyTreeNode {
        if let existing = children[segment] { return existing }
        let node = KeyTreeNode(name: String(decoding: segment, as: UTF8.self),
                               prefix: prefix + segment + delimiter, parent: self, depth: depth + 1)
        children[segment] = node
        sortedChildrenCache = nil
        return node
    }

    fileprivate func addKey(_ index: Int32) {
        keyIndices.append(index)
    }

    fileprivate func incrementTotal() {
        totalKeyCount += 1
    }
}

/// Groups keys into namespaces by a delimiter, incrementally as scan pages arrive.
public final class KeyTree {
    public let delimiter: [UInt8]
    public private(set) var root: KeyTreeNode
    public private(set) var insertedCount = 0

    public init(delimiter: String) {
        self.delimiter = Array((delimiter.isEmpty ? ":" : delimiter).utf8)
        root = KeyTreeNode(name: "", prefix: [], parent: nil, depth: 0)
    }

    public func removeAll() {
        root = KeyTreeNode(name: "", prefix: [], parent: nil, depth: 0)
        insertedCount = 0
    }

    /// Inserts keys `index.count - added ..< index.count` (the newest page).
    public func insert(from index: KeyIndex, range: Range<Int>) {
        for position in range {
            insert(key: index.key(at: position), index: Int32(position))
        }
    }

    public func insert(key: ArraySlice<UInt8>, index: Int32) {
        var node = root
        node.incrementTotal()
        var segmentStart = key.startIndex
        var cursor = key.startIndex
        let first = delimiter[0]
        let width = delimiter.count
        while cursor < key.endIndex {
            if key[cursor] == first, cursor + width <= key.endIndex,
               width == 1 || key[cursor..<(cursor + width)].elementsEqual(delimiter) {
                node = node.child(for: key[segmentStart..<cursor], delimiter: delimiter)
                node.incrementTotal()
                cursor += width
                segmentStart = cursor
            } else {
                cursor += 1
            }
        }
        node.addKey(index)
        insertedCount += 1
    }
}
