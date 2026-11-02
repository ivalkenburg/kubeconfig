# Import review

Mode: Operate. Native macOS, SwiftUI and AppKit.

THESIS: Scan the entire import in aligned Entry, Status, Action and Import as columns; keep the context and its dependencies visible without scrolling through separate sections.

OWN-WORLD: Preserve KubeConfig's native macOS controls, system typography, adaptive semantic colors, and restrained dividers. No new visual identity, materials, raster assets, or palette.

STORY: Choose a file or paste YAML, review names and conflicts, resolve only the decisions that need attention, then merge into the draft and Apply separately.

FIRST VIEWPORT: A compact review sheet opens directly on fixed column headings and contexts-first rows. No summary counts, imported-YAML preview, or repeated footer explanation. The Entry cell uses a name and quiet kind caption without icons. Action menus have short labels (Add, Rename, Replace, Skip, Reuse); the Import as column holds the destination name, editable only for Rename. Rename fields and menus share one centered row. Replacement warnings, resolved paths and validation errors remain. Cancel and Merge into Draft align to the right of one footer row. Imports keep the active context unchanged, with no activation option. Dividers appear only between entries. The sheet fits small imports and caps larger ones with scrolling.

FORM: seed:2453143009c5eb10. Code-led refinement of the user-selected compact table. User rejected the initial implementation as messy and explicitly removed the “1 new entry / name conflicts / identical entries” summary. The updated form uses 840-point width, 95-point Status, 120-point Action, 225-point Import as, 16-point column gaps, and 12-point row padding. The initial under-menu rename placement is superseded by a separate aligned Import as column. Native semantic typography and colors remain authoritative. Intrinsic two-line entry heights in the main list and centered NoticeBar alignment stay in place.

Confirmed context: the reported compressed row followed importing one context. Reproduce with synthetic data, using an explicit sample configuration rather than the user's kubeconfig.

Decision reference (critique only): .impeccable/mocks/decision/import-designs.html, option C. No approved raster comp or external quality-bar image; incumbent native app and DESIGN.md govern finish.
