import Foundation
import Yams

public enum ImportAction {
    case rename, replace, skip, reuse
}

public struct ImportItem: Identifiable {
    public let kind: EntryKind
    public let originalName: String
    public let conflicts: Bool
    public let identical: Bool
    public var action: ImportAction
    public var destinationName: String
    public var id: String { kind.rawValue + ":" + originalName }
}

public struct ImportPlan {
    public let incoming: KubeDocument
    public let resolvedPaths: [String]
    public var items: [ImportItem]
    public var activateImportedContext = false

    public init(target: KubeDocument, incoming: KubeDocument, sourceDirectory: URL?) throws {
        if let version = incoming.root["apiVersion"], version.string != "v1" { throw ConfigError.invalid("Imported apiVersion must be v1.") }
        if let kind = incoming.root["kind"], kind.string != "Config" { throw ConfigError.invalid("The imported file must have kind Config.") }
        var resolved = incoming
        if resolved.hasRelativePaths && sourceDirectory == nil {
            throw ConfigError.invalid("Choose the source folder to resolve the relative file paths in this import.")
        }
        resolvedPaths = sourceDirectory.map { resolved.resolveRelativePaths(relativeTo: $0) } ?? []
        self.incoming = resolved
        items = []
        var nameMaps: [EntryKind: [String: String]] = [:]
        for kind in EntryKind.importOrder {
            var reserved = Set(target.entries(kind).map(\.name) + resolved.entries(kind).map(\.name))
            for entry in resolved.entries(kind) {
                let existing = target.entry(kind, named: entry.name)
                var comparable = entry.node
                if kind == .contexts { Self.rewriteContext(&comparable, maps: nameMaps) }
                let identical = existing?.node.isEquivalent(to: comparable) ?? false
                let needsRename = existing != nil && !identical
                let destination = needsRename ? KubeDocument.uniqueName(entry.name + "-imported", isTaken: reserved.contains) : entry.name
                reserved.insert(destination)
                nameMaps[kind, default: [:]][entry.name] = destination
                items.append(ImportItem(kind: kind, originalName: entry.name, conflicts: existing != nil,
                                        identical: identical, action: identical ? .reuse : .rename, destinationName: destination))
            }
        }
    }

    public func merged(into target: KubeDocument) throws -> KubeDocument {
        var result = target
        var maps: [EntryKind: [String: String]] = [:]
        for item in items {
            let destination = item.action == .rename ? item.destinationName.trimmingCharacters(in: .whitespacesAndNewlines) : item.originalName
            guard !destination.isEmpty else { throw ConfigError.invalid("Every imported entry needs a destination name.") }
            maps[item.kind, default: [:]][item.originalName] = destination
        }
        for kind in EntryKind.importOrder {
            var list = result.entries(kind).map(\.node)
            var destinations = Set<String>()
            for item in items where item.kind == kind {
                guard item.action != .skip else { continue }
                let destination = maps[kind]![item.originalName]!
                guard destinations.insert(destination).inserted else { throw ConfigError.invalid("Two imported \(kind.rawValue) resolve to ‘\(destination)’. Choose unique destination names.") }
                var node = incoming.entry(kind, named: item.originalName)!.node
                node["name"] = KubeDocument.string(destination)
                if kind == .contexts { Self.rewriteContext(&node, maps: maps) }
                let existing = list.firstIndex { $0["name"]?.string == destination }
                switch item.action {
                case .skip: break
                case .reuse:
                    guard let existing, list[existing].isEquivalent(to: node) else {
                        throw ConfigError.invalid("‘\(item.originalName)’ is no longer identical after reference changes. Rename or replace it instead.")
                    }
                case .replace:
                    if let existing { list[existing] = node } else { list.append(node) }
                case .rename:
                    guard existing == nil else { throw ConfigError.invalid("‘\(destination)’ already exists. Choose another name or Replace.") }
                    list.append(node)
                }
            }
            result.root[kind.rawValue] = Node(list)
        }
        // Retain imported top-level extension data as well as opaque entry fields.
        let standard: Set<String> = ["clusters", "users", "contexts", "current-context", "apiVersion", "kind"]
        if let mapping = incoming.root.mapping {
            for pair in mapping {
                guard let key = pair.key.string, !standard.contains(key) else { continue }
                if let old = result.root[key] {
                    result.root[key] = try Self.mergeMetadata(old, pair.value, path: key)
                } else { result.root[key] = pair.value }
            }
        }
        if activateImportedContext, !incoming.currentContext.isEmpty {
            let selected = maps[.contexts]?[incoming.currentContext] ?? incoming.currentContext
            try result.setCurrentContext(selected)
        }
        try result.validate()
        return result
    }

    private static func rewriteContext(_ node: inout Node, maps: [EntryKind: [String: String]]) {
        for kind in EntryKind.referenced {
            if let reference = node["context"]?[kind.singular]?.text, let name = maps[kind]?[reference] {
                node["context"]?[kind.singular] = KubeDocument.string(name)
            }
        }
    }

    private static func mergeMetadata(_ old: Node, _ new: Node, path: String) throws -> Node {
        if old.isEquivalent(to: new) || new.tag == Tag(.null) { return old }
        if old.tag == Tag(.null) { return new }
        if old.mapping != nil, let mapping = new.mapping {
            var result = old
            for pair in mapping {
                let key = pair.key.string!
                result[key] = try old[key].map { try mergeMetadata($0, pair.value, path: path + "." + key) } ?? pair.value
            }
            return result
        }
        if let left = old.sequence, let right = new.sequence {
            var result = Array(left)
            for value in right {
                if result.contains(where: { $0.isEquivalent(to: value) }) { continue }
                if let name = value["name"]?.string, result.contains(where: { $0["name"]?.string == name }) {
                    throw metadataConflict(at: path)
                }
                result.append(value)
            }
            return Node(result)
        }
        throw metadataConflict(at: path)
    }

    private static func metadataConflict(at path: String) -> ConfigError {
        .invalid("Imported metadata conflicts at \(path). Resolve that field in the YAML editor before importing.")
    }
}
