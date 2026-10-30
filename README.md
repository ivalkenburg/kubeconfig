# KubeConfig

A native macOS utility for editing a local kubeconfig, importing provider configurations, switching contexts, and rolling back changes. Open it, do the job, and quit.

Requires macOS 14 or later. The local build targets the Mac on which it is compiled.

## Run

The built application is at `build/KubeConfig.app`. Open it in Finder, or:

```sh
open build/KubeConfig.app
```

It opens `~/.kube/config` by default. **Open Configuration…** selects another file. Only one file is edited at a time; `KUBECONFIG` is not merged automatically.

To try the supplied example without opening your personal configuration:

```sh
open -n build/KubeConfig.app --args --config "$PWD/Examples/sample-config.yaml"
```

The example uses reserved `.invalid` domains and has no working credentials.

## Editing and imports

Select a context to inspect it. **Make Active** stages a context switch. Edit its cluster, user, or namespace; **Apply…** flushes form edits, validates the complete configuration, and opens a diff. **Stage Edits** optionally moves form edits into the draft sooner. Switching to another entry also stages the current form.

Import a file or paste YAML, then review the names and resolved file paths. Conflicting entries receive proposed unique names. Choose **Replace** deliberately: existing contexts referring to that name will use the imported settings. **Skip** can reuse an existing referenced entry of the same name. Identical entries are reused. The merge is blocked if it would leave missing references or discard conflicting opaque metadata.

Renaming a cluster/user updates its context references. Referenced entries cannot be deleted. Deleting the active context explicitly offers to clear the active selection.

The advanced YAML editor exposes the actual configuration, including credentials, after confirmation. Unedited values, extension data, and unknown fields survive form edits. Comments and formatting may change. YAML merge keys (`<<`) must be expanded before editing. Supported configuration size is 16 MB, with at most 64 nesting levels.

Recognized secrets are masked in previews and diffs. Changed secret fields are marked without revealing their values. Reveal mode shows the original contents and formatting. Masking is based on recognized field names; opaque extension data may contain credentials under unfamiliar names. This app never executes credential plugins, connects to clusters, or logs configuration contents.

## Backups and rollback

After each successful Apply, the app saves the **exact previous file bytes**, including original comments, as a backup. Backups are isolated by the resolved configuration path. Preferences controls retention per file: default 10, allowed range 0–1000. Zero disables backup creation. Reduced retention, including zero, prunes old history after the next successful changed Apply.

Search backups by date, select one, and choose **Rollback to This Version…**. It loads a draft; it does not write the file. Review and Apply to restore it. That Apply backs up the version being replaced, making rollback undoable. A malformed historical configuration can be staged for repair but cannot be applied until valid.

Backups are stored beneath:

```text
~/Library/Application Support/KubeConfig/Backups/
```

Use **Reveal Backup Folder** to inspect them. Files use owner-only read/write permissions (`0600`); backup directories use `0700`. Backups contain credentials and are not additionally encrypted. A SHA-256 checksum detects accidental corruption; it is not a cryptographic authenticity guarantee.

Apply uses an atomic file replacement and checks for external changes both before preparing the write and immediately before replacement. Symlinks to kubeconfig files are preserved. Detection is optimistic: another process that does not coordinate its writes could still race the final replacement. Reload is explicit, and pending drafts can be exported before reload.

If the config write succeeds but backup storage fails, the app reports that the configuration **was applied**, retains the previous bytes in memory, and offers **Export Previous…**. Further applies are blocked until those bytes are exported or explicitly discarded. Leaving the configuration or quitting prompts to save or discard them. Since backups are required to be saved after Apply, an abrupt process/system failure between replacement and backup persistence can leave that Apply without an undo point.

## Build and test

Xcode and its Swift toolchain must be installed. Open `Package.swift` in Xcode to work on the app, or use:

```sh
make test
make bundle
```

The Makefile follows the neighboring Spotlite app’s build/bundle/run/install conventions. Build and install either variant:

```sh
make install-dev          # /Applications/KubeConfig Dev.app
make install-production   # /Applications/KubeConfig.app
make run CONFIG=debug     # build and open the development app
make install CONFIG=debug # equivalent development install
make help
```

Development builds go to `build/debug/KubeConfig Dev.app` and use bundle identifier `local.kubeconfig.app.dev`. Production builds go to `build/KubeConfig.app` and use `local.kubeconfig.app`. They can coexist with separate preferences; both use the selected kubeconfig and its backup history.

Installation defaults to `/Applications`. Override it with `INSTALL_DIR="$HOME/Applications"` or another directory. Signing uses the first available Apple Development identity, falling back to ad hoc signing; override with `IDENTITY="..."` or `IDENTITY=-`. These are local development/production installs, without a notarization step. Existing app bundles are replaced only after the new bundle has built and passed signature verification.

The Makefile directly handles compilation, icon generation, bundling, signing, and installation. Icon sizes are generated from `Assets/AppIcon.png` and reused until the source changes. `make clean` removes local build outputs, leaving installed applications and kubeconfig data alone.

Tests use isolated temporary files and never access `~/.kube/config`. They cover YAML preservation, edits and reference integrity, import conflict resolution and path rebasing, secret redaction, external changes, atomic write failures, permissions, rolling retention, corrupt backups, and rollback/undo. Additional app-model tests check staging, review, missing/broken files, and pending changes.

Debug builds can capture the native UI against an explicitly selected example configuration:

```sh
open -n -W "build/debug/KubeConfig Dev.app" --args \
  --config "$PWD/Examples/sample-config.yaml" \
  --capture-dir "$PWD/.impeccable/review"
```

## Project layout

- `Sources/KubeConfigCore`: YAML tree model, imports, diffs, atomic persistence, and backups.
- `Sources/KubeConfig`: SwiftUI interface, application state, preferences, and lifecycle.
- `Tests`: core and app-model regression tests.
- `Assets/AppIcon.png`: generated source icon; the generation prompt is recorded alongside it.
- `Makefile` and `Resources/Info.plist`: native app packaging and installation.

YAML parsing uses [Yams](https://github.com/jpsim/Yams), pinned in `Package.swift` and `Package.resolved`. Its bundled libyaml and Yams are MIT licensed; notices are included in `Resources/ThirdPartyNotices.txt`.
