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

One file at a time, initially ~/.kube/config. Alternate files can be opened. No background agent, cluster connections, cloud login, or execution of credential plugins.

## Capabilities and Constraints

- Searchable contexts, clusters, users, and backups. Selecting a context does not activate it.
- Stage all changes and review a diff before Apply. Prompt on closing with pending changes; quit when the last window closes.
- Focused forms and an explicitly revealed raw YAML editor. Preserve all values, unknown fields, and extensions; comments and formatting may change.
- File and pasted-YAML import with preview, Rename/Replace/Skip choices, reuse of identical entries, updated references, and rebased file paths. Relative paths in pasted YAML require a source folder.
- Rename updates references. Block deletion of referenced users/clusters. Active-context deletion requires replacement or explicit clearing.
- Reject invalid configurations and external modification conflicts. Allow exporting the draft before reload.
- After a successful Apply, save the previous contents as an undo point. Rolling backups per file, default 10, configurable including zero. Trim on the next successful Apply.
- Rollback stages a backup; Apply reviews and commits it, backing up the replaced configuration.
- Mask recognized secrets in forms and diffs, with Reveal. Raw YAML exposes real contents. Never log credentials.
- Offer Create/Import for a missing file and raw repair with locations for invalid YAML.

## Brand Commitments

Name: KubeConfig. Standard macOS controls, system typography, compact spacing, and automatic light/dark appearance. Generate the icon using an image model: a blue hexagonal cluster motif with a white configuration-sliders symbol.

## Product Principles

- Disk changes are explicit, reviewable, and recoverable.
- Preserve unfamiliar configuration rather than reconstructing only recognized fields.
- Keep ordinary jobs quick and advanced editing accessible.
- Test configuration mutations and backup/rollback behavior using isolated files.
