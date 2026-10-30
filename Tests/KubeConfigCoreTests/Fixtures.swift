import Foundation
import XCTest
@testable import KubeConfigCore

enum Fixtures {
    static let yaml = """
    apiVersion: v1
    kind: Config
    clusters:
    - name: dev
      cluster:
        server: https://dev.example.invalid
        certificate-authority: certs/ca.pem
        extensions:
        - name: vendor
          extension:
            retries: 3
            enabled: true
            label: "true"
    users:
    - name: developer
      user:
        token: fixture-secret-token
        vendor-field: retained
    contexts:
    - name: development
      context:
        cluster: dev
        user: developer
        namespace: default
        extensions:
        - name: ui
          extension:
            color: blue
    current-context: development
    vendor-root:
      enabled: true
    """ + "\n"

    static func document() throws -> KubeDocument { try KubeDocument(yaml: yaml) }
    static func changed(namespace: String = "staging") throws -> KubeDocument {
        var doc = try document()
        try doc.update(.contexts, originalName: "development", name: "development", fields: ["namespace": namespace])
        return doc
    }
}

class FileTestCase: XCTestCase {
    var directory: URL!
    var config: URL!
    var backups: BackupStore!
    var store: ConfigurationStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("KubeConfigTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        config = directory.appendingPathComponent("config")
        backups = BackupStore(directory: directory.appendingPathComponent("backups"))
        store = ConfigurationStore(backups: backups)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func writeInitial() throws { try Data(Fixtures.yaml.utf8).write(to: config) }
    func diskText() throws -> String { try String(contentsOf: config, encoding: .utf8) }
}
