---
name: KubeConfig
description: A compact native macOS workspace for inspecting and editing kubeconfig files.
rounded:
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
    rounded: "capsule"
    padding: "6pt 10pt"
  notice-bar:
    padding: "{spacing.notice}"
  k9s-terminal:
    padding: "{spacing.related}"
  detail-header:
    padding: "14pt 24pt"
---

# Design System: KubeConfig

## Overview

**Creative North Star: "A familiar, compact macOS configuration editor"**

KubeConfig uses standard macOS controls, Liquid Glass chrome, system typography, compact spacing, and automatic light/dark appearance. The visual priority is quick inspection and careful editing of a local configuration, with familiar navigation and explicit review before writing to disk.

SwiftUI and AppKit own control rendering, keyboard focus, selection, materials, and adaptive type. SF Symbols identify sections and actions. The generated blue hexagonal cluster icon with white configuration sliders is the app identity asset; its artwork does not define a fixed interface palette.

**Key Characteristics:**
- Compact three-column workspace.
- Adaptive macOS colors and semantic system type.
- Native controls and SF Symbols, with glass reserved for chrome.
- Actions that never move: Undo, Discard, and Apply stay in the toolbar.
- Visible draft state and reviewable changes.

This is the implemented system in Operate mode. Sources: `Sources/KubeConfig/{KubeConfigApp,MainView,EntryDetailView,Sheets,YAMLEditor,K9sTerminal}.swift`; real native captures live in `.impeccable/review/`. Measurements are macOS logical points, independent of screenshot pixel density. Frontmatter owns explicit reusable dimensions; platform-owned values remain semantic references in the sidecar.

## Colors

Adaptive system neutrals support sparse accent and status color. No fixed interface color primitives are declared: resolved RGB values vary with macOS appearance and user settings.

### Primary

`Color.accentColor` marks active-context symbols and prominent native actions. Sidebar symbols and selection are left to macOS.

### Neutral

`Color.primary` and `.secondary` provide primary and supporting text. AppKit `controlBackgroundColor`, `windowBackgroundColor`, and `textBackgroundColor` separate the entry list, detail region, and code surfaces. `.separator` and native `Divider` separate regions. The search surround uses `.quaternary.opacity(0.5)`.

### Status

SwiftUI `.orange` marks pending changes, warnings, and issues. Changed entries and fields use a 6-point orange dot. Diff additions use `.green`; removals use `.red`, each with a change prefix and a 0.08-opacity background. Notice bars use their tint at 0.07 opacity.

YAML uses system colors by token: blue keys, green quoted and block strings, orange numbers, purple booleans and null, secondary comments, and tertiary punctuation. Plain values stay in the primary label color.

**The Adaptive Color Rule.** Preserve the source semantic color references; never promote sampled light/dark colors into fixed interface tokens.

## Typography

Use SwiftUI system typography, resolved by macOS. There is no custom display face or fixed type scale.

- **Title:** `.title2` with semibold weight for detail and sheet titles.
- **Section:** `.headline` for list and resolved-path headings.
- **Body:** default system body; medium weight for entry names and backup timestamps.
- **Supporting:** `.callout` for explanatory text; `.subheadline` for compact summaries.
- **Metadata:** `.caption` for paths, counts, row subtitles, status, and form footers.
- **Code:** system monospaced at the system font size for editable YAML, `.callout` for diffs and backup previews, and `.caption` for paths.

Font sizes, leading, and control labels remain platform-owned. SF Symbols follow their surrounding type role.

## Layout

A `NavigationSplitView` presents section navigation, a searchable entry list, and a flexible editor. The default window is 1120 × 740 points; the minimum is 920 × 600. Sidebar widths are min/ideal/max 155/180/220; list widths are 235/275/370. Resizing preserves this desktop workspace; forms and previews scroll as needed. There is no mobile breakpoint system.

Sidebar navigation groups Contexts, Clusters, and Users under Configuration, and Backups under History, with change badges. There is no footer, so the glass sidebar reaches the window bottom.

The toolbar leads with the current section, aligned to the list rows below it, and a line with the abbreviated file path, draft status, and an orange issue count that opens the issue list. A long path truncates in the middle, keeping the status and count, and the full path appears on hover. While the sidebar is hidden, the section title is a borderless menu of the same sections, split by a divider before Backups. Trailing groups, in order: Open, Import, and YAML; Undo and Redo; Discard; and Apply with its count. These controls stay visible when disabled so nothing shifts, and status belongs by the title rather than among them.

YAML mode drops the entry list, gives the editor the full width, and adds a Wrap Lines toggle in its own group before the other toolbar buttons. Backups shares that setting through a wrap button in its header, tinted with the accent color while on.

Use the frontmatter spacing vocabulary for repeated custom regions. List rows pair medium-weight names with caption metadata. Sheet headers use the header inset; sheet action bars and preview areas commonly use the panel inset. Native grouped forms own their internal row metrics.

Review and import source sheets are respectively 780 × 620 and 680 × 600 points. Import review is 840 points wide; its height is `min(580, max(320, 210 + 56 × item count + paths allowance))`, with a 100-point allowance when resolved paths exist. A three-entry import without resolved paths is 378 points tall; larger imports scroll within the capped sheet. Settings use a 480 × 320-point grouped form. These are implemented surface sizes, not general-purpose breakpoints.

## Elevation & Depth

Liquid Glass belongs to controls floating above content: the toolbar, sidebar, context menus, and the icon button groups in detail headers. Forms, list rows, and code surfaces stay solid so values remain easy to read. The app defines no custom shadows or animation tokens. macOS owns window/sheet depth and native control treatments; retain those platform effects.

## Shapes

Native controls and grouped forms retain their macOS shapes. Search is a capsule, and the pasted-YAML editor outline uses its frontmatter radius. Do not apply one uniform radius to every native component. The pasted editor outline uses a one-point semantic separator stroke.

## Components

### Buttons

Use native `Button` and `SettingsLink`. Apply uses `.glassProminent`; sheet confirmations use `.borderedProminent`. Icon actions in detail headers and the Review stepper use `GlassIconButton`, circular `.glass` buttons with `help` and accessibility labels, inside a `GlassIconGroup`. Destructive buttons declare `.destructive`. Disabled conditions, Return/Escape actions, shortcuts, help, and accessibility labels remain part of the component. Hover, pressed, and focus rendering belongs to macOS.

### Navigation and Lists

Use `NavigationSplitView`, `.sidebar` navigation, and `.inset` entry/backup lists. SF Symbols identify sections; selection and active-context state are separate. The active context has a labeled checkmark. Long names and row subtitles truncate in the middle; detail titles may use two lines. Entry rows preserve their intrinsic vertical height, with a minimum inner height of 40 points and 5-point top and bottom padding. Keep the section symbol vertically centered beside the medium-weight name and caption subtitle, including immediately after insertion.

Row actions live in right-click menus, so forms hold only fields. A delete that isn't possible stays visible but disabled, with its reason.

### Search

A plain `TextField` sits beside a magnifying glass within the capsule surround, next to the list's add or refresh button. Show a labeled clear button when nonempty. Use this same search pattern in all four sections. Differentiate an empty collection from no search matches; backup no-match state offers Clear Search.

### Forms

Use `.grouped` `Form`, `Section`, `TextField`, `Picker`, and `LabeledContent`. Credentials use plain text fields and are always visible. A bad name shows its error in the form rather than an alert. Native file choosers support path fields. Preserve native focus and validation affordances.

### Notices and Empty States

`NoticeBar` combines an SF Symbol, wrapping callout text, optional actions, tint wash, and divider. The symbol, text, and action buttons align vertically to the center, including when text wraps. Warnings include explanatory text. Notices cover a failed backup, a file changed outside the app, damaged backups, a failed k9s, and a k9s session that's out of date. `ContentUnavailableView` supplies missing-file, repair, unselected, and history states with contextual actions.

### YAML, Diffs, and Review Sheets

An `NSTextView` supports raw YAML, with syntax colors, a line-number gutter, a find bar, optional line wrapping, and a red marker on the parse error line. Previews use selectable, syntax-colored monospaced text and two-axis scrolling. Diff lines retain +/− prefixes and status tint. Use an eager stack for wrapped diff lines, since a lazy stack's height estimates make scrolling jump. Review groups neighboring changed lines into steps: circular glass up and down buttons move between them, and the current step takes a stronger tint. Sheets separate explanation, scrollable content, and bottom actions with dividers; Cancel and the confirmation action use native keyboard behavior.

### Import Review

A compact table aligns Entry, Status, Action, and Import as across its fixed heading and scrollable rows, with contexts first. Entry takes the remaining width; Status is 95 points, Action is 120 points, Import as is 225 points, and horizontal gaps are 16 points. Each Entry cell shows its original name and a quiet kind caption without an icon. All cells align vertically to the center, with 12-point top and bottom row padding. Dividers separate entries; the final entry has no trailing divider.

Native action menus align to the left and use short labels: Add, Rename, Replace, Skip, and Reuse. New entries default to Add and also offer Rename; identical entries default to Reuse. Rename makes the destination editable inline in the Import as column beside the menu. Other actions show the final name as secondary text; Skip shows an em dash. Replacement warnings appear beneath the row; resolved file paths remain selectable in the scrolling content.

The title has one explanatory line, followed directly by the column heading without summary counts. Cancel and Merge into Draft align to the right of one fixed footer row, with validation errors above it and no repeated footer explanation. Import review keeps the active context unchanged and has no activation option, imported-YAML disclosure, preview, or syntax highlighting.

### k9s Terminal

A SwiftTerm view replaces the entry form with no header, since k9s shows its live context itself. While it is on screen, Expand and Close form their own group before the other toolbar buttons, and Restart is in the View menu and the failure notices. It is a code surface, so it stays solid. It uses SF Mono at 12 points and an 8-point inset inside the terminal host, with a solid background following SwiftTerm’s actual backing-layer color. k9s paints its skin as true-color cells rather than changing the terminal default, so output updates align the canvas with a background occupying more than half the screen. Selection rows, borders, and status colors do not override it. Runtime default-background changes and reverse video remain supported. Each context retains its own session and expanded layout. New and restarted sessions use the system appearance at launch: light mode passes `--invert` to k9s, while terminal foreground and background use semantic AppKit text colors resolved for that appearance. The session keeps its launch appearance when the system appearance changes; terminal programs can still change their colors. Don't add a theme setting or modify k9s configuration, since k9s skins own their colors.

## Do's and Don'ts

### Do:
- Do use semantic SwiftUI/AppKit colors and verify both macOS appearances. k9s sessions retain their launch appearance until restarted.
- Do preserve native focus, keyboard shortcuts, disabled states, and accessible action labels.
- Do keep search available for contexts, clusters, users, and backups, including clear-search and empty-result states.
- Do pair warnings and diff colors with symbols, text, or change prefixes.
- Do distinguish selection, active context, and pending changes in labels and affordances.
- Do keep every action that changes the draft's main state reachable by more than right-click: a toolbar or header button, a menu item, or a shortcut. Row conveniences such as Duplicate and the copy actions can stay in the right-click menu.

### Don't:
- Don't freeze screenshot RGB values or system type sizes into brand tokens.
- Don't replace standard macOS controls with custom web or mobile imitations.
- Don't use the app icon's blue as a mandatory interface accent; retain Color.accentColor.
- Don't introduce decorative shadows, display fonts, or ornamental panels into the compact workspace.
- Don't put glass on forms, list rows, or code surfaces.
