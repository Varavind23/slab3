# Slabs — Design System

**Caliper** is the visual language for Slabs, a mobile app for people who source
graded trading cards in bulk. They scan slabs one at a time, the app identifies each
card and pulls pricing from three sources, and the resulting inventory gets sliced
into buyer-specific groups and exported as CSV.

The whole product is one loop:

> Scan → build inventory → price it → group it by buyer → filter → export CSV

Everything in the UI serves that loop. No social layer, no marketplace, no checkout.

## The design brief behind Caliper

The client audience "values something that looks cool" — said in those words. The
direction that won is **cool through precision**: an instrument, not a dashboard.
Hairline rules, square corners, mono for every number, near-black ground, and cyan
used as the scanner and the one committed action per screen. The read should be
"expensive measuring tool", not "sci-fi costume".

The counterweight is that this is a data product. 255 rows, eight data points per
row, card names like *Japanese Rulers of the Heavens Rayquaza*. Every stylistic move
had to survive that density, which is why the type scale is steep and the color
system is strictly rationed.

## Surfaces

One product, one surface: the **mobile app**. Four destinations in a persistent
bottom tab bar, each one tap from the others:

| Tab | What it holds |
|---|---|
| **Scan** | Live camera capture. One tap per slab, no confirm step. |
| **Cards** | Inventory, grouping, selection. The center of gravity. |
| **Export** | CSV builder with a live preview. |
| **Settings** | Sources, refresh, payout, scanner and CSV defaults. |

## Sources

Built from two inputs:

1. **A workflow & feature spec** supplied by the client (sections referenced
   throughout the component docs as §1–§8). It fixes the workflow, information
   architecture and data density, and explicitly frees the visual language. Reference
   data snapshot: 255 cards, $121,600 estimated total, $15,348 estimated payout,
   145 of 255 matched, 246 of 255 ungrouped, prices $310–$12,275, PSA 8/9/10, years
   2002–2023, mostly Japanese Pokémon with some One Piece.
2. **Two read-only mounted codebase folders**, `slab3/` and `Slab3/` (the same
   project at two depths — `Slab3/` is `slab3/ios/Slab3/`). These are an earlier,
   narrower build of the same product: a two-source grayscale iOS app. Its domain
   model, cert-parsing rules (PSA = 8 digits, CGC = 10) and CSV-as-deliverable framing
   carried forward; **its visual system did not.** The old grayscale, no-accent-color
   direction has been deliberately replaced.

No Figma file, no GitHub URL, no slide deck, and no brand assets were provided.

## Content fundamentals

**Register: plain and mechanical.** Labels are nouns, actions are bare verbs. Nothing
performs friendliness. There is no exclamation point anywhere in the product.

**Casing.** Sentence case for anything a person reads as a sentence
(`Tap to scan`, `Add 4 to group`, `New group name...`). Uppercase with wide tracking
for mono labels — `EST. PAYOUT`, `INCLUDE COLUMNS`, `3 SELECTED`, `REFRESHING 255
CARDS`. Acronyms stay caps: PSA, CGC, CSV, CL, CY, JP.

**Person.** Second person, implied and rare. No "I", no "we". "Your" only where
possession must be stated.

**Live over static.** This is the strongest content rule in the system: no label is a
fixed string if it could carry a count.

| Element | Unfiltered | Filtered |
|---|---|---|
| Context line | `255 cards` | `4 cards` / `3 of 255 selected` |
| Search placeholder | `Search 255 cards` | `Search 4 cards` |
| Sheet confirm | `Show 255 cards` | `Show 4 cards` |
| Export confirm | `Export 255 cards` | `Export 4 cards` |
| Summary label | `Estimated total` | `Group total` |
| Filename | `inventory_2026-08-19.csv` | `inventory_pete_2026-08-19.csv` |

**Verbatim strings from the product:**

- `Tap to scan` / `PSA QR · CGC BARCODE`
- `Add 4 to group` · `New group name...` · `Create`
- `All cards` · `Ungrouped` · `Unmatched` · `All ranges`
- `145 of 255 matched` · `EST. PAYOUT`
- `Already in inventory · #84920117`
- `Matched in 0.6s · #84920200`
- `No cards in this group yet. Select cards on Inventory and tap Group.`
- `Prices refreshed Aug 19 · 09:12`

**Group names are user strings.** `pete`, `justin 18`, `jose 7/20`, `philcgc`,
`Triumph 7/24`, `s`, `bricks`. Render them exactly as typed — never title-case,
pluralize or reformat a group name.

**Numbers.** Whole dollars with a comma separator, no cents (`$121,600`). Yen is
abbreviated (`¥1.74M`, `¥264K`). Counts are bare. Missing data is an em dash `—`,
never `$0` and never blank. Certs carry a leading `#`.

**Punctuation.** `·` separates metadata on one line. `—` means missing. `→` appears
inside instructions. `↗` prefixes Share. No emoji, ever.

## Visual foundations

**Color.** Near-black ground (`#06090C`), one surface step up (`#0D1318`), and
hairline structure (`#1A242C`). Cyan `#35E0E8` is the interface accent — the scanner,
the active state, and exactly one committed action per screen. Beyond that, color is
rationed to two jobs:

- **Price sources**, which appear on every single row: CL cyan, CY lime `#9BE85C`,
  JP violet `#C98BFF`. A cool trio, chosen so three saturated values can sit side by
  side four times per screen without shouting.
- **Confidence**, deliberately warm — red `#E0685E` / amber `#E5B65C` / green
  `#62D69A` — so a match meter can never be misread as a price source.

Six muted group hues exist as buyer identifiers, and they only ever appear as a small
dot beside the group's name.

**Type.** Space Grotesk for voice, JetBrains Mono for every number and label. All
figures are tabular so prices, certs and counts align down a scrolling list. The
scale is steep at the money: 31px for the hero total, 17px for payout, 13px for card
names, 11px for prices, 9px for meta. Titles are deliberately small — the
oversized-title convention is not used, because the money should be the biggest thing
on screen, not the word "Inventory".

**Spacing and layout.** 18px gutter, 8px between row panels, 12px inside them.
Nothing nests deeper than two levels. Fixed elements: the four-tab bar is pinned at
the bottom on every screen; the header (context line + source toggle + title) is
pinned at the top on every screen; the sheet confirm is sticky; the selection action
bar rises above the tab bar without replacing it.

**Backgrounds.** Flat fills, plus one texture: a 36px hairline grid inside the camera
viewport, which reads as a targeting field rather than decoration. No gradients, no
photography, no illustration, no patterns anywhere else.

**Cards and rows.** Surface fill, 1px hairline, square corners, no shadow. Each
inventory row is its own panel on an 8px gap, so it is its own tap target. Chips are
square too — there are no pills in this system.

**Corners.** 0 is the default. 3px is the maximum radius and only controls get it
(the source toggle, the zoom thumb). The only circles are the selection check and the
group dot.

**Shadows.** No elevation shadows at all. Structure is carried by hairlines. The one
depth effect is a cyan bloom, allowed in exactly three places: the scanline, an
active toggle segment, and a fresh capture's readout. A high-confidence meter gets a
faint green bloom. Nothing else glows.

**Transparency and blur.** Two uses only: the post-scan toast sits on a blurred scrim
over the live camera feed, and the sheet backdrop dims the screen behind it. Nothing
else is translucent.

**Animation.** Restrained and functional. The scanline is the only continuous motion.
The refresh glyph spins while a fetch is in flight. Sheets rise in 260ms on
`cubic-bezier(0.16, 1, 0.3, 1)`. The scan toast holds 1.8s and disappears. No
bounces, no springs, no page transitions, no parallax. Selection mode does not
animate at all, because the list must not reflow.

**States.** Press is opacity (0.6), never a color or scale change. Disabled is 0.4
opacity. Hover does not exist — this is a touch product; a web recreation should step
the surface up one level rather than shift hue. Selection is a filled cyan circle
with a check plus a tinted row: two channels, not one.

**Borders.** 1px hairlines only. `--line` for structure, `--line-strong` for
controls, `--cyan` for the single active edge (the sheet's top border, the selection
bar's top border). No colored left-accent borders except the scan toast, where a 2px
cyan edge distinguishes a fresh match from a duplicate warning.

**Imagery.** One image type exists: a photo of the physical slab, on every inventory
row. Not the card art — the slab, because that is how a sourcer recognizes what they
just scanned. Nothing else in the product is an image.

## Iconography

**Lucide**, outlined, 13–18px, at `--text-secondary` unless the glyph is part of an
active control, in which case cyan. Icons are functional only — controls, tabs, and
the sheet's folder glyphs. No decorative icons, no icon-led empty states.

The full inventory in use:

| Lucide name | Where |
|---|---|
| `scan-line` | Scan tab, onboarding step 1 |
| `layers` | Cards tab, onboarding step 2 |
| `share` | Export tab, selection bar, onboarding step 3 |
| `settings` | Settings tab |
| `funnel` | Filter pill |
| `folder` | Group action, group rows in sheets |
| `folder-minus` | Remove from group |
| `trash-2` | Delete (the only red glyph) |
| `pencil` | Manual entry on Scan |
| `refresh-cw` | Price refresh (spins while fetching) |
| `check` | Selection state |

**Substitution, flagged:** the source material specifies no icon set, so Lucide was
chosen for its thin uniform stroke, which matches the hairline structure. Swap it if
production ships something else — every call site goes through the `Icon` wrapper.

**Emoji:** never. Three unicode marks do work: `·` (metadata separator), `—`
(missing value), `↗` (share).

**No logo exists.** The source material contains no mark, no app icon, and no
wordmark file. The identity is the word **Slabs** set in Space Grotesk at 700. Nothing
has been drawn or reconstructed here; wherever a mark would go, render the wordmark.

## Intentional additions

The spec defines a workflow, not a component library, so the inventory below was
derived from the screens it describes. Three components have no direct counterpart in
the spec and exist for practical reasons:

- **`Icon`** — a Lucide wrapper, so the icon-set substitution lives in one place.
- **`Button`** — the spec's screens use four button treatments repeatedly without
  naming a component; this consolidates them.
- **`PhoneFrame`** — a viewport for the UI kit, not part of the product.

Three screens were designed from scratch, because the spec lists them as gaps and you
asked for them in this pass: **onboarding** (three swipeable cards), **the
price-refresh trigger**, and **the Settings tab**. Settings was built only from what
the rest of the product implies — three sources that need accounts, a refresh cadence
behind the `Refreshed at` column, the payout provider behind `Payout %` and `Outlet`,
and defaults mirroring the Scan and Export controls.

## Still undesigned

Deliberately out of this pass, from the spec's own gap list:

- **Card detail view** — whether a row opens one, and what it holds.
- **Manual entry form** — reachable from the pencil on Scan, not designed.
- **Buy range creation and editing** — consumed as a filter, authored nowhere.
- **Outlet / payout provider surface** — the columns exist in the export; the UI
  that sets them does not.

## Index

| Path | What |
|---|---|
| `styles.css` | Global entry — `@import` list only |
| `tokens/colors.css` | Ground, ink, cyan, three source hues, confidence, group hues |
| `tokens/typography.css` | Faces, figure/title/mono registers, tabular figures |
| `tokens/spacing.css` | Gutter, row gap, radii, thumbnail size |
| `tokens/effects.css` | The three cyan glows, scrim, durations, easing |
| `tokens/fonts.css` | Google Fonts import |
| `guidelines/*.card.html` | 16 specimen cards — Colors, Type, Structure, Voice |
| `components/core/` | `Button`, `Chip`, `Icon` |
| `components/data/` | `CardRow`, `PriceTriple`, `ConfidenceMeter`, `GroupTag`, `SummaryBlock`, `SourceToggle` |
| `components/shell/` | `ScreenHeader`, `TabBar`, `Sheet`, `SelectionBar`, `FilterPill`, `SearchSortBar`, `PhoneFrame` |
| `ui_kits/scanner_app/` | Click-through recreation: onboarding, Scan, Inventory, selection, both sheets, Export, Settings |
| `explorations/` | The three directions that were considered — A Caliper (chosen), B Bloom, C Vector |
| `SKILL.md` | Agent-skill entry point |

### Component list

`Button`, `Chip`, `Icon`, `SourceToggle`, `PriceTriple`, `ConfidenceMeter`,
`GroupTag`, `CardRow`, `SummaryBlock`, `ScreenHeader`, `TabBar`, `PhoneFrame`,
`Sheet`, `SelectionBar`, `FilterPill`, `SearchSortBar`.
