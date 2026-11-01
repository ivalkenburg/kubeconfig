import Foundation
import Yams

/// The exact configuration reviewed and saved, including a snapshot of referenced file contents.
public struct ContextExportPlan {
    public let yaml: String
    public let sourceFiles: Set<URL>

    public init(document source: KubeDocument, contextNames: Set<String>, sourceDirectory: URL,
                readFile: (URL) throws -> Data? = { try LocalFileAccess().read($0, maximumByteCount: KubeDocument.maximumByteCount) }) throws {
        var result = try source.selectingContexts(contextNames)
        var sourceFiles: Set<URL> = []
        var contents: [URL: Data] = [:]
        var embeddedBytes = 0

        func reserve(_ byteCount: Int) throws {
            guard byteCount <= KubeDocument.maximumByteCount - embeddedBytes else {
                throw ConfigError.invalid("The embedded files would exceed the 16 MB configuration size limit.")
            }
            embeddedBytes += byteCount
        }

        func read(_ path: String, entry: ConfigEntry, field: String) throws -> (URL, Data) {
            let url = (path.isAbsolutePath ? URL(fileURLWithPath: path) : sourceDirectory.appendingPathComponent(path)).standardizedFileURL
            let resolved = url.resolvingSymlinksInPath()
            let description = "\(field) for \(entry.kind.singular) ‘\(entry.name)’ at \(url.path)"
            // Underlying errors can contain more than the file location; don't include file contents.
            let unreadable = ConfigError.invalid("Could not read \(description). Check that the file exists and is readable, then retry export.")
            let data: Data
            do {
                guard let found = try contents[resolved] ?? readFile(resolved) else { throw unreadable }
                data = found
            } catch let error as POSIXError where error.code == .EFBIG {
                throw ConfigError.invalid("The file for \(description) exceeds the 16 MB size limit.")
            } catch let error as POSIXError where error.code == .EFTYPE {
                throw ConfigError.invalid("Expected a regular file for \(description). Pipes and devices cannot be embedded.")
            } catch { throw unreadable }
            guard !data.isEmpty else { throw ConfigError.invalid("The file for \(description) is empty.") }
            guard data.count <= KubeDocument.maximumByteCount else {
                throw ConfigError.invalid("The file for \(description) exceeds the 16 MB size limit.")
            }
            contents[resolved] = data
            sourceFiles.formUnion([url, resolved])
            return (url, data)
        }

        for kind in EntryKind.referenced {
            var nodes: [Node] = []
            for entry in result.entries(kind) {
                var node = entry.node
                var fields = entry.fields
                let pairs = kind == .clusters
                    ? [("certificate-authority", "certificate-authority-data")]
                    : [("client-certificate", "client-certificate-data"), ("client-key", "client-key-data")]
                for (pathKey, dataKey) in pairs {
                    if let existing = fields[dataKey]?.text, !existing.isEmpty {
                        // Embedded data already wins over the file, even if that file no longer exists.
                        fields.remove(pathKey)
                    } else if let path = fields[pathKey]?.text, !path.isEmpty {
                        let (_, data) = try read(path, entry: entry, field: pathKey)
                        try reserve(((data.count + 2) / 3) * 4)
                        fields[dataKey] = KubeDocument.string(data.base64EncodedString())
                        fields.remove(pathKey)
                    }
                }
                if kind == .users, let path = fields["tokenFile"]?.text, !path.isEmpty {
                    let (url, data) = try read(path, entry: entry, field: "tokenFile")
                    guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                        throw ConfigError.invalid("Token file for user ‘\(entry.name)’ at \(url.path) must contain a nonempty UTF-8 token.")
                    }
                    // client-go uses the last successfully read token file value ahead of a static token.
                    try reserve(token.utf8.count)
                    fields["token"] = KubeDocument.string(token)
                    fields.remove("tokenFile")
                }
                node[kind.singular] = fields
                nodes.append(node)
            }
            result.root[kind.rawValue] = Node(nodes)
        }
        try result.validate()
        yaml = try result.serialized()
        self.sourceFiles = sourceFiles
    }
}

extension KubeDocument {
    /// Copies only selected contexts and their dependencies, retaining whole entry nodes and no root metadata.
    public func selectingContexts(_ names: Set<String>) throws -> KubeDocument {
        guard !names.isEmpty else { throw ConfigError.invalid("Select at least one context to export.") }
        let contexts = entries(.contexts).filter { names.contains($0.name) }
        if let missing = names.subtracting(contexts.map(\.name)).sorted().first {
            throw ConfigError.missingEntry(missing)
        }
        var result = Self.empty
        result.root["contexts"] = Node(contexts.map(\.node))
        for kind in EntryKind.referenced {
            let required = Set(contexts.map { $0.value(kind.singular) }.filter { !$0.isEmpty })
            result.root[kind.rawValue] = Node(entries(kind).filter { required.contains($0.name) }.map(\.node))
        }
        let active = contexts.count == 1 ? contexts[0].name : names.contains(currentContext) ? currentContext : ""
        try result.setCurrentContext(active)
        try result.validate()
        return result
    }
}
