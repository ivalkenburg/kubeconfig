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

Right-click an entry for **Make Active**, **Duplicate**, **Copy Name**, and **Delete**. The active context offers **Clear Active Context** instead, there and on the check button in its header, and clusters add **Copy Server URL**. Delete is also on the Delete key, the Edit menu, and the trash button. Deletes are staged and undoable, so only deleting the active context asks first.

In Contexts, ⌘click selects multiple entries and ⇧click selects a range. The detail pane shows the number selected and a **Preview Export…** button. Activation, duplication, and deletion are disabled until a single context is selected. Searching removes hidden contexts from the selection; clearing search does not restore them. If a committed edit in any section would hide its row, search clears to keep it visible.

**Import** opens one sheet where you can choose a file or paste YAML. You can also drop one kubeconfig file into the main window to open its import review directly. Multiple-file drops are rejected, and drops do not replace an open sheet. Then review the names and resolved file paths. Conflicting entries receive proposed unique names. Choose **Replace** deliberately: existing contexts referring to that name will use the imported settings. **Skip** can reuse an existing referenced entry of the same name. Identical entries are reused. The merge is blocked if it would leave missing references, point a context at a different entry renamed to the name of one it skipped, or discard conflicting opaque metadata, or if the imported active context you chose to activate is skipped.

The export icon beside **Make Active** in a context's header, **Preview Export…** when multiple contexts are selected, or **File → Export Selected Contexts…** exports the selected contexts into one kubeconfig. Export is available only in the Contexts list with at least one selection. It uses the current draft, including the focused field's edit, and includes each required cluster and user once. The preview shows the exported YAML directly; choose **Export…** to save. Cancelling the Save dialog keeps the preview open. Export does not apply or discard pending changes or change the original file.

Referenced CA certificates, client certificates, and private keys are embedded as data; token files are copied as their current token value and will no longer refresh from the original file. Relative paths are resolved from the open configuration's folder. As in kubectl, `~` isn't expanded, so a path starting with it counts as relative, in imports too. Existing embedded certificate/key data takes precedence over its file path, while a token file takes precedence over a static token. Missing or unreadable required files block export and identify the affected entry and path. Only regular files can be embedded, and exports remain subject to the 16 MB configuration limit. Credential plugins and authentication providers are preserved without being run; their external dependencies, including files named in arguments, environment values, or extension data, are not embedded. Exported files include credentials and are saved with owner-only permissions (`0600`). The open configuration and embedded source files cannot be used as the export destination, including a credential symlink's original target if the link changes after preview.

Only the exported subset is validated, so unrelated invalid entries do not block it. Included entries retain all their fields and extensions; unrelated top-level metadata is omitted. A single exported context becomes active in the exported file. With multiple contexts, the current active context is retained if selected; otherwise the export has no active context. **File → Export Draft…** remains available separately to save the entire draft, including unfinished YAML.

Renaming a cluster/user updates its context references. Referenced entries cannot be deleted.

The YAML button switches between the forms and the full file. The editor has syntax highlighting (up to 2 MB), line numbers, a marker on the line with a parse error, a find bar (⌘F, with ⌘G and ⇧⌘G to step through matches), and a **Wrap Lines** toggle in the toolbar and View menu. The same setting applies to backup previews, which have their own wrap button. Typing in the editor has its own undo, and the whole session becomes one step in the main history when you leave it. Unedited values, extension data, and unknown fields survive form edits. Comments and formatting may change. YAML merge keys (`<<`) must be expanded before editing. Tags such as `!!binary` or `!custom` can't be saved, so remove them in the editor before Apply or export; an immediate context switch leaves them alone. A leading byte order mark is accepted and dropped on Apply. Supported configuration size is 16 MB, with at most 64 nesting levels and a million values once aliases are expanded.

Credentials are always visible in forms, the YAML editor, diffs, and previews. This app never executes credential plugins, connects to clusters, or logs configuration contents.

## Backups and rollback

After each successful Apply, the app saves the **exact previous file bytes**, including original comments, as a backup. Immediate context switches save none and don't prune history. Backups are isolated by the resolved configuration path. Settings controls retention per file: default 10, allowed range 0–1000. Zero disables backup creation. Reduced retention, including zero, prunes old history after the next successful changed Apply.

Search backups by date, select one, and choose the rollback button or **Rollback…** from the right-click menu. It loads a draft; it does not write the file. Review and Apply to restore it. That Apply backs up the version being replaced, making rollback undoable. A malformed historical configuration can be staged for repair but cannot be applied until valid.

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

YAML parsing uses [Yams](https://github.com/jpsim/Yams), pinned in `Package.swift` and `Package.resolved`. Its bundled libyaml and Yams are MIT licensed; notices are included in `Resources/ThirdPartyNotices.txt`.
