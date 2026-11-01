import Foundation
import Yams

/// How to start k9s on one context of a file, without it depending on the active context.
public struct K9sLaunch {
    public let executable: String
    public let arguments: [String]
    public let environment: [String]

    /// Where package managers install k9s, for when the login shell can't be asked.
    static let fallbackDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/run/current-system/sw/bin"]
    private static let pathMarker = "__KUBECONFIG_PATH__"

    /// Prints the shell's `PATH` between markers, since startup files can print anything around it.
    public static let pathProbeCommand = "printf '\(pathMarker)'; printenv PATH; printf '\(pathMarker)'"

    public static func path(fromProbeOutput output: String) -> String? {
        let parts = output.components(separatedBy: pathMarker)
        guard parts.count >= 3 else { return nil }
        let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Returns nil when k9s can't be found. Apps opened from Finder don't inherit the shell's `PATH`, so `loginPath`
    /// goes first and also reaches k9s itself, which needs it to find credential plugins.
    /// `cluster` is the one the context points to, which k9s uses to find what it saved for the context.
    public init?(kubeconfig: URL, context: String, cluster: String = "", loginPath: String?, inherited: [String: String],
                 isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) {
        var directories: [String] = []
        for directory in [loginPath, inherited["PATH"]].compactMap({ $0 }).flatMap({ $0.components(separatedBy: ":") }) + Self.fallbackDirectories
        where !directory.isEmpty && !directories.contains(directory) { directories.append(directory) }
        guard let executable = directories.map({ ($0 as NSString).appendingPathComponent("k9s") }).first(where: isExecutable) else { return nil }
        self.executable = executable
        let startingView = K9sSavedView.isContextList(cluster: cluster, context: context, environment: inherited) ? ["--command", "pods"] : []
        arguments = ["--kubeconfig", kubeconfig.path, "--context", context, "--splashless", "--logoless"] + startingView
        var variables = inherited
        variables["PATH"] = directories.joined(separator: ":")
        variables["KUBECONFIG"] = kubeconfig.path
        variables["TERM"] = "xterm-256color"
        variables["COLORTERM"] = "truecolor"
        // Apps opened from Finder have no locale, and terminal programs misjudge wide characters without one.
        if variables["LANG"] == nil { variables["LANG"] = "en_US.UTF-8" }
        environment = variables.map { "\($0.key)=\($0.value)" }.sorted()
    }
}

/// Reads the view k9s saved for a context, which it reopens on the next start. A context that failed to connect is
/// saved on the context list, and would stay there after the connection recovers. Only ever reads k9s's files.
public enum K9sSavedView {
    /// Follows k9s's own lookup: `K9S_CONFIG_DIR`, then `XDG_DATA_HOME`, then the macOS default.
    static func file(cluster: String, context: String, environment: [String: String]) -> URL {
        func directory(_ name: String) -> URL? {
            environment[name].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        }
        let home = directory("HOME") ?? FileManager.default.homeDirectoryForCurrentUser
        let root = directory("K9S_CONFIG_DIR")
            ?? (directory("XDG_DATA_HOME") ?? home.appendingPathComponent("Library/Application Support")).appendingPathComponent("k9s")
        return root.appendingPathComponent("clusters").appendingPathComponent(folderName(cluster))
            .appendingPathComponent(folderName(context)).appendingPathComponent("config.yaml")
    }

    /// False when there's no saved view or it can't be read, which leaves the choice to k9s.
    public static func isContextList(cluster: String, context: String, environment: [String: String]) -> Bool {
        guard !cluster.isEmpty,
              let text = try? String(contentsOf: file(cluster: cluster, context: context, environment: environment), encoding: .utf8),
              let saved = (try? Yams.load(yaml: text)) as? [String: Any],
              let k9s = saved["k9s"] as? [String: Any], let view = k9s["view"] as? [String: Any],
              let active = view["active"] as? String else { return false }
        // k9s saves a namespace after some views, as in "v1/pods default".
        return ["contexts", "context", "ctx"].contains(active.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "")
    }

    private static func folderName(_ name: String) -> String {
        name.replacingOccurrences(of: "[:/]+", with: "-", options: .regularExpression)
    }
}

/// Finds the `PATH` of the user's login shell. Interactive too, since many people only set it in `.zshrc`.
public enum LoginShell {
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var found: String?

        var path: String? { lock.withLock { found } }

        func append(_ chunk: Data) -> String? {
            lock.withLock {
                data.append(chunk)
                found = K9sLaunch.path(fromProbeOutput: String(decoding: data, as: UTF8.self))
                return found
            }
        }
    }

    public static func path(timeout: TimeInterval = 5) async -> String? {
        await path(shell: userShell, timeout: timeout)
    }

    static func path(shell: String, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: probe(shell: shell, timeout: timeout))
            }
        }
    }

    /// Stops at the closing marker rather than end of file, since anything a startup file leaves running holds the pipe open.
    /// A hung shell gets SIGKILL because interactive shells ignore SIGTERM.
    private static func probe(shell: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", K9sLaunch.pathProbeCommand]
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let output = Output()
        let finished = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if output.append(chunk) != nil || chunk.isEmpty { finished.signal() }
        }
        defer {
            reader.readabilityHandler = nil
            try? reader.close()
        }
        guard (try? process.run()) != nil else { return nil }
        _ = finished.wait(timeout: .now() + timeout)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        return output.path
    }

    private static var userShell: String {
        getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) } ?? "/bin/zsh"
    }
}

/// How a context's connection differs between two versions of a configuration.
public enum ContextConnectionChange: Equatable {
    case unchanged
    case changed
    /// The newer version has no context by that name, which is also how a rename looks.
    case removed
}

extension KubeDocument {
    /// Compares the context and the cluster and user it points to, which is everything a connection reads.
    /// Other entries and the active context don't count.
    public static func connectionChange(ofContext name: String, from old: KubeDocument?, to new: KubeDocument?) -> ContextConnectionChange {
        guard let new, let newContext = new.entry(.contexts, named: name) else { return .removed }
        guard let old, let oldContext = old.entry(.contexts, named: name), oldContext.node.isEquivalent(to: newContext.node) else { return .changed }
        for kind in [EntryKind.clusters, .users] {
            let reference = newContext.value(kind.singular)
            let before = old.entry(kind, named: reference), after = new.entry(kind, named: reference)
            switch (before, after) {
            case (nil, nil): continue
            case let (before?, after?) where before.node.isEquivalent(to: after.node): continue
            default: return .changed
            }
        }
        return .unchanged
    }
}
