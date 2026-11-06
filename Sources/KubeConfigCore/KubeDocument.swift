import Foundation
import Yams

public enum ConfigError: LocalizedError, Equatable {
    case invalid(String)
    case syntax(line: Int, column: Int)
    case duplicateKey(String, line: Int)
    case externalChange
    case missingEntry(String)
    case referenced(String, [String])
    case backupFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .syntax(let line, let column): return "Invalid YAML at line \(line), column \(column). Check indentation, quotes, and brackets."
        case .duplicateKey(let key, let line): return "The key ‘\(key)’ is repeated in one mapping, first at line \(line). Remove the extra copy."
        case .externalChange: return "This file changed outside KubeConfig. Export your draft if needed, then reload the file before applying."
        case .missingEntry(let name): return "The entry ‘\(name)’ no longer exists."
        case .referenced(let name, let contexts): return "‘\(name)’ is used by: \(contexts.joined(separator: ", ")). Update or delete those contexts first."
        case .backupFailure(let message): return message
        }
    }

    /// The one-based line to mark in the YAML editor, when the problem has one.
    public var line: Int? {
        switch self {
        case .syntax(let line, _), .duplicateKey(_, let line): return line
        default: return nil
        }
    }
}

public enum EntryKind: String, CaseIterable, Identifiable {
    case contexts, clusters, users
    /// The kinds a context refers to by name.
    public static let referenced: [EntryKind] = [.clusters, .users]
    /// Clusters and users come first, so that contexts can pick up their new names.
    public static let importOrder: [EntryKind] = referenced + [.contexts]
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
    public var fields: Node { node[kind.singular] ?? .emptyMapping }
    public func value(_ key: String) -> String { fields[key]?.text ?? "" }
    /// client-go accepts y/n as booleans; Yams' Bool accessor omits those spellings.
    public func booleanValue(_ key: String) -> Bool? {
        guard let value = fields[key], value.tag == Tag(.bool) else { return nil }
        switch value.string?.lowercased() {
        case "true", "yes", "y", "on": return true
        case "false", "no", "n", "off": return false
        default: return nil
        }
    }
    /// Whether the field holds anything but a YAML null, which counts as leaving it out.
    public func has(_ key: String) -> Bool { fields[key].map { $0.tag != Tag(.null) } ?? false }
    public var authenticationSummary: String {
        if has("exec") { return "Credential plugin" }
        if has("auth-provider") { return "Authentication provider" }
        if has("token") || has("tokenFile") { return "Token" }
        if has("client-certificate") || has("client-certificate-data") { return "Client certificate" }
        if has("username") { return "Username & password" }
        return "No credentials"
    }
}

public struct KubeDocument: Equatable {
    public static let maximumByteCount = 16 * 1024 * 1024
    /// Counts aliases at every use, since a short file of nested aliases can otherwise expand without end.
    private static let maximumNodeCount = 1_000_000
    /// kubectl reads dates, `12:30` and `=` as strings, so Yams' rules for them would refuse working files.
    private static let resolver = try! Resolver.default.removing(.timestamp).removing(.value)
        .replacing(.bool, with: #"^(?:y|Y|n|N|yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF)$"#)
        .replacing(.int, with: #"^(?:(?:[-+]_*)?0[bB][0-1_]+|(?:[-+]_*)?0[oO]?[0-7_]+|(?:[-+]_*)?(?:0|[1-9][0-9_]*)|(?:[-+]_*)?0[xX][0-9a-fA-F_]+)$"#)
        .replacing(.float, with: #"^(?:(?:[-+]_*)?(?:[0-9][0-9_]*(?:\.[0-9_]*)?|\.[0-9_]+)(?:[eE][-+]?[0-9]+)?|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$"#)

    public internal(set) var root: Node

    public init(yaml: String) throws {
        try Self.checkSize(yaml)
        // Yams reads a byte order mark as content, which puts the first line out of step with the rest.
        let yaml = yaml.unicodeScalars.first == "\u{FEFF}" ? String(yaml.unicodeScalars.dropFirst()) : yaml
        do {
            guard let parsed = try Yams.compose(yaml: yaml, Self.resolver), parsed.mapping != nil else {
                throw ConfigError.invalid("A kubeconfig must be a YAML mapping.")
            }
            root = parsed
        } catch let error as YamlError {
            // Yams' default description includes source lines, which may contain credentials.
            switch error {
            case .scanner(_, _, let mark, _), .parser(_, _, let mark, _), .composer(_, _, let mark, _):
                throw ConfigError.syntax(line: mark.line, column: mark.column)
            case .duplicatedKeysInMapping(let duplicates, let context):
                throw ConfigError.duplicateKey(duplicates.first ?? "", line: context.mark.line)
            default: throw ConfigError.invalid("Could not parse the YAML. Check its encoding and syntax.")
            }
        }
        var nodeCount = 0
        try Self.checkMappings(root, depth: 0, nodeCount: &nodeCount)
        // Rewriting the tree doubled parse time, and the draft is parsed on every keystroke. Tags have forms besides `!!str`.
        if yaml.utf8.contains(UInt8(ascii: "!")) { root = Self.keepingStrings(root) }
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

    public var currentContext: String { root["current-context"]?.text ?? "" }

    public func entries(_ kind: EntryKind) -> [ConfigEntry] {
        (root[kind.rawValue]?.array() ?? []).map { ConfigEntry(kind: kind, node: $0) }
    }

    public func entry(_ kind: EntryKind, named name: String) -> ConfigEntry? {
        entries(kind).first { $0.name == name }
    }

    public func entriesByName(_ kind: EntryKind) -> [String: ConfigEntry] {
        Dictionary(entries(kind).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func serialized() throws -> String {
        let text = try Yams.serialize(node: root, width: -1, allowUnicode: true)
        try Self.checkSize(text)
        return text
    }

    public var validationIssues: [String] {
        var issues: [String] = []
        if let version = root["apiVersion"], version.string != "v1" { issues.append("apiVersion must be v1.") }
        if let kind = root["kind"], kind.string != "Config" { issues.append("kind must be Config.") }
        if let current = root["current-context"], current.tag != Tag(.str) && current.null == nil {
            issues.append("current-context must be a string.")
        }
        let clusters = entries(.clusters), users = entries(.users), contexts = entries(.contexts)
        for cluster in clusters {
            if !Self.isServerAddress(cluster.value("server")) {
                issues.append("Cluster ‘\(cluster.name)’ needs a valid http or https server address.")
            }
            issues += Self.stringFieldIssues(cluster, keys: ["server", "certificate-authority", "certificate-authority-data", "tls-server-name", "proxy-url"])
            for key in ["insecure-skip-tls-verify", "disable-compression"] {
                if let value = cluster.fields[key], value.null == nil && value.tag != Tag(.bool) {
                    issues.append("\(key) in cluster ‘\(cluster.name)’ must be a boolean.")
                }
            }
        }
        for user in users {
            issues += Self.stringFieldIssues(user, keys:["username", "password", "token", "tokenFile", "client-certificate", "client-certificate-data", "client-key", "client-key-data", "as", "as-uid"])
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
        // Scanning the lists for each name took 19 ms at 100 entries.
        let clusterNames = Set(clusters.map(\.name)), userNames = Set(users.map(\.name))
        for context in contexts {
            let user = context.value("user")
            if !clusterNames.contains(context.value("cluster")) { issues.append("Context ‘\(context.name)’ refers to a missing cluster.") }
            if !user.isEmpty && !userNames.contains(user) { issues.append("Context ‘\(context.name)’ refers to a missing user.") }
            issues += Self.stringFieldIssues(context, keys: ["cluster", "user", "namespace"])
        }
        if !currentContext.isEmpty && !contexts.contains(where: { $0.name == currentContext }) {
            issues.append("The active context ‘\(currentContext)’ does not exist.")
        }
        var tags = Set<String>()
        Self.collectLostTags(in: root, into: &tags)
        issues += tags.sorted().map { "The YAML tag \($0) would be lost when saving. Remove it in the YAML editor." }
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

    private static let currentContextValue = try! NSRegularExpression(
        pattern: #"^current-context[ \t]*:[ \t]*("(?:[^"\\\r\n]|\\.)*"|'(?:[^'\r\n]|'')*'|(?!#)(?:(?![ \t]+#)[^\r\n])*)"#,
        options: .anchorsMatchLines)

    /// Changes only the active context in `yaml`, keeping comments and formatting, since a switch skips the diff.
    /// Returns nil unless the result parses back to exactly that change, as with JSON or a multi-line value.
    public static func settingCurrentContext(_ name: String, in yaml: String) -> String? {
        guard var expected = try? KubeDocument(yaml: yaml) else { return nil }
        if expected.currentContext == name { return yaml }
        guard (try? expected.setCurrentContext(name)) != nil,
              let line = try? Yams.serialize(node: Node([(Node("current-context"), string(name))]), width: -1, allowUnicode: true) else { return nil }
        let patched: String
        if let match = currentContextValue.firstMatch(in: yaml, range: NSRange(yaml.startIndex..., in: yaml)), let range = Range(match.range, in: yaml) {
            patched = yaml.replacingCharacters(in: range, with: line.trimmingCharacters(in: .newlines))
        } else {
            let lineBreak = yaml.contains("\r\n") ? "\r\n" : "\n"
            patched = (yaml.last?.isNewline == true ? yaml : yaml + lineBreak) + line.trimmingCharacters(in: .newlines) + lineBreak
        }
        return (try? KubeDocument(yaml: patched))?.isEquivalent(to: expected) == true ? patched : nil
    }

    /// Patches only fields explicitly supplied by the form, retaining every unfamiliar field.
    public mutating func update(_ kind: EntryKind, originalName: String?, name: String, fields: [String: String]) throws {
        if let issue = nameIssue(kind, name: name, originalName: originalName) { throw ConfigError.invalid(issue) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = entries(kind).map(\.node)
        let index = originalName.flatMap { old in list.firstIndex { $0["name"]?.string == old } }
        if let originalName, index == nil { throw ConfigError.missingEntry(originalName) }
        var node = index.map { list[$0] } ?? Node([(Node("name"), Self.string(trimmed)), (Node(kind.singular), .emptyMapping)])
        node["name"] = Self.string(trimmed)
        var body = node[kind.singular] ?? .emptyMapping
        // Sorted so that several new keys land in the same order on every run.
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            if value.isEmpty { body.remove(key) } else { body[key] = Self.string(value) }
        }
        node[kind.singular] = body
        if let index { list[index] = node } else { list.append(node) }
        root[kind.rawValue] = Node(list)
        if let originalName, originalName != trimmed {
            if kind == .contexts && currentContext == originalName { root["current-context"] = Self.string(trimmed) }
            if kind != .contexts, !entries(.contexts).isEmpty {
                var contexts = entries(.contexts).map(\.node)
                for index in contexts.indices where contexts[index]["context"]?[kind.singular]?.text == originalName {
                    contexts[index]["context"]?[kind.singular] = Self.string(trimmed)
                }
                root["contexts"] = Node(contexts)
            }
        }
    }

    public func nameIssue(_ kind: EntryKind, name: String, originalName: String?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a name." }
        if entries(kind).contains(where: { $0.name == trimmed && $0.name != originalName }) {
            return "A \(kind.singular) named ‘\(trimmed)’ already exists."
        }
        return nil
    }

    /// Clones the whole entry, so unfamiliar fields survive the copy.
    public mutating func duplicate(_ kind: EntryKind, name: String) throws -> String {
        guard var node = entry(kind, named: name)?.node else { throw ConfigError.missingEntry(name) }
        let copy = Self.uniqueName("\(name)-copy") { entry(kind, named: $0) != nil }
        node["name"] = Self.string(copy)
        root[kind.rawValue] = Node(entries(kind).map(\.node) + [node])
        return copy
    }

    public func referencingContexts(_ kind: EntryKind, name: String) -> [String] {
        guard kind != .contexts else { return [] }
        return entries(.contexts).filter { $0.value(kind.singular) == name }.map(\.name)
    }

    /// Groups references to a selection in one traversal, omitting entries that are not in use.
    public func referencingContexts(_ kind: EntryKind, names: Set<String>) -> [String: [String]] {
        guard kind != .contexts, !names.isEmpty else { return [:] }
        var references: [String: [String]] = [:]
        for context in entries(.contexts) {
            let name = context.value(kind.singular)
            if names.contains(name) { references[name, default: []].append(context.name) }
        }
        return references
    }

    public mutating func delete(_ kind: EntryKind, name: String) throws {
        guard entry(kind, named: name) != nil else { throw ConfigError.missingEntry(name) }
        let references = referencingContexts(kind, name: name)
        guard references.isEmpty else { throw ConfigError.referenced(name, references) }
        root[kind.rawValue] = Node(entries(kind).filter { $0.name != name }.map(\.node))
    }

    /// Deletes the entire selection or leaves the document untouched if any entry cannot be deleted.
    public mutating func delete(_ kind: EntryKind, names: Set<String>) throws {
        guard !names.isEmpty else { return }
        let entries = entries(kind)
        let existing = Set(entries.map(\.name))
        if let missing = names.subtracting(existing).sorted().first { throw ConfigError.missingEntry(missing) }
        let references = referencingContexts(kind, names: names)
        let blocked = references.keys.sorted().map { name in
            ConfigError.referenced(name, references[name, default: []].sorted()).localizedDescription
        }
        guard blocked.isEmpty else { throw ConfigError.invalid(blocked.joined(separator: "\n")) }
        if kind == .contexts, names.contains(currentContext) { try setCurrentContext("") }
        root[kind.rawValue] = Node(entries.filter { !names.contains($0.name) }.map(\.node))
    }

    public var hasRelativePaths: Bool {
        var copy = self
        return !copy.resolveRelativePaths(relativeTo: URL(fileURLWithPath: "/")).isEmpty
    }

    public mutating func resolveRelativePaths(relativeTo directory: URL) -> [String] {
        var resolutions: [String] = []
        func resolved(_ path: String) -> Node {
            let absolute = directory.appendingPathComponent(path).standardizedFileURL.path
            resolutions.append("\(path) → \(absolute)")
            return Self.string(absolute)
        }
        for kind in EntryKind.referenced where !entries(kind).isEmpty {
            var nodes = entries(kind).map(\.node)
            for index in nodes.indices {
                var fields = nodes[index][kind.singular]!
                for key in Self.fileKeys(kind) {
                    if let value = fields[key]?.text, !value.isEmpty, !value.isAbsolutePath { fields[key] = resolved(value) }
                }
                if kind == .users, let command = fields["exec"]?["command"]?.text, command.contains("/"), !command.isAbsolutePath {
                    fields["exec"]?["command"] = resolved(command)
                }
                nodes[index][kind.singular] = fields
            }
            root[kind.rawValue] = Node(nodes)
        }
        return resolutions
    }

    /// `base`, or the first of `base-2`, `base-3`, and so on that isn't taken.
    public static func uniqueName(_ base: String, isTaken: (String) -> Bool) -> String {
        var name = base, suffix = 2
        while isTaken(name) { name = "\(base)-\(suffix)"; suffix += 1 }
        return name
    }

    /// What kubectl's YAML parser reads as a number or boolean, once underscores are gone, while Yams reads a string.
    private static let kubectlNonString = try! NSRegularExpression(
        pattern: #"^(?:[yYnN]|[-+]?(?:0[bBoOxX][0-9a-fA-F]+|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?))$"#)

    /// Quotes a string that would otherwise read back as a number, boolean, or null, here or in kubectl, which refuses the whole file.
    internal static func string(_ value: String) -> Node {
        let digits = value.replacingOccurrences(of: "_", with: "")
        let isAmbiguous = kubectlNonString.firstMatch(in: digits, range: NSRange(digits.startIndex..., in: digits)) != nil
        return .scalar(isAmbiguous ? Node.Scalar(value, Tag(.str), .singleQuoted) : value.represented())
    }

    /// The emitter drops a `!!str` tag, so `!!str 123` has to be quoted or it would read back as a number.
    private static func keepingStrings(_ node: Node) -> Node {
        if let mapping = node.mapping {
            return Node(mapping.map { (keepingStrings($0.key), keepingStrings($0.value)) }, mapping.tag, mapping.style)
        }
        if let sequence = node.sequence { return Node(sequence.map(keepingStrings), sequence.tag, sequence.style) }
        guard node.tag == Tag(.str), node.scalar?.style == .plain, let text = node.string else { return node }
        return string(text)
    }

    /// The emitter writes no tags, which changes the value: kubectl decodes `!!binary` and reads `!!int "5"` as a number.
    /// Nodes built here carry the implicit tag, and no tag of their own.
    private static let strTag = Tag(.str), mapTag = Tag(.map), seqTag = Tag(.seq), implicitTag = Tag(.implicit)

    private static func collectLostTags(in node: Node, into tags: inout Set<String>) {
        if let mapping = node.mapping {
            if mapping.tag != mapTag, mapping.tag != implicitTag { tags.insert(displayName(of: mapping.tag)) }
            for pair in mapping { collectLostTags(in: pair.value, into: &tags) }
        } else if let sequence = node.sequence {
            if sequence.tag != seqTag, sequence.tag != implicitTag { tags.insert(displayName(of: sequence.tag)) }
            for value in sequence { collectLostTags(in: value, into: &tags) }
        } else if let scalar = node.scalar, scalar.tag != strTag, scalar.tag != implicitTag {
            let implied = scalar.style == .plain ? Tag(resolver.resolveTag(of: Node.scalar(Node.Scalar(scalar.string)))) : strTag
            if scalar.tag != implied { tags.insert(displayName(of: scalar.tag)) }
        }
    }

    private static func displayName(of tag: Tag) -> String {
        tag.description.replacingOccurrences(of: "tag:yaml.org,2002:", with: "!!")
    }

    private static func checkSize(_ text: String) throws {
        guard text.utf8.count <= maximumByteCount else { throw ConfigError.invalid("Configuration exceeds the 16 MB size limit.") }
    }

    /// Accepts a bare `host:port` too, for which kubectl picks the scheme.
    private static func isServerAddress(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace),
              let url = URL(string: text.contains("://") ? text : "https://" + text),
              let scheme = url.scheme?.lowercased() else { return false }
        return ["https", "http"].contains(scheme) && url.host?.isEmpty == false
    }

    private static func fileKeys(_ kind: EntryKind) -> [String] {
        kind == .clusters ? ["certificate-authority"] : ["client-certificate", "client-key", "tokenFile"]
    }

    private static func stringFieldIssues(_ entry: ConfigEntry, keys: [String]) -> [String] {
        let fields = entry.fields
        return keys.compactMap { key in
            guard let value = fields[key], value.null == nil, value.tag != Tag(.str) else { return nil }
            return "\(key) in \(entry.kind.singular) ‘\(entry.name)’ must be a string."
        }
    }

    private static func checkMappings(_ node: Node, depth: Int, nodeCount: inout Int) throws {
        guard depth < 64 else { throw ConfigError.invalid("YAML nesting exceeds 64 levels.") }
        nodeCount += 1
        guard nodeCount <= maximumNodeCount else { throw ConfigError.invalid("YAML expands to more than a million values.") }
        if let mapping = node.mapping {
            for pair in mapping {
                // A plain << carries YAML's merge tag, so this comes before the string check.
                guard pair.key.string != "<<" else { throw ConfigError.invalid("YAML merge keys (<<) are not supported. Expand the mapping before editing.") }
                guard pair.key.string != nil, pair.key.tag == Tag(.str) else {
                    throw ConfigError.invalid("YAML mapping keys must be strings.")
                }
                try checkMappings(pair.value, depth: depth + 1, nodeCount: &nodeCount)
            }
        } else if let sequence = node.sequence {
            for value in sequence { try checkMappings(value, depth: depth + 1, nodeCount: &nodeCount) }
        }
    }
}

extension String {
    /// Whether client-go takes this path as it stands. NSString's check of the same name also accepts `~`, which client-go doesn't expand.
    var isAbsolutePath: Bool { hasPrefix("/") }
}

extension Node {
    static var emptyMapping: Node { Node([] as [(Node, Node)]) }

    /// The scalar's text, or nil for a YAML null, which `string` reads back as "null" or "~".
    var text: String? { tag == Tag(.null) ? nil : string }

    mutating func remove(_ key: String) {
        guard var mapping else { return }
        mapping[key] = nil
        self = .mapping(mapping)
    }

    /// Equality that ignores the order of mapping keys, which carries no meaning in a kubeconfig.
    func isEquivalent(to other: Node) -> Bool {
        if let left = mapping, let right = other.mapping {
            guard left.count == right.count else { return false }
            return left.allSatisfy { pair in right[pair.key].map { pair.value.isEquivalent(to: $0) } ?? false }
        }
        if let left = sequence, let right = other.sequence {
            return left.count == right.count && zip(left, right).allSatisfy { $0.isEquivalent(to: $1) }
        }
        return self == other
    }
}
