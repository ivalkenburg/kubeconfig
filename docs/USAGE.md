# KubeConfig

A native macOS utility for editing a local kubeconfig, importing provider configurations, switching contexts, and rolling back changes. Open it, do the job, and quit.

Requires macOS 26 or later, which provides the Liquid Glass interface. The local build targets the Mac on which it is compiled.

## Run

The built application is at `build/KubeConfig.app`. Open it in Finder, or:

```sh
open build/KubeConfig.app
```

It opens `~/.kube/config` by default, offering to create or import a configuration if that file is missing or empty. **Open Configuration…** selects another file, and **Open Recent** in the File menu lists the last ten. Only one file is edited at a time; `KUBECONFIG` is not merged automatically.

To try the supplied example without opening your personal configuration:

```sh
open -n build/KubeConfig.app --args --config "$PWD/Examples/sample-config.yaml"
```

The example uses reserved `.invalid` domains and has no working credentials.

## Editing and imports

Select a context to inspect it. Double-click it, press Return, or use **Make Active** to switch to it. With **Switch contexts immediately** on in Settings, the default, the switch goes straight to the file: only the `current-context` value changes, so comments and formatting survive. It skips review, saves no backup, and isn't on the Undo history, so switch back to reverse it. **Clear Active Context** works the same way. Other pending edits stay in the draft. A context that isn't on disk yet, or a file whose `current-context` can't be changed on its own, such as JSON, falls back to a staged switch. A file changed outside the app is refused, as with Apply. With the setting off, every switch is staged for Apply.

Edits join the draft when you press Return or leave the field, and picker changes join it immediately. An empty or duplicate name stays in the form with its error beside it. Changed entries and fields get an orange dot, and **Apply** shows the number of changes its review will step through. Changing a value back clears its marker. The sidebar counts changed entries in each section, and a rename counts as one. **Apply** is disabled while the configuration has issues; click the orange issue count beside the file path to list them. Otherwise it opens a diff of the complete configuration, starting at the first change. The up and down buttons, or the arrow keys, step through the changes. The diff compares parsed configurations, so formatting alone doesn't appear in it, though comments and formatting may still change on Apply.

**Undo** and **Redo** (⌘Z, ⇧⌘Z) step through finished actions: an edit, add, delete, staged activation, import, rollback, or Discard. While typing in a field, ⌘Z stays with that field. **Discard** returns to the file on disk and can itself be undone. History clears after Apply, Open, and Reload; Backups cover anything older.

The toolbar title names the current section, above the path of the open file. With the sidebar hidden, clicking the title opens a menu of the sections; its chevron appears when you hover over the title. The app remembers whether the sidebar is hidden across launches and keeps that state when switching between forms and YAML. ⌘F outside the YAML editor moves to the list's search field, which also matches a context's cluster, user, and namespace.

Right-click an entry for **Make Active**, **Duplicate**, **Copy Name**, and **Delete**. The active context offers **Clear Active Context** instead, there and on the check button in its header, and clusters add **Copy Server URL**. For a single entry, Delete is also on the Delete key, the Edit menu, and the trash button. Single-entry deletes are staged and undoable, so only deleting the active context asks first.

In Contexts, Clusters, and Users, ⌘click selects multiple entries and ⇧click selects a range. Selection stays within the current section. The detail pane shows the number selected and a **Delete N Items…** button; Contexts also offers **Preview Export…**. Activation and duplication require a single selection. Searching removes hidden entries from the selection; clearing search does not restore them. If a committed edit in any section would hide its row, search clears to keep it visible.

To delete multiple entries, use **Delete N Items…** in the selection summary or right-click menu. Right-click a selected row to act on the whole selection; right-click an unselected row to act on that row alone. A standard confirmation shows the number and type of selected entries, with **Cancel** and **Delete** buttons. If any selected cluster or user is referenced by a context, a **Cannot delete selected items** alert explains the blocking references and offers only **OK**; the entire batch stays unchanged. Deleting contexts keeps their clusters and users, even when unused. If the active context is selected, deleting it also clears the active context without an additional warning. The whole deletion is staged until Apply and can be reversed with one Undo. After deletion, the first remaining visible entry is selected; Undo restores and reselects the deleted entries.

**Import** opens one sheet where you can choose a file or paste YAML. You can also drop one kubeconfig file into the main window to open its import review directly. Multiple-file drops are rejected, and drops do not replace an open sheet. The review table lists contexts first, with each entry’s status, action, and destination name aligned in columns. Choose **Rename** to edit the destination in the **Import as** column; conflicting entries receive proposed unique names. Resolved file paths appear below the table. Choose **Replace** deliberately: existing contexts referring to that name will use the imported settings. **Skip** can reuse an existing referenced entry of the same name. Identical entries are reused. The merge is blocked if it would leave missing references, point a context at a different entry renamed to the name of one it skipped, or discard conflicting opaque metadata. Importing keeps the current active context; use **Make Active** separately to switch contexts.

The export icon beside **Make Active** in a context's header, **Preview Export…** when multiple contexts are selected, or **File → Export Selected Contexts…** exports the selected contexts into one kubeconfig. Export is available only in the Contexts list with at least one selection. It uses the current draft, including the focused field's edit, and includes each required cluster and user once. The preview shows the exported YAML directly; choose **Copy** to copy the complete preview, including credentials, to the clipboard, or **Export…** to save the same content. Copy keeps the preview open and briefly shows **Copied**. Cancelling the Save dialog keeps the preview open. Export does not apply or discard pending changes or change the original file.

Referenced CA certificates, client certificates, and private keys are embedded as data; token files are copied as their current token value and will no longer refresh from the original file. Relative paths are resolved from the open configuration's folder. As in kubectl, `~` isn't expanded, so a path starting with it counts as relative, in imports too. Existing embedded certificate/key data takes precedence over its file path, while a token file takes precedence over a static token. Missing or unreadable required files block export and identify the affected entry and path. Only regular files can be embedded, and exports remain subject to the 16 MB configuration limit. Credential plugins and authentication providers are preserved without being run; their external dependencies, including files named in arguments, environment values, or extension data, are not embedded. Exported files include credentials and are saved with owner-only permissions (`0600`). The open configuration and embedded source files cannot be used as the export destination, including a credential symlink's original target if the link changes after preview.

Only the exported subset is validated, so unrelated invalid entries do not block it. Included entries retain all their fields and extensions; unrelated top-level metadata is omitted. A single exported context becomes active in the exported file. With multiple contexts, the current active context is retained if selected; otherwise the export has no active context. **File → Export Draft…** remains available separately to save the entire draft, including unfinished YAML.

Renaming a cluster/user updates its context references. Referenced entries cannot be deleted.

The YAML button switches between the forms and the full file. The editor has syntax highlighting (up to 2 MB), line numbers, a marker on the line with a parse error, a find bar (⌘F, with ⌘G and ⇧⌘G to step through matches), and a **Wrap Lines** toggle in the toolbar and View menu. The same setting applies to backup previews, which have their own wrap button. Typing in the editor has its own undo, and the whole session becomes one step in the main history when you leave it. Unedited values, extension data, and unknown fields survive form edits. Comments and formatting may change. YAML merge keys (`<<`) must be expanded before editing. Tags such as `!!binary` or `!custom` can't be saved, so remove them in the editor before Apply or export; an immediate context switch leaves them alone. A leading byte order mark is accepted and dropped on Apply; an immediate context switch keeps it. Only regular files can be opened or imported, and oversized files are rejected before reading their contents. Plain values such as `y`, `n`, `0X1F`, and `+.5` follow kubectl’s boolean/number rules; quote them when using them as names or credentials. Supported configuration size is 16 MB, with at most 64 nesting levels and a million values once aliases are expanded.

Credentials are always visible in forms, the YAML editor, diffs, and previews. The app itself never executes credential plugins, connects to clusters, or logs configuration contents. The optional k9s terminal below is a separate program that does connect and does run credential plugins.

## k9s

**Open in k9s** (⇧⌘K, the terminal button on a context, its right-click menu, or the View menu) runs [k9s](https://k9scli.io) on that context in the detail pane. k9s isn't bundled: install it with `brew install k9s`. The app finds it through your login shell's `PATH`, then the usual Homebrew, MacPorts, and Nix folders, and credential plugins are found the same way. Opening k9s doesn't change the active context, and your k9s settings apply, including read-only mode. k9s reopens the last view it saved for each context, except that a context saved on its contexts list opens on pods. k9s saves that list when a context can't connect, so a context that can't connect still shows it. k9s can change what's on the cluster, so check the context in k9s's own header, which stays correct if you switch contexts inside k9s.

k9s reads the file on disk, so the action is unavailable while a pending change touches the context or the cluster or user it points to. Apply first. Changes to other entries don't matter.

Each context can have one session, and sessions on different contexts run independently. A terminal symbol marks each open session. Select a context to return to its session; Open in k9s focuses the existing session. Close (the × button in the toolbar), Restart, and quitting k9s affect only that context’s session. Applying or reloading a file without a context closes its session; reloading keeps sessions for contexts that still exist. Opening another file or quitting the app closes all sessions. Ending a session also stops any port-forwards in it. Quitting k9s returns to the form. If k9s fails, its output stays on screen with Restart and Back. Expand, also in the toolbar, gives k9s the whole window and is remembered separately for each open session. Restart k9s is in the View menu, and Undo, Redo, and Find are off while k9s is on screen.

The terminal has an 8-point inset on all sides that follows the k9s skin’s main background color, including skin changes during a session. New and restarted sessions follow the system appearance: light mode passes k9s’s `--invert` switch, which reverses the selected skin, including custom skins. Terminal text and background colors match the session’s launch appearance. Running sessions keep their appearance when the system changes themes; restart a session to pick up the new appearance. The app does not modify your k9s configuration.

If the context, its cluster, or its user changes on disk during a session, a notice offers Restart, which needs any pending changes to them applied first. If the context is gone or renamed, it offers Close.

## Backups and rollback

After each successful Apply, the app saves the **exact previous file bytes**, including original comments, as a backup. Immediate context switches save none and don't prune history. Backups are isolated by the resolved configuration path. Settings controls retention per file: default 10, allowed range 0–1000. Zero disables backup creation. Reduced retention, including zero, prunes old history after the next successful changed Apply.

Search backups by date, select one, and choose the rollback button or **Rollback…** from the right-click menu. It loads a draft; it does not write the file. Review and Apply to restore it. That Apply backs up the version being replaced, making rollback undoable. **Delete…** in the right-click menu, or the Delete key, removes a backup for good after asking; it isn't on the Undo history. A malformed historical configuration can be staged for repair but cannot be applied until valid.

Backups are stored beneath:

```text
~/Library/Application Support/KubeConfig/Backups/
```

Use the folder button in Backups to inspect them. Each backup is a `.json` file with a small `.meta` summary beside it, so the list loads without reading any backup's contents; a backup's checksum is verified when you select it, roll back to it, or it's pruned. Backups that fail these checks aren't used or pruned: the list counts any it can't show and links to the folder, and the rest stay available. Files use owner-only read/write permissions (`0600`); backup directories use `0700`. Backups contain credentials and are not additionally encrypted. A SHA-256 checksum detects accidental corruption; it is not a cryptographic authenticity guarantee.

Apply uses an atomic file replacement and checks for external changes both before preparing the write and immediately before replacement. Symlinks to kubeconfig files are preserved, including chains of links to a file that doesn't exist yet. Detection is optimistic: another process that does not coordinate its writes could still race the final replacement. When the app comes forward it checks the file again, and shows a notice if it changed. Reload is explicit, and pending drafts can be exported before reload.

If the config write succeeds but backup storage fails, the app reports that the configuration **was applied**, retains the previous bytes in memory, and offers **Export Previous…**. Further applies are blocked until those bytes are exported or explicitly discarded. Leaving the configuration or quitting prompts to save or discard them. Since backups are required to be saved after Apply, an abrupt process/system failure between replacement and backup persistence can leave that Apply without an undo point.

## Build and test

Xcode and its Swift toolchain must be installed. Open `Package.swift` in Xcode to work on the app, or use:

```sh
make test
make bundle
```

Build and install either variant:

```sh
make install-dev          # /Applications/KubeConfig Dev.app
make install-production   # /Applications/KubeConfig.app
make run CONFIG=debug     # build and open the development app
make install CONFIG=debug # equivalent development install
make help
```

Development builds go to `build/debug/KubeConfig Dev.app` and use bundle identifier `com.igorv.kubeconfig.dev`. Production builds go to `build/KubeConfig.app` and use `com.igorv.kubeconfig`. They can coexist with separate preferences; both use the selected kubeconfig and its backup history.

Installation defaults to `/Applications`. Override it with `INSTALL_DIR="$HOME/Applications"` or another directory. Signing uses the first available Apple Development identity, falling back to ad hoc signing; override with `IDENTITY="..."` or `IDENTITY=-`. These are local development/production installs, without a notarization step. Existing app bundles are replaced only after the new bundle has built and passed signature verification.

The Makefile directly handles compilation, icon generation, bundling, signing, and installation. Icon sizes are generated from `Assets/AppIcon.png` and reused until the source changes. `make clean` removes local build outputs, leaving installed applications and kubeconfig data alone.

Tests use isolated temporary files and never access `~/.kube/config`. They cover YAML preservation, edits and reference integrity, import conflict resolution and path rebasing, external changes, atomic write failures, permissions, rolling retention, corrupt backups, and rollback/undo. Additional tests check staging, immediate context switches, review, undo history, change tracking, the YAML tokenizer, missing/broken files, and pending changes.

Debug builds can capture the native UI against an explicitly selected example configuration. Captures go through the window server, so the app needs Screen Recording permission:

```sh
open -n -W "build/debug/KubeConfig Dev.app" --args \
  --config "$PWD/Examples/sample-config.yaml" \
  --capture-dir "$PWD/.impeccable/review"
```

## Project layout

- `Sources/KubeConfigCore`: YAML tree model, YAML tokenizer, imports, diffs, draft change tracking, atomic persistence, and backups.
- `Sources/KubeConfig`: SwiftUI interface, application state, preferences, and lifecycle.
- `Tests`: core and app-model regression tests.
- `Assets/AppIcon.png`: generated source icon.
- `Makefile` and `Resources/Info.plist`: native app packaging and installation.

YAML parsing uses [Yams](https://github.com/jpsim/Yams) and the k9s terminal uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), both pinned in `Package.swift` and `Package.resolved`. They and Yams's bundled libyaml are MIT licensed; notices are included in `Resources/ThirdPartyNotices.txt`.
