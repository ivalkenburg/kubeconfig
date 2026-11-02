import Foundation
import Yams

public enum ImportAction {
    case rename, replace, skip, reuse
}

public struct ImportItem {
    public let kind: EntryKind
    public let originalName: String
    public let conflicts: Bool
    public let identical: Bool
    public var action: ImportAction
    public var destinationName: String
}

public struct ImportPlan {
    public let incoming: KubeDocument
    public let resolvedPaths: [String]
    public var items: [ImportItem]

    public init(target: KubeDocument, incoming: KubeDocument, sourceDirectory: URL?) throws {
        if let version = incoming.root["apiVersion"], version.string != "v1" { throw ConfigError.invalid("Imported apiVersion must be v1.") }
        if let kind = incoming.root["kind"], kind.string != "Config" { throw ConfigError.invalid("The imported file must have kind Config.") }
        var resolved = incoming
        if sourceDirectory == nil && resolved.hasRelativePaths {
            throw ConfigError.invalid("Choose the source folder to resolve the relative file paths in this import.")
        }
        // Entries can share a file, and the sheet identifies these rows by their text.
        var listed = Set<String>()
        resolvedPaths = (sourceDirectory.map { resolved.resolveRelativePaths(relativeTo: $0) } ?? []).filter { listed.insert($0).inserted }
        self.incoming = resolved
        items = []
        var nameMaps: [EntryKind: [String: String]] = [:]
        for kind in EntryKind.importOrder {
            let existingEntries = target.entriesByName(kind)
            let incomingEntries = resolved.entries(kind)
            let reserved = Set(existingEntries.keys).union(incomingEntries.map(\.name))
            for entry in incomingEntries {
                let existing = existingEntries[entry.name]
                var comparable = entry.node
                if kind == .contexts { Self.rewriteContext(&comparable, maps: nameMaps) }
                let identical = existing?.node.isEquivalent(to: comparable) ?? false
                // Proposed for identical entries too, in case Rename is chosen over reusing them.
                let proposed = existing == nil ? entry.name : KubeDocument.uniqueName(entry.name + "-imported", isTaken: reserved.contains)
                nameMaps[kind, default: [:]][entry.name] = identical ? entry.name : proposed
                items.append(ImportItem(kind: kind, originalName: entry.name, conflicts: existing != nil,
                                        identical: identical, action: identical ? .reuse : .rename, destinationName: proposed))
            }
        }
    }

    public func merged(into target: KubeDocument) throws -> KubeDocument {
        var result = target
        var maps: [EntryKind: [String: String]] = [:]
        var skipped: [EntryKind: Set<String>] = [:]
        var claimed: [EntryKind: [String: String]] = [:]
        for item in items {
            let destination = item.action == .rename ? item.destinationName.trimmingCharacters(in: .whitespacesAndNewlines) : item.originalName
            guard !destination.isEmpty else { throw ConfigError.invalid("Every imported entry needs a destination name.") }
            maps[item.kind, default: [:]][item.originalName] = destination
            if item.action == .skip { skipped[item.kind, default: []].insert(item.originalName) }
            else { claimed[item.kind, default: [:]][destination] = item.originalName }
        }
        for kind in EntryKind.importOrder {
            let existingEntries = result.entries(kind)
            var list = existingEntries.map(\.node)
            var indices = Dictionary(uniqueKeysWithValues: existingEntries.enumerated().map { ($0.element.name, $0.offset) })
            let incomingEntries = incoming.entriesByName(kind)
            var destinations = Set<String>()
            for item in items where item.kind == kind && item.action != .skip {
                let destination = maps[kind]![item.originalName]!
                guard destinations.insert(destination).inserted else { throw ConfigError.invalid("Two imported \(kind.rawValue) resolve to ‘\(destination)’. Choose unique destination names.") }
                var node = incomingEntries[item.originalName]!.node
                node["name"] = KubeDocument.string(destination)
                if kind == .contexts {
                    try Self.checkSkippedReferences(of: node, skipped: skipped, claimed: claimed)
                    Self.rewriteContext(&node, maps: maps)
                }
                let existing = indices[destination]
                switch item.action {
                case .skip: break
                case .reuse:
                    guard let existing, list[existing].isEquivalent(to: node) else {
                        throw ConfigError.invalid("‘\(item.originalName)’ is no longer identical after reference changes. Rename or replace it instead.")
                    }
                case .replace:
                    if let existing { list[existing] = node }
                    else { indices[destination] = list.count; list.append(node) }
                case .rename:
                    guard existing == nil else { throw ConfigError.invalid("‘\(destination)’ already exists. Choose another name or Replace.") }
                    indices[destination] = list.count
                    list.append(node)
                }
            }
            if !list.isEmpty { result.root[kind.rawValue] = Node(list) }
        }
        // Retain imported top-level extension data as well as opaque entry fields.
        let standard: Set<String> = ["clusters", "users", "contexts", "current-context", "apiVersion", "kind"]
        if let mapping = incoming.root.mapping {
            for pair in mapping {
                guard let key = pair.key.string, !standard.contains(key) else { continue }
                result.root[pair.key] = try result.root[pair.key].map { try Self.mergeMetadata($0, pair.value, path: key) } ?? pair.value
            }
        }
        try result.validate()
        return result
    }

    /// A skipped entry keeps its name in references, which mustn't then land on another entry renamed to it.
    private static func checkSkippedReferences(of context: Node, skipped: [EntryKind: Set<String>], claimed: [EntryKind: [String: String]]) throws {
        for kind in EntryKind.referenced {
            guard let reference = context["context"]?[kind.singular]?.text,
                  skipped[kind]?.contains(reference) == true,
                  let other = claimed[kind]?[reference] else { continue }
            throw ConfigError.invalid("Context ‘\(context["name"]?.string ?? "")’ refers to the skipped \(kind.singular) ‘\(reference)’, and ‘\(other)’ would take that name. Import ‘\(reference)’ or choose another name.")
        }
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
                result[pair.key] = try old[pair.key].map { try mergeMetadata($0, pair.value, path: path + "." + key) } ?? pair.value
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
