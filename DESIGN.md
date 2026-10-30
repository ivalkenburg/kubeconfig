---
name: KubeConfig
description: A compact native macOS workspace for inspecting and editing kubeconfig files.
rounded:
  search: "7pt"
  section-symbol: "9pt"
  yaml-input: "6pt"
spacing:
  row-detail: "5pt"
  related: "8pt"
  compact: "10pt"
  control-group: "12pt"
  notice: "14pt"
  inset: "16pt"
  panel: "20pt"
  header: "24pt"
components:
  search-field:
    rounded: "{rounded.search}"
    padding: "9pt"
  section-symbol:
    rounded: "{rounded.section-symbol}"
    width: "42pt"
    height: "42pt"
  notice-bar:
    padding: "{spacing.notice}"
  detail-header:
    padding: "{spacing.header}"
---

# Design System: KubeConfig

## Overview

**Creative North Star: "A familiar, compact macOS configuration editor"**

KubeConfig uses standard macOS controls, system typography, compact spacing, and automatic light/dark appearance. The visual priority is quick inspection and careful editing of a local configuration, with familiar navigation and explicit review before writing to disk.

SwiftUI and AppKit own control rendering, keyboard focus, selection, materials, and adaptive type. SF Symbols identify sections and actions. The generated blue hexagonal cluster icon with white configuration sliders is the app identity asset; its artwork does not define a fixed interface palette.

**Key Characteristics:**
- Compact three-column workspace.
- Adaptive macOS colors and semantic system type.
- Native controls and SF Symbols.
- Visible draft state and reviewable changes.

This is the implemented system in Operate mode. Sources: `Sources/KubeConfig/{KubeConfigApp,MainView,EntryDetailView,Sheets}.swift`; real native captures live in `.impeccable/review/`. Measurements are macOS logical points, independent of screenshot pixel density. Frontmatter owns explicit reusable dimensions; platform-owned values remain semantic references in the sidecar.

## Colors

Adaptive system neutrals support sparse accent and status color. No fixed interface color primitives are declared: resolved RGB values vary with macOS appearance and user settings.

### Primary

`Color.accentColor` marks active-context symbols, detail symbols, and prominent native actions. Selected sidebar symbols use white over the native selection background. The section-symbol background uses accent at 0.09 opacity.

### Neutral

`Color.primary` and `.secondary` provide primary and supporting text. AppKit `controlBackgroundColor`, `windowBackgroundColor`, and `textBackgroundColor` separate the entry list, detail region, and code surfaces. `.bar` supplies the footer material; `.separator` and native `Divider` separate regions. The search surround uses `.quaternary.opacity(0.5)`.

### Status

SwiftUI `.orange` marks pending changes, warnings, and issues. Diff additions use `.green`; removals use `.red`, each with a change prefix and a 0.08-opacity background. Notice bars use their tint at 0.07 opacity.

**The Adaptive Color Rule.** Preserve the source semantic color references; never promote sampled light/dark colors into fixed interface tokens.

## Typography

Use SwiftUI system typography, resolved by macOS. There is no custom display face or fixed type scale.

- **Title:** `.title2` with semibold weight for detail and sheet titles.
- **Section:** `.headline` for list and import-group headings.
- **Body:** default system body; medium weight for entry names and backup timestamps.
- **Supporting:** `.callout` for explanatory text; `.subheadline` for compact summaries.
- **Metadata:** `.caption` for paths, counts, row subtitles, status, and form footers.
- **Code:** system monospaced `.body` for editable YAML, `.callout` for diffs and backup previews, and `.caption` for import previews and paths.

Font sizes, leading, and control labels remain platform-owned. SF Symbols follow their surrounding type role; the detail-header symbol is explicitly 25 points inside the section-symbol container.

## Layout

A `NavigationSplitView` presents section navigation, a searchable entry list, and a flexible editor. The default window is 1120 × 740 points; the minimum is 920 × 600. Sidebar widths are min/ideal/max 155/180/220; list widths are 235/275/370. Resizing preserves this desktop workspace; forms and previews scroll as needed. There is no mobile breakpoint system.

Sidebar navigation groups Contexts, Clusters, and Users under Configuration, and Backups under History. The active on-disk context sits below navigation. The full-width footer shows the file and draft/status information. Toolbar actions remain at the top.

Use the frontmatter spacing vocabulary for repeated custom regions. Search has an outer compact inset and its own internal padding. List rows pair medium-weight names with caption metadata. Detail/sheet headers use the header inset; sheet action bars and preview areas commonly use the panel inset. Native grouped forms own their internal row metrics.

Review, paste, and import sheets are respectively 780 × 620, 680 × 600, and 800 × 680 points. Preferences use a 480 × 320-point grouped form. These are implemented surface sizes, not general-purpose breakpoints.

## Elevation & Depth

Content uses system surfaces, dividers, grouped forms, and low-opacity tints. The app defines no custom shadows or animation tokens. macOS owns window/sheet depth and native control treatments; retain those platform effects.

## Shapes

Native controls and grouped forms retain their macOS shapes. Only custom surrounds use the frontmatter radii: search, the section-symbol tile, and the pasted-YAML editor outline. Do not apply one uniform radius to every native component. The pasted editor outline uses a one-point semantic separator stroke.

## Components

### Buttons

Use native `Button`, `Menu`, and `SettingsLink`. Prominent actions use `.borderedProminent`; toolbar/list utility icons use appropriate native plain or borderless styles. Destructive buttons declare `.destructive`. Disabled conditions, Return/Escape actions, shortcuts, help, and accessibility labels remain part of the component. Hover, pressed, and focus rendering belongs to macOS.

### Navigation and Lists

Use `NavigationSplitView`, `.sidebar` navigation, and `.inset` entry/backup lists. SF Symbols identify sections; selection and active-context state are separate. The active context has a labeled checkmark. Long names and row subtitles truncate in the middle; detail titles may use two lines.

### Search

A plain `TextField` sits beside a magnifying glass within the rounded semantic surround. Show a labeled clear button when nonempty. Use this same search pattern in all four sections. Differentiate an empty collection from no search matches; backup no-match state offers Clear Search.

### Forms and Credential Fields

Use `.grouped` `Form`, `Section`, `TextField`, `Picker`, `LabeledContent`, and native toggles. `SecureField` masks recognized secrets until Reveal; forms use a small native switch, while review/import/backup surfaces use checkboxes. Native file choosers support path fields. Preserve native focus and validation affordances.

### Notices and Empty States

`NoticeBar` combines an SF Symbol, wrapping callout text, optional action, tint wash, and divider. Warnings include explanatory text. `ContentUnavailableView` supplies missing-file, repair, unselected, and history states with contextual actions.

### YAML, Diffs, and Review Sheets

Monospaced `TextEditor` supports raw YAML, with an explicit credential warning. Previews use selectable monospaced text and two-axis scrolling. Diff lines retain +/− prefixes and status tint. Sheets separate explanation, scrollable content, and bottom actions with dividers; Cancel and the confirmation action use native keyboard behavior.

## Do's and Don'ts

### Do:
- Do use semantic SwiftUI/AppKit colors and verify both macOS appearances.
- Do preserve native focus, keyboard shortcuts, disabled states, and accessible action labels.
- Do keep search available for contexts, clusters, users, and backups, including clear-search and empty-result states.
- Do pair warnings and diff colors with symbols, text, or change prefixes.
- Do distinguish selection, active context, and pending changes in labels and affordances.

### Don't:
- Don't freeze screenshot RGB values or system type sizes into brand tokens.
- Don't replace standard macOS controls with custom web or mobile imitations.
- Don't use the app icon's blue as a mandatory interface accent; retain Color.accentColor.
- Don't introduce decorative shadows, display fonts, or ornamental panels into the compact workspace.
