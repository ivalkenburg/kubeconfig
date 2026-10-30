import Foundation
import Yams

public enum ConfigError: LocalizedError, Equatable {
    case invalid(String)
    case externalChange
    case missingEntry(String)
    case referenced(String, [String])
    case activeContext
    case backupFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .externalChange: return "This file changed outside KubeConfig. Export your draft if needed, then reload the file before applying."
        case .missingEntry(let name): return "The entry ‘\(name)’ no longer exists."
        case .referenced(let name, let contexts): return "‘\(name)’ is used by: \(contexts.joined(separator: ", ")). Update or delete those contexts first."
        case .activeContext: return "Choose another active context or explicitly clear the active context before deleting this one."
        case .backupFailure(let message): return message
        }
    }
}

public enum EntryKind: String, CaseIterable, Identifiable, Codable {
    case contexts, clusters, users
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var singular: String { String(rawValue.dropLast()) }
    public var symbol: String {
        switch self {
        case .contexts: return "square.stack.3d.up"
        case .clusters: return "server.rack"
        case .users: return "person.crop.circle"
        }
    }
}

public struct ConfigEntry: Identifiable, Equatable {
    public let kind: EntryKind
    public internal(set) var node: Node
    public var name: String { node["name"]?.string ?? "" }
    public var id: String { name }
    public var fields: Node { node[kind.singular] ?? Node([] as [(Node, Node)]) }
    public func value(_ key: String) -> String { fields[key]?.string ?? "" }
    public var authenticationSummary: String {
        if fields["exec"] != nil { return "Credential plugin" }
        if fields["auth-provider"] != nil { return "Authentication provider" }
        if fields["token"] != nil || fields["tokenFile"] != nil { return "Token" }
        if fields["client-certificate"] != nil || fields["client-certificate-data"] != nil { return "Client certificate" }
        if fields["username"] != nil { return "Username & password" }
        return "No credentials"
    }
}

public struct KubeDocument: Equatable {
    public static let maximumByteCount = 16 * 1024 * 1024
    public internal(set) var root: Node

    public init(yaml: String) throws {
        try Self.checkSize(yaml)
        do {
            guard let parsed = try Yams.compose(yaml: yaml), parsed.mapping != nil else {
                throw ConfigError.invalid("A kubeconfig must be a YAML mapping. Create a configuration or import an existing one.")
            }
            root = parsed
        } catch let error as YamlError {
            // Yams' default description includes source lines, which may contain credentials.
            switch error {
            case .scanner(_, _, let mark, _), .parser(_, _, let mark, _), .composer(_, _, let mark, _):
                throw ConfigError.invalid("Invalid YAML at line \(mark.line), column \(mark.column). Check indentation, quotes, and brackets.")
            default: throw ConfigError.invalid("Could not parse the YAML. Check its encoding and syntax.")
            }
        }
        try Self.checkMappings(root, path: "configuration", depth: 0)
        for kind in EntryKind.allCases {
            guard let node = root[kind.rawValue], node.null == nil else { continue }
            guard node.sequence != nil else { throw ConfigError.invalid("\(kind.title) must be a YAML list.") }
            var seen = Set<String>()
            for entry in entries(kind) {
                guard entry.node.mapping != nil, !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      entry.node["name"]?.tag == Tag(.str), entry.node[kind.singular]?.mapping != nil else {
                    throw ConfigError.invalid("Each \(kind.singular) needs a string name and a ‘\(kind.singular)’ mapping.")
                }
                guard seen.insert(entry.name).inserted else { throw ConfigError.invalid("Duplicate \(kind.singular) name: \(entry.name). Rename it in YAML before continuing.") }
            }
        }
    }

    public static let empty = try! KubeDocument(yaml: "apiVersion: v1\nkind: Config\nclusters: []\nusers: []\ncontexts: []\ncurrent-context: \"\"\n")

    public var currentContext: String { root["current-context"]?.string ?? "" }

    public func entries(_ kind: EntryKind) -> [ConfigEntry] {
        (root[kind.rawValue]?.array() ?? []).map { ConfigEntry(kind: kind, node: $0) }
    }

    public func entry(_ kind: EntryKind, named name: String) -> ConfigEntry? {
        entries(kind).first { $0.name == name }
    }

    public func serialized(revealingSecrets: Bool = true) throws -> String {
        let text = try Yams.serialize(node: revealingSecrets ? root : Self.redacted(root), width: -1, allowUnicode: true)
        if revealingSecrets { try Self.checkSize(text) }
        return text
    }

    internal func redactedComparedTo(_ previous: KubeDocument?) throws -> String {
        try Yams.serialize(node: Self.redacted(root, comparedTo: previous?.root), width: -1, allowUnicode: true)
    }

    public var validationIssues: [String] {
        var issues: [String] = []
        if let version = root["apiVersion"], version.string != "v1" { issues.append("apiVersion must be v1.") }
        if let kind = root["kind"], kind.string != "Config" { issues.append("kind must be Config.") }
        if let current = root["current-context"], current.tag != Tag(.str) && current.null == nil {
            issues.append("current-context must be a string.")
        }
        for cluster in entries(.clusters) {
            let server = cluster.value("server")
            if let url = URL(string: server), ["https", "http"].contains(url.scheme ?? ""), url.host != nil {} else {
                issues.append("Cluster ‘\(cluster.name)’ needs a valid http or https server address.")
            }
            issues += Self.stringFieldIssues(cluster, keys: ["server", "certificate-authority", "certificate-authority-data", "tls-server-name", "proxy-url"])
            for key in ["insecure-skip-tls-verify", "disable-compression"] {
                if let value = cluster.fields[key], value.null == nil && value.tag != Tag(.bool) {
                    issues.append("\(key) in cluster ‘\(cluster.name)’ must be a boolean.")
                }
            }
        }
        for user in entries(.users) {
            issues += Self.stringFieldIssues(user, keys: ["username", "password", "token", "tokenFile", "client-certificate", "client-certificate-data", "client-key", "client-key-data", "as", "as-uid"])
            for key in ["exec", "auth-provider"] {
                if let value = user.fields[key], value.null == nil && value.mapping == nil {
                    issues.append("\(key) in user ‘\(user.name)’ must be a mapping.")
                }
            }
            if let exec = user.fields["exec"], exec.mapping != nil {
                if exec["command"]?.tag != Tag(.str) || exec["command"]?.string?.isEmpty != false {
                    issues.append("Credential plugin in user ‘\(user.name)’ needs a command string.")
                }
                if let args = exec["args"], args.null == nil,
                   args.sequence == nil || args.array().contains(where: { $0.tag != Tag(.str) }) {
                    issues.append("Credential plugin args in user ‘\(user.name)’ must be a list of strings.")
                }
                if let env = exec["env"], env.null == nil,
                   env.sequence == nil || env.array().contains(where: { $0["name"]?.tag != Tag(.str) || $0["value"]?.tag != Tag(.str) }) {
                    issues.append("Credential plugin env in user ‘\(user.name)’ must contain string name/value pairs.")
                }
            }
        }
        for context in entries(.contexts) {
            let cluster = context.value("cluster")
            let user = context.value("user")
            if cluster.isEmpty || entry(.clusters, named: cluster) == nil { issues.append("Context ‘\(context.name)’ refers to a missing cluster.") }
            if !user.isEmpty && entry(.users, named: user) == nil { issues.append("Context ‘\(context.name)’ refers to a missing user.") }
            for key in ["cluster", "user", "namespace"] {
                if let value = context.fields[key], value.tag != Tag(.str) && value.null == nil {
                    issues.append("\(key.capitalized) in context ‘\(context.name)’ must be a string.")
                }
            }
        }
        if !currentContext.isEmpty && entry(.contexts, named: currentContext) == nil {
            issues.append("The active context ‘\(currentContext)’ does not exist.")
        }
        return issues
    }

    public func validate() throws {
        let issues = validationIssues
        if !issues.isEmpty { throw ConfigError.invalid(issues.joined(separator: "\n")) }
    }

    public mutating func setCurrentContext(_ name: String) throws {
        guard name.isEmpty || entry(.contexts, named: name) != nil else { throw ConfigError.missingEntry(name) }
        root["current-context"] = Self.string(name)
    }

    /// Patches only fields explicitly supplied by the form, retaining every unfamiliar field.
    public mutating func update(_ kind: EntryKind, originalName: String?, name: String, fields: [String: String]) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConfigError.invalid("Enter a name.") }
        guard !entries(kind).contains(where: { $0.name == trimmed && $0.name != originalName }) else {
            throw ConfigError.invalid("A \(kind.singular) named ‘\(trimmed)’ already exists.")
        }
        var list = entries(kind).map(\.node)
        let index = originalName.flatMap { old in list.firstIndex { $0["name"]?.string == old } }
        if originalName != nil && index == nil { throw ConfigError.missingEntry(originalName!) }
        var node = index.map { list[$0] } ?? Node([(Node("name"), Self.string(trimmed)), (Node(kind.singular), Node([] as [(Node, Node)]))])
        node["name"] = Self.string(trimmed)
        var body = node[kind.singular] ?? Node([] as [(Node, Node)])
        for (key, value) in fields {
            if value.isEmpty { body.remove(key) } else { body[key] = Self.string(value) }
        }
        node[kind.singular] = body
        if let index { list[index] = node } else { list.append(node) }
        root[kind.rawValue] = Node(list)
        if let originalName, originalName != trimmed {
            if kind == .contexts && currentContext == originalName { root["current-context"] = Self.string(trimmed) }
            if kind != .contexts {
                var contexts = entries(.contexts).map(\.node)
                for index in contexts.indices where contexts[index]["context"]?[kind.singular]?.string == originalName {
                    contexts[index]["context"]?[kind.singular] = Self.string(trimmed)
                }
                root["contexts"] = Node(contexts)
            }
        }
    }

    public func referencingContexts(_ kind: EntryKind, name: String) -> [String] {
        guard kind != .contexts else { return [] }
        return entries(.contexts).filter { $0.value(kind.singular) == name }.map(\.name)
    }

    public mutating func delete(_ kind: EntryKind, name: String) throws {
        guard entry(kind, named: name) != nil else { throw ConfigError.missingEntry(name) }
        let references = referencingContexts(kind, name: name)
        guard references.isEmpty else { throw ConfigError.referenced(name, references) }
        guard kind != .contexts || currentContext != name else { throw ConfigError.activeContext }
        root[kind.rawValue] = Node(entries(kind).filter { $0.name != name }.map(\.node))
    }

    public var hasRelativePaths: Bool { !relativePaths.isEmpty }

    public var relativePaths: [String] {
        var paths: [String] = []
        for kind in [EntryKind.clusters, .users] {
            for entry in entries(kind) {
                for key in Self.fileKeys(kind) {
                    let value = entry.value(key)
                    if !value.isEmpty && !NSString(string: value).isAbsolutePath { paths.append(value) }
                }
                if let command = entry.fields["exec"]?["command"]?.string,
                   command.contains("/"), !NSString(string: command).isAbsolutePath { paths.append(command) }
            }
        }
        return paths
    }

    public mutating func resolveRelativePaths(relativeTo directory: URL) -> [String] {
        var resolutions: [String] = []
        for kind in [EntryKind.clusters, .users] {
            var nodes = entries(kind).map(\.node)
            for index in nodes.indices {
                var fields = nodes[index][kind.singular]!
                for key in Self.fileKeys(kind) {
                    if let value = fields[key]?.string, !value.isEmpty, !NSString(string: value).isAbsolutePath {
                        let resolved = directory.appendingPathComponent(value).standardizedFileURL.path
                        fields[key] = Self.string(resolved)
                        resolutions.append("\(value) → \(resolved)")
                    }
                }
                if let command = fields["exec"]?["command"]?.string,
                   command.contains("/"), !NSString(string: command).isAbsolutePath {
                    let resolved = directory.appendingPathComponent(command).standardizedFileURL.path
                    fields["exec"]?["command"] = Self.string(resolved)
                    resolutions.append("\(command) → \(resolved)")
                }
                nodes[index][kind.singular] = fields
            }
            root[kind.rawValue] = Node(nodes)
        }
        return resolutions
    }

    internal static func string(_ value: String) -> Node { Node(value, Tag(.str)) }

    private static func checkSize(_ text: String) throws {
        guard text.utf8.count <= maximumByteCount else { throw ConfigError.invalid("Configuration exceeds the 16 MB size limit.") }
    }

    private static func fileKeys(_ kind: EntryKind) -> [String] {
        kind == .clusters ? ["certificate-authority"] : ["client-certificate", "client-key", "tokenFile"]
    }

    private static func stringFieldIssues(_ entry: ConfigEntry, keys: [String]) -> [String] {
        keys.compactMap { key in
            guard let value = entry.fields[key], value.null == nil, value.tag != Tag(.str) else { return nil }
            return "\(key) in \(entry.kind.singular) ‘\(entry.name)’ must be a string."
        }
    }

    private static func checkMappings(_ node: Node, path: String, depth: Int) throws {
        guard depth < 64 else { throw ConfigError.invalid("YAML nesting exceeds 64 levels.") }
        if let mapping = node.mapping {
            var keys = Set<String>()
            for pair in mapping {
                guard let key = pair.key.string, pair.key.tag == Tag(.str) else {
                    throw ConfigError.invalid("YAML mapping keys must be strings.")
                }
                guard key != "<<" else { throw ConfigError.invalid("YAML merge keys (<<) are not supported. Expand the mapping before editing.") }
                guard keys.insert(key).inserted else { throw ConfigError.invalid("Duplicate YAML key at \(path). Check the raw YAML.") }
                try checkMappings(pair.value, path: path + "." + key, depth: depth + 1)
            }
        } else if let sequence = node.sequence {
            for value in sequence { try checkMappings(value, path: path, depth: depth + 1) }
        }
    }

    private static func redacted(_ node: Node, comparedTo previous: Node? = nil) -> Node {
        if let mapping = node.mapping {
            return Node(mapping.map { pair in
                let key = pair.key.string?.lowercased() ?? ""
                let sensitive = ["token", "id-token", "access-token", "refresh-token", "password", "client-key-data", "client-key", "client-secret", "secret", "args", "env"].contains(key)
                    || key.contains("password") || key.contains("secret") || key.hasSuffix("token")
                let label = previous != nil && previous?[pair.key] != pair.value ? "‹changed secret›" : "‹redacted›"
                return (pair.key, sensitive ? Self.string(label) : redacted(pair.value, comparedTo: previous?[pair.key]))
            })
        }
        if let sequence = node.sequence {
            return Node(sequence.enumerated().map { index, value in
                let old = previous?.array()
                let comparison: Node?
                if let name = value["name"]?.string { comparison = old?.first { $0["name"]?.string == name } }
                else { comparison = old.flatMap { $0.indices.contains(index) ? $0[index] : nil } }
                return redacted(value, comparedTo: comparison)
            })
        }
        return node
    }
}

extension Node {
    mutating func remove(_ key: String) {
        guard var mapping else { return }
        mapping[key] = nil
        self = .mapping(mapping)
    }
}
