# Component rules

One section per component, lifted from the design system's own prompt files. These are
the rules each component must keep when rebuilt in SwiftUI — the "what and when", and
the constraints easiest to lose in translation.


---

## Button

Buttons. Square, hairline, mono-labelled.

```jsx
<Button variant="primary" fullWidth>Share CSV</Button>
<Button variant="outline">Recent ↓</Button>
<Button variant="text">Select</Button>
<Button variant="danger">Delete</Button>
```

Exactly one `primary` per screen — it is the thing the user came to do (Share CSV,
Create, Start scanning). Press state is opacity; never a color change.

---

## Chip

A small mono badge.

```jsx
<Chip>PSA 10</Chip>
<Chip tone="quiet">Year</Chip>
<Chip tone="source" color="var(--src-cy)" order={5}>CY Price</Chip>
```

Export column chips carry `order` — the number IS the column position in the file,
so it has to be visible.

---

## Icon

One Lucide glyph. Icons are functional only — controls and tabs, never decoration.

```jsx
<Icon name="scan-line" size={17} />
<Icon name="funnel" size={14} color="var(--cyan)" />
```

Requires `<script src="https://unpkg.com/lucide@latest"></script>`. Default color is
`--text-secondary`; cyan only when the glyph is part of the active control.

---

## SourceToggle

The CL | CY | JP switcher. One instance, global state, on every tab's context line.

```jsx
<SourceToggle value={source} onChange={setSource} />
```

The active segment fills with that source's own hue, so the toggle teaches the color
code every time it's used. Never let it hide the other two prices on a row.

---

## PriceTriple

Three prices, one card. The active source leads; the others trail in the meta line.

```jsx
<PriceTriple prices={{ CL: 4177, CY: 5071, JP: null }} source="CY" />
<PriceRest prices={{ CL: 4177, CY: 5071, JP: null }} source="CY" />
```

Non-negotiable: a missing price is `—`, never `$0` and never blank. All three
sources stay visible on the row no matter which one is active.

---

## ConfidenceMeter

How sure the match is. Sits right-aligned on the card row's second line.

```jsx
<ConfidenceMeter value={5} source="CL" />
<ConfidenceMeter value={2} source="CY" />
```

Never color it with a price-source hue — the whole point is that a meter and a source
can't be confused.

**The segment count belongs to the source, not to us** (2026-09-03). Card Ladder
publishes a 1–5 confidence and shows five steps in its own UI, so CL draws five.
Courtyard's API carries a 1–5 as well, but its app only ever renders low / medium /
high beside the price — drawing five there claims a resolution Courtyard never
stated, which is the no-fabricated-numbers rule applied to a match figure. CY draws
three: 1 low, 2–3 medium, 4–5 high, the same split the tones already use.

Both meters are the **same overall width** (43pt: five 7pt segments, or three 13pt
ones, on 2pt gaps). They share one right-aligned slot on the card row and stack in
the detail screen's price panel, so a scale that changed the width would make the
row's right edge jump when the source toggle flips.

---

## GroupTag

A buyer group. Dot + name, always together.

```jsx
<GroupTag name="pete" color="var(--group-1)" />
<GroupTag name="justin 18" color="var(--group-2)" size="md" />
```

Group names are whatever the user typed — `philcgc`, `Triumph 7/24`, `s`. Render
them verbatim; never capitalize or reformat.

---

## CardRow

The inventory row. Everything about a card, three lines, one panel.

```jsx
<CardRow
  name="Japanese Rulers of the Heavens Rayquaza"
  prices={{ CL: 4177, CY: 5071, JP: null }} source="CY"
  year={2006} category="Pokemon" cardNumber="4"
  confidence={5} cert="84920117" grade="10" grader="PSA"
  group="pete" groupColor="var(--group-1)" />
```

Selection mode is `selectable` + `selected` on the same rows — not a different
component and not a different screen. Missing prices are em dashes. Never drop the
thumbnail: it's a photo of the slab, which is how a sourcer recognizes the card.

---

## SummaryBlock

The two money figures. Always both, never one.

```jsx
<SummaryBlock total={121600} payout={15348} matched={145} of={255} />
<SummaryBlock total={6419} payout={0} matched={0} of={4} scoped />
```

A group with no matched cards legitimately shows `EST. PAYOUT $0` and `0 of 4
matched` — that's information, not an error state.

---

## ScreenHeader

Every screen starts with this.

```jsx
<ScreenHeader context="255 cards" title="Inventory" source={src} onSource={setSrc}
  actions={<Button variant="text">Select</Button>} />
```

The context line must always reflect live scope — card count, selection count, row
count, filename. If it can be a static string, it's wrong.

---

## TabBar

The persistent bottom bar — four destinations, no more.

```jsx
<TabBar value={tab} onChange={setTab} />
```

Selection mode does NOT replace this bar; the selection action bar rises above it.

---

## Sheet

Bottom sheet. Filters and Groups are the same shell with different confirms.

```jsx
<Sheet title="Filters" trailing={<Button variant="text">Clear all</Button>}
  confirm={<Button variant="primary" fullWidth>Show 4 cards</Button>}>
  <SheetRow label="All cards" trailing="255" active />
  <SheetRow leading={<GroupTag name="pete" size="md" />} label="pete" sub="4 cards" trailing="›" />
</Sheet>
```

The confirm label always states the outcome with its live count. Group creation is
inline in the sheet — never a separate "manage groups" screen.

---

## SelectionBar

Rises above the tab bar in selection mode.

```jsx
<SelectionBar count={3} total={5487} onAction={handle} />
```

Keep Delete last and red — destructive stays visually separated from constructive.
The running total updates on every tap.

---

## FilterPill

The filter entry point, on both Cards and Export.

```jsx
<FilterPill onOpen={openFilters} />
<FilterPill group="pete" groupColor="var(--group-1)" onOpen={openFilters} onClear={clear} />
```

Clearing is inline — the user should not have to open a sheet to undo a filter.
Filter state persists across tabs, so Export inherits whatever Cards had.

---

## SearchSortBar

Search and sort, side by side.

```jsx
<SearchSortBar count={255} sort="Recent" dir="↓" />
```

The placeholder counts the current scope, not the library. It's one of the small
things that makes filtering feel live.

---

## PhoneFrame

Wraps a screen in a phone viewport.

```jsx
<PhoneFrame><InventoryScreen /></PhoneFrame>
```

No bezel art, no light mode.
