# Handoff: Caliper — Slabs visual system + scanner workflow

## Overview

Caliper is a full visual rework of Slabs plus the workflow described in the client's
feature spec. It replaces the grayscale, no-accent-color direction currently
implemented in `ios/Slab3/` with a dark, hairline-structured, cyan-accented system,
and restructures the app from three tabs to four.

**Read this first: two separate jobs are hiding in here, and only one is a restyle.**

| Job | Size | What it touches |
|---|---|---|
| **A. Restyle what exists** | Mechanical | Swap the token files, restyle existing views. No new data. |
| **B. Adopt the new workflow** | Real feature work | A third price source, confidence scoring, groups replacing folders, buy ranges, payout, a CSV column builder, selection mode. Touches the model, the worker adapters, and the Supabase schema. |

Job A can ship alone and will already look like the mocks on the screens that exist
today. Job B is a product change, not a design change. Don't treat them as one ticket.

## About the design files

Everything in `reference/` is a **design reference created in HTML/React** —
prototypes showing intended look and behavior. They are **not production code to
copy**. The target is SwiftUI (iOS 17, SwiftData, XcodeGen), so recreate these designs
using that environment's patterns. Do not embed a web view.

`swift/` is the exception: those two files ARE meant to be dropped in. They're a
mechanical translation of the design system's CSS tokens into SwiftUI and they replace
`Slab3/DesignSystem/Palette.swift` and `Typography.swift`.

## Fidelity

**High-fidelity.** Every color, type size, weight, spacing value, border width and
radius below is final and exact. Where a value looks unusual (11pt spacing, 3pt max
radius, 9pt metadata) it's deliberate — don't snap anything to a 4/8-pt grid.

## What changes structurally

The current app and the new design disagree about the product's shape. This is the
migration map:

| Today (`ios/Slab3/`) | Caliper | Notes |
|---|---|---|
| 3 tabs: Home, Scanner, Folders | **4 tabs: Scan, Cards, Export, Settings** | Home is deleted — it only held "Start Scanning" and a count. Settings graduates from a hamburger sheet to a tab. |
| 2 price sources | **2 sources: CL, CY** | Both stay visible; the active source leads. |
| `PricePair` — winner glows green, loser red | **The ACTIVE source leads in its own hue** | There is no winner; there's an emphasized source chosen by a global toggle. **The single biggest departure.** |
| No confidence concept | **Confidence 0–5 per source** | New model field, new column in `price_cache`. |
| `Folder` (name, tag color, archived) | **`Group`** (name, color) | Same idea, renamed. `archived` has no equivalent — decide whether to keep it. |
| No buy ranges | **Buy ranges per owner, used as a filter** | Not authored anywhere in the design either. Flagged below. |
| No payout | **Est. payout beside every total** | Needs a rate source. |
| `CSVExport.write` — fixed columns | **Column builder; selection order = column order** | Needs an ordered column list parameter. |
| Light + dark via `Palette.dyn` | **Dark only** | `AppearanceModifier` and the appearance picker come out. Cyan-on-black doesn't invert. |
| Grayscale, no accent | **Cyan accent, two source hues, warm confidence** | `design.md` §1 is overturned — see open question 6. |

## Design tokens

Drop in `swift/DesignTokens.swift` and `swift/CaliperType.swift`. Full values:

### Color

| Token | Hex | Use |
|---|---|---|
| `bg` | `#06090C` | App background |
| `surface` | `#0D1318` | Row and panel fill |
| `surface2` | `#141C22` | Chip and inset fill |
| `line` | `#1A242C` | Structural hairline |
| `lineStrong` | `#26333C` | Control hairline |
| `textPrimary` | `#E8F1F4` | Card names, figures |
| `textSecondary` | `#74858F` | Labels, metadata |
| `textTertiary` | `#4A585F` | Cert numbers, missing values |
| `textOnCyan` | `#04191A` | Label on a filled cyan control |
| `cyan` | `#35E0E8` | Scanner, active state, one primary action |
| `cyanDim` | `#0E3A42` | Selected-row border, accent outlines |
| `srcCL` | `#35E0E8` | Card Ladder price |
| `srcCY` | `#9BE85C` | Courtyard price |
| `confLow` | `#E0685E` | Confidence 0–1 |
| `confMid` | `#E5B65C` | Confidence 2–3 |
| `confHigh` | `#62D69A` | Confidence 4–5 |
| `payout` | `#62D69A` | Est. payout figure |
| `danger` | `#E0685E` | Delete only |
| group hues | `#C98BFF` `#9BE85C` `#35E0E8` `#E5B65C` `#FF8FD0` `#7FA6FF` | Buyer group dots |

**Non-negotiable:**
- One cyan primary action per screen. If two things are cyan, one is wrong.
- Confidence is warm precisely so a meter can never be misread as a price source.
  Never color a meter with a source hue, or the reverse.
- A missing price renders `—`. Never `$0`, never blank. (Matches the existing
  `CLAUDE.md` rule: never fabricate a price to make a code path return something.)

### Typography

| Token | Size / weight | Use |
|---|---|---|
| `figure` | 31 / 700 sans | Estimated or group total |
| `figureSmall` | 17 / 700 sans | Est. payout, selection total |
| `calTitle` | 23 / 600 sans | Page title |
| `calHeading` | 16 / 600 sans | Sheet title |
| `calBody` | 13 / 500 sans | Card names, sheet rows |
| `price` | 11 / 500 mono | A price on a row |
| `meta` | 9 / 500 mono, tracking 0.05em | Year, set, cert, trailing prices |
| `label` | 10 / 500 mono, tracking 0.13em, uppercase | EST. PAYOUT, 3 SELECTED |
| `code` | 9 / 400 mono | CSV preview |

Faces: **Space Grotesk** (voice) and **JetBrains Mono** (all numbers and labels), both
Google Fonts. Add the .ttf files and list them under `UIAppFonts`. Every figure is
tabular.

### Spacing and geometry

Gutter **18**. Row gap **8**. Row padding **12**. Scale: 2, 4, 6, 8, 11, 14, 18, 24.
Border width **1**. Hit target minimum **44**. Slab thumbnail **46 × 64**. Camera grid
cell **36**.

Radius: **0 is the default.** 3 is the maximum and only controls get it (source
toggle, zoom thumb). The only circles are the selection check and the group dot. There
are no pills and no rounded cards.

### Depth and motion

**No elevation shadows anywhere.** Structure is hairlines. Cyan blooms in exactly three
places: the scanline (`0 0 16px` at 55%), an active toggle segment, and a fresh
capture's readout. High confidence gets a faint green bloom. Nothing else glows.

The scanline is the only continuous animation. The refresh glyph spins while a fetch is
in flight. Sheets rise in 260 ms on `timingCurve(0.16, 1, 0.3, 1)`. The scan toast
holds 1.8 s. Selection mode does not animate at all, because the list must not reflow.

Press is opacity 0.6. Disabled is 0.4. No hover — touch product.

## Screens

### 1. Onboarding — three swipeable cards
Explains the loop before first use. Replayable from Settings → How it works.

Full-bleed `bg`, gutter 18. Top row: cyan `STEP 01` (`label`) left, `Skip` right.
Centered: a 52 × 52 square with a 1pt `cyanDim` border and `cyan.opacity(0.06)` fill
holding a 24pt glyph; a 29pt/600 title at -1 tracking; a 14pt/400 body at
`textSecondary`, line-height 1.6; a hairline rule with a `meta` footnote at
`textTertiary`. Bottom: three 2pt progress bars, tappable, filled bars cyan with the
active one glowing. Primary button: **Next**, then **Open the scanner**.

Copy, verbatim:
1. *Tap once per slab* — "The whole viewport is the shutter. PSA slabs read from their QR code, CGC from the barcode — the cert number is all the app needs to identify the card." Footnote: "Zoom and torch live under the viewfinder. Cert digits are small and slabs are shiny."
2. *Two markets, one row* — "Every card carries prices from CL and CY, each with a confidence meter showing how sure the match is. Switch which source leads with the toggle up top — the other one never disappears." Footnote: "A source with no data shows an em dash. Nothing here ever invents a number."
3. *Group by buyer, export CSV* — "Select cards until the running total hits your target, drop them into a buyer's group, then filter to that group and export. The filename carries the buyer and the date." Footnote: "The CSV is usually the only part of this app your buyer ever sees."

### 2. Scan
Header: context `Today · N scans`, source toggle right-aligned, a 26 × 26 outlined
pencil for manual entry, then the title **Scan**.

Viewport: 4:5, inset by the gutter, 1pt `lineStrong` border, gradient
`#0A1013 → #070A0C`, with four 24 × 24 corner brackets, 2pt cyan, inset 16.
**The entire viewport is the shutter** — one tap, no focus step, no confirm step.

The "Tap to scan" block is anchored to the **lower third** (16pt/600 plus a
`PSA · CGC QR OR BARCODE` label).

Post-scan toast, inset 14 from the viewport's bottom: blurred scrim, 1pt cyan border,
2pt cyan left edge, holding the card name, the active source's price in that source's
hue, `MATCHED IN 0.6s · #84920117`, and the grade chip. A duplicate cert instead gets
an amber left edge and `ALREADY IN INVENTORY · #84920117` — and does not add a row.
Holds 1.8 s.

Below: a `ZOOM` row (2pt track, cyan fill to 36%, a 14 × 14 cyan square thumb with
glow, live `2.0×` readout) and a `TORCH` row (44 × 22 square switch, cyan when on),
separated by a hairline.

### 3. Cards — Inventory
The center of gravity. Everything else is upstream or downstream of it.

Header: context `255 cards`, source toggle, title **Inventory** (the group name when
filtered, **Select cards** in selection mode), `Select` text action.

**Summary block** — 1pt `lineStrong`, `surface` fill, two rows split by a hairline.
Top: `ESTIMATED TOTAL` label then the 31pt figure. Bottom: `EST. PAYOUT` label, the
17pt figure in `payout` green, and `145 of 255 matched` right-aligned in `meta`. When
filtered the top label becomes `GROUP TOTAL` and every figure recalculates. A group
with no matched cards legitimately shows `EST. PAYOUT $0` / `0 of 4 matched`.

**Filter pill** — full width, 1pt `lineStrong`. Unfiltered: funnel, "All cards",
chevron. Filtered: the group chip with an inline `×` that clears without opening the
sheet.

**Search + sort + refresh** — a scope-aware search field ("Search 255 cards" →
"Search 4 cards"), a `RECENT ↓` control, and a refresh button whose glyph spins during
a fetch. Beneath, a `meta` line reads `PRICES REFRESHED AUG 19 · 09:12`, turning cyan
and becoming `REFRESHING 9 CARDS · CL, CY` in flight. **This is the price-refresh
trigger the spec listed as missing** — the `Refreshed at` column had no visible cause.

**Card row** — the densest component. A panel (surface, 1pt `line`, square, no shadow),
12pt padding, on an 8pt gap:

- Left: 46 × 64 slab thumbnail, 1pt `lineStrong` border. **A photo of the physical
  slab, not the card art** — that's how a sourcer recognizes what they scanned.
- Line 1: card name (13/500, one line, truncating) and the active source's price
  (11/500 mono in that source's hue, with an 8pt source suffix at 75% opacity).
- Line 2: the other price and `year category · #number` in `meta`, then the
  confidence meter right-aligned — five 7 × 4 segments, 2pt apart, filled left to
  right in the confidence tone.
- Line 3: `#cert` in `textTertiary`, then right-aligned the group chip (if any) and
  the grade badge (`PSA 10`, `surface2` fill, 1pt `lineStrong`).

**Selection mode** is a mode on this same screen. The list does not reflow and the
scroll position doesn't change. Rows grow a 19pt circle on the left (filled cyan with a
check when selected) and tint to `cyan.opacity(0.055)` with a `cyanDim` border. Header
context becomes `3 of 255 selected` in cyan, the title becomes `Select cards`, and
`Select all` / `Cancel` replace `Select`.

**Selection action bar** rises above the tab bar without replacing it: 1pt cyan top
border, `surface` fill. Top row `3 SELECTED` left and the running total `$5,487` at
17/700 right — **that running total is the point of the whole mode**; sourcers select
until they hit a target value. Below, four equal columns split by hairlines: Group,
Remove, Export, Delete. Delete is last and the only red thing in the bar.

### 4. Group sheet
Title states action and count: **Add 4 to group**. `Cancel` top-right. A scrolling list
of existing groups — a folder glyph **in the group's own hue**, the name, an `N cards`
subtitle, a chevron. Below a `cyanDim` divider: a text field (`New group name...`) and
a cyan **Create** button beside it. **Creating a group and assigning the selection are
one action** — there is never a separate manage-groups screen. After assignment the
sheet dismisses, selection clears, and the affected rows show their new chip
immediately.

### 5. Filters sheet
Shared by Cards and Export — same component, only the confirm verb changes. Header
**Filters**, with `Clear all` appearing only when something is active.

`GROUPS`: All cards (with the total, checkmarked when active), Ungrouped with its
count, then every group with hue, name and count. Groups with zero cards still render.

`BUY RANGE`: All ranges, Unmatched with its count, then each owner with a color dot,
name, count, and an expand chevron implying nested ranges.

Sticky confirm pinned to the bottom, **always visible, always carrying the live
count**: `Show 255 cards` → `Show 4 cards` from Cards, `Export 4 cards` from Export.
The count updates before the sheet closes.

### 6. Export
Header context `inventory.csv · 255 rows`. Same filter pill, same sheet — **filter
state is global across tabs**, so filtering on Cards carries here without being
re-applied.

**CSV preview** as a code window: title bar with three dots and the generated filename,
which encodes scope and date — `inventory_2026-08-19.csv` unfiltered,
`inventory_pete_2026-08-19.csv` with a group active. Body is 9/400 mono, scrolling
horizontally, showing the header row then the first few real rows. **Header cells are
tinted to the source of their column** (`cy_price`, `cy_conf` in lime, etc.).

**Include columns**: a wrapping grid of chips. Selected chips are filled and carry a
numeric order badge — **selection order IS column order in the file**, which is why the
number must be visible. Unselected chips are outlined. Source-owned chips take that
source's hue. Full list: Cert, Name, Year, Card #, Grade, Grader, CL Price, CL Conf,
CY Price, CY Conf, Outlet, Payout %, Payout provider, Payout $,
Scanned at, Refreshed at.

Pinned above the tab bar: `N CARDS` and the scope's dollar total, then a full-width
cyan **↗ Share CSV**, handing off to the OS share sheet. No in-app file browser.

### 7. Settings
Never shown in the client's reference, so designed from what the rest of the product
implies. Sectioned rows, each section headed by a `label`:

- **PRICE SOURCES** — Card Ladder / Courtyard, each with its hue dot
  and a connection state; plus Default emphasis.
- **PRICE REFRESH** — Automatic refresh (`ON SCAN + DAILY`), Last full refresh, Refresh
  on pull-down. Where the `Refreshed at` cadence is configured.
- **PAYOUT** — Payout provider (`NOT SET`), Default payout %, Buy ranges.
- **SCANNER** — Torch default, Zoom default, Haptic on capture, Duplicate certs
  (`WARN, DON'T BLOCK`).
- **CSV** — Default columns, Filename pattern (`INVENTORY_GROUP_DATE`).
- **ABOUT** — How it works (Replay), Version, Sign out (red).

Treat these as a proposal, not a spec — they encode assumptions you may want to change.

### Tab bar
Four columns — five for someone on a team, Teams in the centre (Scan · Cards · Teams ·
Export · Settings; teams-first, 2026-09-28) — 1pt `line` top border, `bg` fill. Each: a 17pt glyph over a `meta`
uppercase label. Active is cyan with a heavier stroke; inactive `textSecondary`.
Selection mode does **not** replace this bar.

## Behavior that must be preserved

From the client's spec §5 — the difference between the design working and not:

1. **Every count is live.** Row counts, dollar totals, match counts, search
   placeholders, filenames and button labels all recalculate the moment a filter or
   selection changes. If a label can be a static string, it's wrong.
2. **Filter state is global across tabs.**
3. **Money is always shown twice** — raw value and estimated payout, side by side.
4. **Missing data is an em dash**, never `$0`, never blank.
5. **Both sources visible on every row simultaneously.** The toggle changes
   emphasis and sort basis; it doesn't hide the other.
6. **Destructive actions are visually separated** from constructive ones.
7. **Selection mode is a mode, not a screen.** The list doesn't reflow.
8. **One-tap capture.** No focus, confirm, or review step between tap and scan.
9. **Group creation is inline.**

## State

Global, surviving tab changes: `activeSource: PriceSource`, `filter: Filter?`
(group / ungrouped / buy range / unmatched), `selection: Set<Card.ID>`,
`isSelecting: Bool`, `sortOrder`, `refreshState`, `enabledColumns: [Column]` (an
**ordered** array — order is meaning), `hasSeenOnboarding: Bool`.

Per card, new versus today: `confidence` per source (0–5), `price` per source (three,
not two), `refreshedAt` per source, buy-range match, payout figure.

In the current codebase `activeSource` and `filter` are the two genuinely new pieces of
app-level state — everything else is already in `Card`/`Folder` or is view-local.

## Suggested order of work

1. Drop in `swift/DesignTokens.swift` + `swift/CaliperType.swift`, delete
   `Palette.swift` and `Typography.swift`, fix the compile errors. The app is now
   dark-only and cyan-accented with no layout work at all.
2. Rebuild the row: `CardPriceRow` → the Caliper card row. Biggest single visual win.
3. Restructure navigation: four tabs, Settings out of the hamburger, Home deleted.
4. Selection mode + the action bar.
5. Groups sheet (rename `Folder` → `Group`, inline create).
6. Filters sheet, with filter state lifted to app level.
7. Export tab: column builder, ordered columns into `CSVExport`, live filename.
8. Confidence scoring — model, worker adapter, schema.
9. Buy ranges and payout.
10. Onboarding, then Settings.

Steps 1–7 are Job A plus the UI-only parts of Job B. Steps 8–10 need backend work.

## Open questions for the client

1. **Where do confidence scores come from?** Stored as a small integer per source, but
   the spec never says how it's computed. Today's matching is an exact/probable flag on
   `card_key`; confidence needs a defined scale.
2. **Who authors buy ranges?** Consumed as a filter and referenced by payout, but no
   screen creates or edits them — in the client's reference or in this design.
3. **What is the payout rate?** `Payout %`, `Payout provider` and `Outlet` exist as
   export columns with no UI. The mocks apply a flat ~12.6% to matched cards, derived
   from the reference snapshot's \$121,600 → \$15,348. That's a placeholder.
5. **Does `archived` survive?** Folders could be archived; groups have no such state.
6. **Is `design.md` being retired or amended?** It states "no accent color anywhere" as
   non-negotiable and `CLAUDE.md` says it's enforced in code. Caliper contradicts it.
   Either way, both documents need updating or the next contributor implements the old
   rule.

## Files in this bundle

| Path | What |
|---|---|
| `swift/DesignTokens.swift` | Drop-in. Replaces `Palette.swift`. Includes `PriceSource`. |
| `swift/CaliperType.swift` | Drop-in. Replaces `Typography.swift`. Includes panel/label/money helpers. |
| `reference/A-caliper.html` | The original direction study — four screens side by side, static. Best single overview; open it first. |
| `reference/ui-kit-source.md` | The interactive prototype's full source, collected into one readable document. |
| `reference/component-rules.md` | Per-component rules: what each is for and what must not be lost. |
| `reference/prop-contracts.md` | Every component's prop interface, with each prop documented. |
| `reference/design-system/` | The token CSS the Swift files were generated from, plus the design system's own readme (content fundamentals, visual foundations, iconography). |

The living design system, including specimen cards for every token group, is the Slabs
Design System project this bundle came from.
