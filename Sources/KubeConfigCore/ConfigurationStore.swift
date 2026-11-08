import CryptoKit
import Darwin
import Foundation

public protocol FileAccess {
    func read(_ url: URL, maximumByteCount: Int) throws -> Data?
    func writeAtomically(_ data: Data, to url: URL) throws
    func replaceIfUnchanged(_ data: Data, at url: URL, expectedContents: Data?) throws
}

public extension FileAccess {
    fileprivate func matches(_ expected: Data?, at url: URL) throws -> Bool {
        do { return try read(url, maximumByteCount: expected?.count ?? 0) == expected }
        catch let error as POSIXError where error.code == .EFBIG || error.code == .EFTYPE { return false }
    }

    func replaceIfUnchanged(_ data: Data, at url: URL, expectedContents: Data?) throws {
        guard try matches(expectedContents, at: url) else { throw ConfigError.externalChange }
        try writeAtomically(data, to: url)
    }
}

public struct LocalFileAccess: FileAccess {
    public init() {}

    private var lastError: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    /// Bounds regular-file reads before allocating their contents, without waiting on pipes or devices.
    public func read(_ url: URL, maximumByteCount: Int) throws -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw lastError
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw lastError
        }
        guard information.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        guard information.st_size <= maximumByteCount else { throw POSIXError(.EFBIG) }
        var data = Data()
        while data.count <= maximumByteCount {
            let chunk = try handle.read(upToCount: min(64 * 1024, maximumByteCount - data.count + 1)) ?? Data()
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
        throw POSIXError(.EFBIG)
    }

    public func writeAtomically(_ data: Data, to url: URL) throws {
        try write(data, to: url, expected: nil)
    }

    public func replaceIfUnchanged(_ data: Data, at url: URL, expectedContents: Data?) throws {
        try write(data, to: url, expected: .some(expectedContents))
    }

    /// A double optional distinguishes an unconditional export from expecting a missing destination.
    private func write(_ data: Data, to url: URL, expected: Data??) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let temporary = directory.appendingPathComponent(".kubeconfig-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw lastError }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer {
            try? handle.close()
            try? manager.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        if let expected, try !matches(expected, at: url) { throw ConfigError.externalChange }
        // rename(2) replaces the destination atomically, leaving no partial kubeconfig.
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw lastError }
        let parent = Darwin.open(directory.path, O_RDONLY)
        if parent >= 0 { _ = Darwin.fsync(parent); Darwin.close(parent) }
    }
}

public struct FileSnapshot: Equatable {
    public let url: URL
    public let resolvedURL: URL
    public let data: Data?
    /// Stored, because the app compares it with the draft several times per view update.
    public let text: String
    public var exists: Bool { data != nil }

    init(url: URL, resolvedURL: URL, data: Data?) {
        self.url = url
        self.resolvedURL = resolvedURL
        self.data = data
        text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// What a backup list shows. It's saved beside each backup, so that listing never reads file contents.
public struct BackupSummary: Codable, Identifiable, Equatable {
    public let id: String
    public let configurationPath: String
    public let createdAt: Date
    public let byteCount: Int
}

public struct BackupListing: Equatable {
    public var records: [BackupSummary] = []
    /// Files that failed their checks. They stay in the folder, left out of `records`.
    public var damagedCount = 0
}

public struct BackupRecord: Codable, Identifiable, Equatable {
    public let id: String
    public let configurationPath: String
    public let createdAt: Date
    public let contents: Data
    public let checksum: String
    public var summary: BackupSummary {
        BackupSummary(id: id, configurationPath: configurationPath, createdAt: createdAt, byteCount: contents.count)
    }

    public init(configurationPath: String, contents: Data, createdAt: Date = Date()) {
        id = UUID().uuidString
        self.configurationPath = configurationPath
        self.createdAt = createdAt
        self.contents = contents
        checksum = Self.hash(contents)
    }

    internal static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct BackupStore {
    public let directory: URL
    private let files: any FileAccess

    public init(directory: URL, files: any FileAccess = LocalFileAccess()) {
        self.directory = directory
        self.files = files
    }

    public static var applicationDefault: BackupStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return BackupStore(directory: root.appendingPathComponent("KubeConfig/Backups", isDirectory: true))
    }

    public func location(for configuration: URL) -> URL {
        directory.appendingPathComponent(BackupRecord.hash(Data(configuration.standardizedFileURL.path.utf8)), isDirectory: true)
    }

    public func records(for configuration: URL) throws -> BackupListing {
        let folder = location(for: configuration)
        var listing = BackupListing()
        guard FileManager.default.fileExists(atPath: folder.path) else { return listing }
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        for url in urls {
            if let summary = savedSummary(of: url, for: configuration) ?? rebuiltSummary(of: url, for: configuration) {
                listing.records.append(summary)
            } else { listing.damagedCount += 1 }
        }
        listing.records.sort { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt }
        return listing
    }

    /// Reads a listed backup in full. A summary says nothing about its file, so this is where damage shows up.
    public func record(_ summary: BackupSummary, for configuration: URL) throws -> BackupRecord {
        try verifiedRecord(at: fileURL(of: summary.id, for: configuration), for: configuration)
    }

    /// A backup already gone from the folder still loses its summary, so nothing is left behind.
    public func remove(_ summary: BackupSummary, for configuration: URL) throws {
        let url = fileURL(of: summary.id, for: configuration)
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile {}
        try? FileManager.default.removeItem(at: summaryURL(of: url))
    }

    private func fileURL(of id: String, for configuration: URL) -> URL {
        location(for: configuration).appendingPathComponent(id + ".json")
    }

    private func summaryURL(of url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("meta") }

    private func savedSummary(of url: URL, for configuration: URL) -> BackupSummary? {
        guard let data = try? files.read(summaryURL(of: url), maximumByteCount: 64 * 1024),
              let summary = try? JSONDecoder().decode(BackupSummary.self, from: data),
              summary.configurationPath == configuration.standardizedFileURL.path,
              summary.id == url.deletingPathExtension().lastPathComponent else { return nil }
        return summary
    }

    /// Covers backups saved before summaries existed, and summaries that were lost.
    private func rebuiltSummary(of url: URL, for configuration: URL) -> BackupSummary? {
        guard let record = try? verifiedRecord(at: url, for: configuration) else { return nil }
        try? files.writeAtomically(JSONEncoder().encode(record.summary), to: summaryURL(of: url))
        return record.summary
    }

    private func verifiedRecord(at url: URL, for configuration: URL) throws -> BackupRecord {
        // Base64 and escaped slashes can expand a 16 MB payload to nearly three times its size.
        guard let data = try? files.read(url, maximumByteCount: KubeDocument.maximumByteCount * 3 + 64 * 1024),
              let record = try? JSONDecoder().decode(BackupRecord.self, from: data),
              record.configurationPath == configuration.standardizedFileURL.path,
              BackupRecord.hash(record.contents) == record.checksum,
              record.id == url.deletingPathExtension().lastPathComponent else {
            throw ConfigError.backupFailure("This backup is damaged or belongs to another configuration. Reveal the backup folder to inspect it.")
        }
        return record
    }

    /// Called only after the destination was successfully replaced.
    @discardableResult
    public func savePrevious(_ contents: Data?, for configuration: URL, retention: Int, now: Date = Date()) throws -> BackupRecord? {
        guard retention >= 0 else { throw ConfigError.invalid("Backup retention cannot be negative.") }
        guard retention > 0 else {
            // Zero disables creation and, on successful Apply, removes previous rolling backups.
            try prune(for: configuration, keeping: 0)
            return nil
        }
        var saved: BackupRecord?
        if let contents {
            let record = BackupRecord(configurationPath: configuration.standardizedFileURL.path, contents: contents, createdAt: now)
            let folder = location(for: configuration)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let url = fileURL(of: record.id, for: configuration)
            try files.writeAtomically(JSONEncoder().encode(record), to: url)
            try? files.writeAtomically(JSONEncoder().encode(record.summary), to: summaryURL(of: url))
            saved = record
        }
        // The backup is safe by now.
        try? prune(for: configuration, keeping: retention)
        return saved
    }

    public func rollbackText(_ record: BackupRecord, for configuration: URL) throws -> String {
        guard record.configurationPath == configuration.standardizedFileURL.path,
              BackupRecord.hash(record.contents) == record.checksum else {
            throw ConfigError.backupFailure("This backup does not match the open configuration or failed its integrity check.")
        }
        guard let text = String(data: record.contents, encoding: .utf8) else { throw ConfigError.invalid("The backup is not UTF-8 text.") }
        return text
    }

    /// A damaged backup stays for inspection, so each one is verified before it goes.
    private func prune(for configuration: URL, keeping retention: Int) throws {
        for summary in try records(for: configuration).records.dropFirst(retention) where (try? record(summary, for: configuration)) != nil {
            try remove(summary, for: configuration)
        }
    }
}

public struct ApplyResult {
    public let snapshot: FileSnapshot
    public let backup: BackupRecord?
    public let warning: String?
    /// If backup persistence failed after Apply, retain these bytes for explicit recovery/export.
    public let recoveryContents: Data?
}

public struct ConfigurationStore {
    private let files: any FileAccess
    public let backups: BackupStore

    public init(backups: BackupStore = .applicationDefault, files: any FileAccess = LocalFileAccess()) {
        self.backups = backups
        self.files = files
    }

    public func load(_ url: URL) throws -> FileSnapshot {
        let logical = url.standardizedFileURL
        let resolved = Self.resolved(logical)
        let data: Data?
        do { data = try files.read(resolved, maximumByteCount: KubeDocument.maximumByteCount) }
        catch let error as POSIXError where error.code == .EFBIG {
            throw ConfigError.invalid("Configuration exceeds the 16 MB size limit.")
        }
        if let data, String(data: data, encoding: .utf8) == nil { throw ConfigError.invalid("The configuration must be UTF-8 text.") }
        return FileSnapshot(url: logical, resolvedURL: resolved, data: data)
    }

    public func hasChanged(_ snapshot: FileSnapshot) throws -> Bool {
        if Self.resolved(snapshot.url) != snapshot.resolvedURL { return true }
        return try !files.matches(snapshot.data, at: snapshot.resolvedURL)
    }

    /// `resolvingSymlinksInPath` stops at a dangling link, and writing there would replace the link.
    private static func resolved(_ url: URL) -> URL {
        var path = url.resolvingSymlinksInPath()
        // Bounded, because links that form a loop never arrive anywhere.
        for _ in 0..<32 {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path.path) else { break }
            path = URL(fileURLWithPath: target, relativeTo: path.deletingLastPathComponent()).absoluteURL.resolvingSymlinksInPath()
        }
        return path
    }

    public func apply(_ document: KubeDocument, over snapshot: FileSnapshot, retention: Int) throws -> ApplyResult {
        try document.validate()
        guard retention >= 0 else { throw ConfigError.invalid("Backup retention cannot be negative.") }
        let data = Data(try document.serialized().utf8)
        guard try !hasChanged(snapshot) else { throw ConfigError.externalChange }
        if data == snapshot.data { return ApplyResult(snapshot: snapshot, backup: nil, warning: nil, recoveryContents: nil) }
        // Check as late as possible, after serialization/validation and immediately before replacement.
        try files.replaceIfUnchanged(data, at: snapshot.resolvedURL, expectedContents: snapshot.data)
        let next = FileSnapshot(url: snapshot.url, resolvedURL: snapshot.resolvedURL, data: data)
        do {
            let backup = try backups.savePrevious(snapshot.data, for: snapshot.resolvedURL, retention: retention)
            return ApplyResult(snapshot: next, backup: backup, warning: nil, recoveryContents: nil)
        } catch {
            // The Apply succeeded. Never report it as a failed write or roll back over a potentially concurrent editor.
            return ApplyResult(snapshot: next, backup: nil,
                               warning: "Configuration applied, but its backup could not be saved. Export the previous contents now to keep an undo point.",
                               recoveryContents: snapshot.data)
        }
    }

    /// Writes only the active context, with no backup, since switching back undoes it.
    /// Returns nil when the file can't take the patch, leaving the switch to go through Apply.
    public func switchContext(to name: String, over snapshot: FileSnapshot) throws -> FileSnapshot? {
        guard let text = KubeDocument.settingCurrentContext(name, in: snapshot.text) else { return nil }
        guard try !hasChanged(snapshot) else { throw ConfigError.externalChange }
        let data = Data(text.utf8)
        if data == snapshot.data { return snapshot }
        try files.replaceIfUnchanged(data, at: snapshot.resolvedURL, expectedContents: snapshot.data)
        return FileSnapshot(url: snapshot.url, resolvedURL: snapshot.resolvedURL, data: data)
    }
}
