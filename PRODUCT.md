# KubeConfig

<!-- impeccable:product-schema 1 -->

## Platform

Native macOS desktop (SwiftUI). No mobile or web target.

## Stack

Swift and SwiftUI, with a standalone Swift package for the configuration core and its tests.

## Users

A developer managing their own local Kubernetes configuration. Personal use first.

## Product Purpose

Open the app, inspect or edit a kubeconfig, apply changes, and quit. Success means importing a provider configuration, resolving naming conflicts, and activating its context without manually editing YAML.

## Operating Context

One file at a time, initially ~/.kube/config. Alternate files can be opened. No background agent, cluster connections, cloud login, or execution of credential plugins by the app itself. The one exception is k9s, an external tool the user starts on a context, which connects and runs plugins in its own process.

## Capabilities and Constraints

- Searchable contexts, clusters, users, and backups. Selecting a context does not activate it; double-click, Return, or Make Active does.
- Context switches go straight to the file by default, skipping Apply, review, Undo, and backups, and changing only `current-context`. Pending edits stay in the draft. A preference stages switches instead. Contexts not yet on disk and files that can't take the single-value change are staged either way.
- Stage all changes and step through a diff before Apply. Undo and Redo step through staged actions until Apply; Discard is one undoable step. Prompt on closing with pending changes; quit when the last window closes.
- Focused forms and a syntax-highlighted raw YAML editor, one toggle away. Preserve all values, unknown fields, and extensions; comments and formatting may change.
- File and pasted-YAML import with preview, Rename/Replace/Skip choices, reuse of identical entries, updated references, and rebased file paths. Relative paths in pasted YAML require a source folder.
- Rename updates references. Block deletion of referenced users/clusters, and say why before the attempt. Multi-select within Contexts, Clusters, or Users to delete selected entries with one confirmation and one Undo step; keep related entries. Single-entry deletion confirms only for the active context. Bulk deletion clears a selected active context without another warning. Deletes are staged until Apply.
- Reject invalid configurations and external modification conflicts. Notice outside changes when the app comes forward, leaving Reload to the user. Allow exporting the draft before reload.
- After a successful Apply, save the previous contents as an undo point. Rolling backups per file, default 10, configurable including zero. Trim on the next successful Apply.
- Rollback stages a backup; Apply reviews and commits it, backing up the replaced configuration.
- Credentials are always visible. Never log them.
- Offer Create/Import for a missing or empty file and raw repair with locations for invalid YAML.

## Brand Commitments

Name: KubeConfig. Standard macOS controls with Liquid Glass chrome, system typography, compact spacing, and automatic light/dark appearance. Generate the icon using an image model: a blue hexagonal cluster motif with a white configuration-sliders symbol.

## Product Principles

- Disk changes are explicit, reviewable, and recoverable. The one exception is an immediate context switch, which is explicit and reversed by switching back.
- Preserve unfamiliar configuration rather than reconstructing only recognized fields.
- Keep ordinary jobs quick and advanced editing accessible.
- Test configuration mutations and backup/rollback behavior using isolated files.
