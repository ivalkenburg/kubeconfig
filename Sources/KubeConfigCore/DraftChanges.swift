import Foundation
import Yams

/// What Apply would change, compared by entry with the file on disk.
public struct DraftChanges {
    private var changed: [EntryKind: Set<String>] = [:]
    private var removed: [EntryKind: Set<String>] = [:]
    private var renamed: [EntryKind: Int] = [:]
    public private(set) var activeContextChanged = false

    public var count: Int { EntryKind.allCases.reduce(activeContextChanged ? 1 : 0) { $0 + count($1) } }
    public func count(_ kind: EntryKind) -> Int { (changed[kind]?.count ?? 0) + (removed[kind]?.count ?? 0) - (renamed[kind] ?? 0) }
    public func contains(_ kind: EntryKind, name: String) -> Bool { changed[kind]?.contains(name) == true }

    init(draft: KubeDocument, disk: KubeDocument?) {
        for kind in EntryKind.allCases {
            let old = Dictionary((disk?.entries(kind) ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let new = draft.entries(kind)
            changed[kind] = Set(new.filter { entry in old[entry.name]?.node.isEquivalent(to: entry.node) != true }.map(\.name))
            let gone = Set(old.keys).subtracting(new.map(\.name))
            removed[kind] = gone
            // A rename arrives as one entry removed and another added, but it's a single change.
            var unmatched = gone.compactMap { old[$0]?.withoutName }
            renamed[kind] = new.filter { entry in
                guard old[entry.name] == nil, let index = unmatched.firstIndex(where: { $0.isEquivalent(to: entry.withoutName) }) else { return false }
                unmatched.remove(at: index)
                return true
            }.count
        }
        activeContextChanged = draft.currentContext != (disk?.currentContext ?? "")
    }
}

private extension ConfigEntry {
    var withoutName: Node {
        var trimmed = node
        trimmed.remove("name")
        return trimmed
    }
}

extension KubeDocument {
    public func changes(from disk: KubeDocument?) -> DraftChanges { DraftChanges(draft: self, disk: disk) }

    /// Whether the two differ at most by key order, or by empty lists or an empty active context that one of them leaves out.
    public func isEquivalent(to other: KubeDocument) -> Bool { trimmedRoot.isEquivalent(to: other.trimmedRoot) }

    /// Uses `disk`'s copy of each entry that differs only by key order, as clearing a field and setting it again leaves it,
    /// so that the serialized draft shows no change there.
    public func adoptingKeyOrder(of disk: KubeDocument) -> KubeDocument {
        var result = self
        for kind in EntryKind.allCases where !entries(kind).isEmpty {
            let old = Dictionary(disk.entries(kind).map { ($0.name, $0.node) }, uniquingKeysWith: { first, _ in first })
            result.root[kind.rawValue] = Node(entries(kind).map { entry in
                old[entry.name].flatMap { $0.isEquivalent(to: entry.node) ? $0 : nil } ?? entry.node
            })
        }
        return result
    }

    private var trimmedRoot: Node {
        var trimmed = root
        for kind in EntryKind.allCases where entries(kind).isEmpty { trimmed.remove(kind.rawValue) }
        if currentContext.isEmpty { trimmed.remove("current-context") }
        return trimmed
    }
}
