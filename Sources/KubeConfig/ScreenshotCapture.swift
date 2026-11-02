#if DEBUG
import AppKit
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
            func wait(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
            await wait(1000)
            guard let window = model.window else { NSApplication.shared.terminate(nil); return }
            @MainActor func setAppearance(_ name: NSAppearance.Name) {
                NSApp.appearance = NSAppearance(named: name)
                window.appearance = NSAppearance(named: name)
            }
            @MainActor func shot(_ name: String, after milliseconds: Int = 300) async {
                await wait(milliseconds)
                save(window, to: folder.appendingPathComponent("\(name).png"))
            }
            @MainActor func sheetShot(_ name: String, after milliseconds: Int) async {
                await wait(milliseconds)
                if let sheet = window.attachedSheet { save(sheet, to: folder.appendingPathComponent("\(name).png")) }
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            setAppearance(.aqua)
            window.setContentSize(NSSize(width: 1120, height: 740))
            await shot("contexts-light", after: 400)
            setAppearance(.darkAqua)
            await shot("contexts-dark", after: 400)
            setAppearance(.aqua)
            window.setContentSize(NSSize(width: 920, height: 600))
            await shot("contexts-compact", after: 400)
            window.setContentSize(NSSize(width: 1120, height: 740))
            model.selectSection(.clusters)
            await shot("cluster")
            model.selectSection(.users)
            await shot("user")
            model.selectSection(.backups)
            await shot("backups")
            if let snapshot = model.snapshot, let data = snapshot.data,
               let example = try? model.store.backups.savePrevious(data, for: snapshot.resolvedURL, retention: BackupRetention.range.upperBound) {
                model.refreshBackups()
                model.selectedBackupID = example.id
                await shot("backup-rollback")
                model.wrapsYAML = true
                await shot("backup-wrapped")
                model.wrapsYAML = false
                await wait(300)
                model.search = "no-matching-backup"
                await shot("backup-search-empty")
                model.search = ""
                try? model.store.backups.remove(example.summary, for: snapshot.resolvedURL)
                model.refreshBackups()
            }
            model.selectSection(.contexts)
            model.selectContexts(["development", "production-eu"])
            await shot("contexts-multiple")
            window.setContentSize(NSSize(width: 920, height: 600))
            await shot("contexts-multiple-compact")
            model.requestContextExport()
            await sheetShot("context-export", after: 500)
            model.closeContextExport()
            await wait(500)
            setAppearance(.darkAqua)
            model.requestContextExport()
            await sheetShot("context-export-dark", after: 500)
            model.closeContextExport()
            await wait(500)
            setAppearance(.aqua)
            window.setContentSize(NSSize(width: 1120, height: 740))
            model.selectEntry("development")
            model.columnVisibility = .detailOnly
            await shot("sidebar-collapsed", after: 500)
            model.toggleRawEditor()
            await shot("yaml-sidebar-collapsed", after: 500)
            model.toggleRawEditor()
            await shot("forms-sidebar-collapsed", after: 500)
            model.columnVisibility = .all
            await wait(500)
            model.editor?.fields["namespace"] = "preview-namespace"
            _ = try? model.flushEditor()
            await shot("contexts-pending")
            model.showRaw = true
            await shot("yaml", after: 500)
            model.wrapsYAML = true
            await shot("yaml-wrapped", after: 400)
            model.wrapsYAML = false
            model.showRaw = false
            await wait(300)
            model.addEntry()
            model.editor?.fields["cluster"] = ""
            model.commitForm()
            await shot("issues", after: 400)
            model.deleteEntry()
            model.showImportSource = true
            await sheetShot("import-source", after: 500)
            model.showImportSource = false
            await wait(500)
            model.selectEntry("production-eu")
            // Staged directly, since Make Active could write to the file.
            if var next = model.document {
                try? next.setCurrentContext("production-eu")
                try? model.stage(next, message: "Context switch staged")
            }
            model.requestReview()
            await sheetShot("review-diff", after: 1000)
            model.cancelReview()
            await wait(400)
            let imported = (model.snapshot?.text ?? "").replacingOccurrences(of: "dev.example.invalid", with: "imported.example.invalid")
            try? model.prepareImport(yaml: imported, directory: model.snapshot?.url.deletingLastPathComponent())
            await sheetShot("import", after: 500)
            model.closeImport()
            await wait(400)
            // One-context import: a new context, a conflicting cluster, and an identical user.
            let singleContext = """
            apiVersion: v1
            kind: Config
            clusters:
            - name: development
              cluster:
                server: https://imported.example.invalid:6443
            users:
            - name: developer
              user:
                exec:
                  apiVersion: client.authentication.k8s.io/v1
                  command: example-credential-plugin
                  interactiveMode: Never
            contexts:
            - name: bbl-pedalpro
              context:
                cluster: development
                user: developer
            current-context: bbl-pedalpro
            """
            do {
                try model.prepareImport(yaml: singleContext, directory: explicitURL.deletingLastPathComponent())
                await sheetShot("import-single-light", after: 500)
                setAppearance(.darkAqua)
                await sheetShot("import-single-dark", after: 400)
                if let plan = model.importPlan {
                    try model.acceptImport(plan)
                    model.selectEntry("bbl-pedalpro")
                    await shot("imported-context-dark", after: 500)
                    setAppearance(.aqua)
                    await shot("imported-context-light", after: 400)
                    window.setContentSize(NSSize(width: 920, height: 600))
                    await shot("imported-context-compact", after: 400)
                }
            } catch {
                // Fixtures are synthetic, but keep capture failures visible to the caller.
                try? Data(error.localizedDescription.utf8).write(to: folder.appendingPathComponent("import-capture-error.txt"))
                model.closeImport()
            }
            model.discardDraft()
            await wait(300)
            NSApplication.shared.terminate(nil)
        }
    }

    /// Uses the window server, since cacheDisplay can't draw the Liquid Glass sidebar.
    private static func save(_ window: NSWindow, to url: URL) {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
        try? capture.run()
        capture.waitUntilExit()
    }
}
#endif
