#if DEBUG
import AppKit
import Foundation
import KubeConfigCore

/// Captures the real native view using an explicitly supplied sample file, never the user's kubeconfig.
@MainActor enum ScreenshotCapture {
    private static var started = false

    static func startIfRequested(model: AppModel) {
        guard !started, let options = model.launchOptions, let folder = options.captureDirectory,
              let explicitURL = options.configurationURL, model.snapshot?.url == explicitURL,
              model.snapshot?.exists == true else { return }
        started = true
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.title == "KubeConfig" }) else {
                NSApplication.shared.terminate(nil); return
            }
            NSApp.appearance = NSAppearance(named: .aqua)
            window.appearance = NSAppearance(named: .aqua)
            window.setContentSize(NSSize(width: 1120, height: 740))
            try? await Task.sleep(for: .milliseconds(400))
            save(window, to: folder.appendingPathComponent("contexts-light.png"))
            NSApp.appearance = NSAppearance(named: .darkAqua)
            window.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(400))
            save(window, to: folder.appendingPathComponent("contexts-dark.png"))
            NSApp.appearance = NSAppearance(named: .aqua)
            window.appearance = NSAppearance(named: .aqua)
            window.setContentSize(NSSize(width: 920, height: 600))
            try? await Task.sleep(for: .milliseconds(400))
            save(window, to: folder.appendingPathComponent("contexts-compact.png"))
            window.setContentSize(NSSize(width: 1120, height: 740))
            model.selectSection(.clusters)
            try? await Task.sleep(for: .milliseconds(300))
            save(window, to: folder.appendingPathComponent("cluster.png"))
            model.selectSection(.users)
            try? await Task.sleep(for: .milliseconds(300))
            save(window, to: folder.appendingPathComponent("user.png"))
            model.selectSection(.backups)
            try? await Task.sleep(for: .milliseconds(300))
            save(window, to: folder.appendingPathComponent("backups.png"))
            if let snapshot = model.snapshot, let data = snapshot.data {
                let exampleBackup = BackupRecord(configurationPath: snapshot.resolvedURL.path, contents: data)
                model.records = [exampleBackup]
                model.selectedBackupID = exampleBackup.id
                try? await Task.sleep(for: .milliseconds(300))
                save(window, to: folder.appendingPathComponent("backup-rollback.png"))
                model.search = "no-matching-backup"
                try? await Task.sleep(for: .milliseconds(300))
                save(window, to: folder.appendingPathComponent("backup-search-empty.png"))
                model.search = ""
            }
            model.selectSection(.contexts)
            model.editor?.fields["namespace"] = "preview-namespace"
            _ = try? model.flushEditor()
            model.requestReview()
            try? await Task.sleep(for: .milliseconds(500))
            if let sheet = window.attachedSheet { save(sheet, to: folder.appendingPathComponent("review-diff.png")) }
            model.cancelReview()
            try? await Task.sleep(for: .milliseconds(400))
            let imported = (model.snapshot?.text ?? "").replacingOccurrences(of: "dev.example.invalid", with: "imported.example.invalid")
            try? model.prepareImport(yaml: imported, directory: model.snapshot?.url.deletingLastPathComponent())
            try? await Task.sleep(for: .milliseconds(500))
            if let sheet = window.attachedSheet { save(sheet, to: folder.appendingPathComponent("import.png")) }
            model.showImport = false; model.importPlan = nil
            model.discardDraft()
            try? await Task.sleep(for: .milliseconds(300))
            NSApplication.shared.terminate(nil)
        }
    }

    private static func save(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }
}
#endif
