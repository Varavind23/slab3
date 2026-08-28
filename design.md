# Slabs — Design

> Last updated: 2026-08-24
> Status: **Caliper v1.1** — the grayscale system below is superseded.

## Source of truth

`design/caliper/README.md` is the design source of truth, with the per-component
rules in `design/caliper/reference/`. The tokens are implemented in
`ios/Slab3/DesignSystem/DesignTokens.swift` and `CaliperType.swift` — those two
files are generated from `design/caliper/reference/design-system/tokens/*.css`,
so a value that changes in the CSS changes in the Swift in the same commit.

## What Caliper overturned

The v1 system below was grayscale with **no accent color anywhere**, light and
dark, three tabs, and two price sources compared as winner-vs-loser. Caliper
replaces all four:

| v1 (retired) | Caliper |
|---|---|
| Grayscale, no accent | Dark only, cyan interface accent, two source hues |
| Light + dark | Dark only — cyan on black doesn't invert |
| `PricePair`: a winner glows green, the loser goes red | `PriceLead` + `PriceRest`: no winner, an *emphasised* source chosen by a global toggle |
| 3 tabs (Home, Scanner, Folders) + hamburger Settings | 4 tabs (Scan, Cards, Export, Settings) |
| Folders | Groups (same entity, new vocabulary) |
| Rounded surfaces | Square. Radius 3 is the maximum and only controls get it |

The red/green judgment pair is gone with the winner concept. Warm tones now carry
**confidence**, and are deliberately never a source hue so a meter can't be
misread as a price.

## What carried over unchanged

- **Never fabricate a price.** A source with no data renders an em dash — never
  `$0`, never blank. This was the strongest rule in v1 and it is the strongest
  rule in Caliper.
- **Copy states what happened and what to do**, without apology or personality.
- **Numbers are the content.** The money is the biggest thing on screen; the page
  title is deliberately small.
- **Colour is never the only channel.** A group's hue always travels with its
  name; the confidence meter is a count of filled segments, not a hue alone.

## Still unanswered

`design/caliper/README.md` closes with six open questions for the client. Four of
them gate work that is deliberately *not* built: how
confidence is really computed, who authors buy ranges, and what the payout rate
is. Where those touch the UI, the app says so honestly rather than showing a
plausible number.

---

# Appendix — v1 grayscale system (retired 2026-08-24)

Kept because it records *why* choices were made, and because some of the product
rules below (the sale-limit notice, the unmatched-row states, the CSV as the real
deliverable) still describe the product.


> Last updated: 2026-08-22
> Status: Draft v1.0

This document is the design reference for Slabs. It is intentionally independent of
any code — it doesn't assume a `docs/` folder, an asset pipeline, or design tokens.
Treat it as the source of truth for visual and product identity; whoever builds the
UI translates these principles into actual code/tokens as needed.

## What Slabs is

A professional tool for people who buy and resell graded trading cards in volume:
scan a stack of slabs, get prices from multiple markets (Courtyard, Card Ladder),
organize cards into folders, export a CSV to whoever's buying. It is inventory
software, not a collector app — every card in the system is gone within weeks. It
should feel like a plain instrument that slots into a process the sourcer already
has, not a product asserting a personality. There is no accent color, no "brand"
color anywhere in this system — that was tried in an earlier pass and rejected.

Reference session, for texture: 255 cards scanned, ~$121,600 estimated value, ~$15,000
expected payout, 110 cards unmatched and needing manual attention. Buyers named Pete,
Justin, Phil, Jose. Japanese Pokémon, PSA 8 through 10, $300–$5,000 per card.

## Quick Reference

| Element | Value |
|---|---|
| Name | Slabs |
| Palette | Black/white/grayscale, no accent color |
| Functional color | Softened red / softened green — meaning only |
| Voice | Muted, quiet, no personality in copy |
| Identity lives in | Splash screen, price-number treatment |

---

## 1. Color

**No brand accent color anywhere.** No gold, no blue, nothing decorative. This was
explicitly tried and rejected — the app should not look "designed" or assert a
personality through color.

**Neutrals**
- Dark mode: black-dominant surfaces (near-black background, one or two slightly
  lighter surface elevations for cards/rows, grayscale borders and text).
- Light mode: white-dominant surfaces (near-white background, light gray surface
  elevations, grayscale borders and text).
- Both modes: everything structural (backgrounds, borders, secondary text, icons,
  nav bar, buttons) stays grayscale. No color is used to indicate "this is
  interactive" — contrast and position do that job instead.

**Red / Green — the only saturated colors in the system**
- Used strictly for meaning: better price vs. worse price, accept vs. decline,
  positive vs. negative. Never decorative, never used for branding, navigation,
  or emphasis unrelated to a good/bad judgment.
- Both hues are deliberately softened/desaturated — not stoplight-harsh. The goal
  is for the pair to read calm and coherent side by side, not alarming.
- Asymmetric treatment: the winning/positive green gets a subtle glow/bloom (the
  one moment of visual delight in the whole system). Red stays flat and matte —
  it's information to note, not a warning to dwell on. Only the positive side is
  expressive; this keeps the pair from feeling like a loud, symmetrical stoplight.
- **Color is reinforcement, never the only channel.** Red-green color blindness
  affects roughly 1 in 12 men — plausibly some actual sourcers using this app.
  The winning price needs a non-color cue too: full bold weight + a small
  leading glyph (e.g. a filled triangle or checkmark) in addition to the glow.
  The losing price stays regular weight with no glyph. A colorblind user should
  be able to tell which price wins from weight and glyph alone, with color as
  the (correct, but not load-bearing) fast path.
**Folder tag colors — the one sanctioned exception (added 2026-08-24).**
Folders carry a user-chosen tag color from a fixed set of 12 muted hues. This is an
explicit exception to "no color anywhere," justified because the color is a
*functional identifier*, not decoration: a sourcer running a dozen buyer folders at a
show recognizes "Pete = clay" faster than reading a dozen labels. It stays in bounds
by rule:
- Colors appear ONLY as the small folder-tag glyph — never as a background, button,
  price, nav accent, or anything else.
- All 12 are desaturated to the same calm register as the softened win/lose pair.
- Color is never the only channel — the folder's name is always adjacent, and the
  picker marks selection with a ring + checkmark, not hue alone.
- Graphite is the default and reads as ordinary grayscale ("untagged").
Everything else in this section still holds: red/green remain the only saturated
colors, and they remain reserved for price judgment.

- **No-winner case.** If both prices are missing, or tied, the red/green pair
  doesn't apply — see the folder row spec in Design Components for the
  no-price state.

## 2. Typography

- Numbers are the content — prices, grades, cert-adjacent data. They should be
  bold and visually prominent, carrying more weight than the labels around them.
- The winning price in a comparison gets the green glow treatment described above;
  the other price is muted into the background so the eye goes straight to the
  number that matters.
- Typeface: needs strong tabular figures and an unambiguous 0 vs. O, 1 vs. l at
  small sizes (read at arm's length, one-handed, in bad light). Exact face is not
  pinned yet — pick one when building against this doc, evaluate at actual phone
  sizes before committing.
- **Hierarchy within a folder row** (four data points competing for the same
  line): the winning price is the largest and boldest element in the row. Card
  name is next — legible but not competing with the price. Grade is smallest,
  treated as a compact chip rather than running text, closer to a label than
  a headline.

## 3. Voice & Tone

- Muted and quiet throughout: button labels, system messages, empty states.
- No personality injected into copy — no exclamation points, no celebration, no
  encouragement. The tool doesn't perform confidence or warmth; it just states
  things and gets out of the way.
- Identity is concentrated in two places only: the splash screen, and the
  price-number visual treatment. Everywhere else, stay quiet.
- Errors state what happened and what to do, without apology. Empty states
  describe the next action, not the absence of data.

**Example copy** (illustrative — final strings are an implementation task, but
these should be the register everything else is checked against):
- Empty Folders screen: "No folders yet. Start a scan to build one."
- Empty lot (opened Scanner, nothing captured): "Scan a card to begin."
- Price lookup failed for both sources: "No price found. Add manually or skip."
- Export failure: "Export failed. Check connection and try again."
- 4th duplicate added to a folder (see §5): "4th of this card + grade in this
  folder." (soft notice, not a warning — final language TBD)

**Open reconciliation — "self-intuitive, almost magical" vs. muted/no-personality.**
These aren't automatically in conflict, but they pull in different directions and
haven't been explicitly reconciled: the product spec calls for a non-technical
user base to find the app "almost magical," while this doc deliberately strips
personality from copy and color everywhere except the splash screen and price
glow. Recommended default: "magical" comes from *speed and reliability* — scan to
priced card in under a second, correct on the first try, zero screens between
scanning and seeing a trustworthy number — not from decoration, animation, or
warm copy. If that's not what "magical" meant in the original framing, flag it;
otherwise this doc's muted direction stands as the intended interpretation.

## 4. Naming

**"Slabs."** Settled. Note: an earlier version of this brief argued the name should
avoid hobby words like "slab" (to avoid reading as a collector app). The user
deliberately overrode that constraint — "Slabs" is the final name.

**Splash/intro screen**: shown on launch. Plain wordmark, "Slabs," bold, no
supporting graphic or icon. Black-on-white or white-on-black depending on mode.
This is the one screen where the identity gets to show up as itself, before the
UI goes quiet again.

## 5. Product Surface & Navigation

**Bottom tab bar** (persistent, three tabs — nothing competes with the core loop):
- **Home** — "Start Scanning" as the obvious primary action, plus recent folders
  listed below it so the user can jump back into something in progress.
- **Scanner** — capture cards one at a time; they accumulate into a lot.
- **Folders** — the list of folders (see below), plus anything not yet assigned
  to a folder surfacing at the top under a placeholder label like "Unsorted"
  (final copy still open). "Unsorted" is a pinned section, not a folder card —
  it should not visually read as one of the user's named destinations, since
  it isn't one and can't be exported the same way.

**Settings**: not a tab — a hamburger icon, top right, unfolds to reveal dark/light
mode toggle and other preferences.

**Core flow: Scan → Lot → Folder → CSV**
1. User scans a stack of cards in the Scanner; they accumulate into a lot.
2. From the lot, the user assigns cards into folders.
3. Folders are uniform — no special-casing between a folder that represents a
   person (a buyer like Pete) versus a platform (a marketplace like Courtyard).
   Just a name, a list of cards, and an export.
4. When a folder is ready, it exports as a CSV — this is the actual deliverable
   handed to a buyer, and often the only part of Slabs they ever see.
5. Archived (shipped) folders stay visible in the Folders list, not hidden away —
   just visually demoted (grayed out, pushed to the bottom).

**Resolved — folder model is generic, by design.** Sourcing regularly goes to
Card Ladder and Courtyard, but just as often to individual buyers — the uniform,
arbitrarily-named folder model is intentional, not scope creep past the approved
spec. Users can create any folder for any destination; there's no fixed two-buyer
constraint in the UI.

**Sale-limit rule (duplicate cards) — soft warning only, no hard block.** The
approved spec's 3-identical-card-per-sale rule gets a subtle, non-blocking nudge
in the folder: when a 4th identical card+grade combination is added, show a
quiet inline notice (exact copy TBD — something in the register of "4th of this
card+grade in this folder"). It never prevents the add. Styled like the folder
row's existing muted/informational state, not a modal, not red-alarm — a soft
heads-up, not an error. Server-side enforcement (if any) is a separate,
unrelated concern from this UI behavior.

## 6. Design Components

**Folder row** (list view — no thumbnails; deliberately dropped for simplicity):
- Card name
- Grade (PSA or CGC)
- Courtyard price
- Card Ladder price — the higher/better of the two prices shown in the softened
  green with glow (plus the bold-weight and glyph cue from §1); the other muted
  into the background.

**Folder row states beyond the happy path** (the reference session had 110 of
255 cards land here — this is common usage, not an edge case):
- **No price from either source**: both price columns show a plain, muted
  placeholder ("—" or "No price") in regular weight. No red, no green — the
  red/green pair only applies when there's an actual comparison to show.
- **Tied prices**: same treatment as no-price — neither gets the green
  treatment, since there's no winner to highlight.
- **Price still loading** (fetch in flight after a scan): price columns show a
  quiet loading indicator, not a flash of "no price" that then changes —
  avoids a false negative flickering past on a slow connection.
- **Unidentified scan** (camera captured something but no card/cert was
  resolved): the row still appears — probably in "Unsorted" — with name and
  grade shown as unresolved/placeholder and no price columns at all, since
  there's nothing to price yet.

**Splash screen**: full-bleed black or white background (mode-dependent), "Slabs"
wordmark centered, bold weight, no icon or illustration.

**Buttons / interactive elements**: grayscale, distinguished by contrast and
position rather than color. No colored buttons except where an action is itself
a green/red judgment (e.g., accept/decline).

## 7. Imagery

- No thumbnails in folder rows — confirmed, dropped for simplicity and to avoid
  the data/scripting overhead of thumbnail generation.
- No decorative graphics, no illustration, no stock imagery. "Very subtle
  graphics" throughout.
- Icons only where functionally necessary (nav bar, settings) — outlined, small,
  quiet, not a visual feature in themselves.

---

## Explicitly out of scope for this document

Screen-by-screen UX specs (exact row dimensions, full settings menu contents
beyond the dark/light toggle, the final typeface pick, exact hex values for the
softened red/green pair) are not pinned here. This document captures the
identity and structural principles agreed on; a separate implementation pass
should work out precise values and layouts against these principles.

## Changelog

| Version | Date | Changes |
|---|---|---|
| 1.0 | 2026-08-22 | Initial draft, based on the design conversation with the user. |
| 1.1 | 2026-08-22 | Design review pass: added accessibility cue for red/green, no-price/tied/loading/unidentified row states, typography hierarchy, voice example copy, and flagged two open decisions. |
| 1.2 | 2026-08-22 | Resolved both open decisions: folder model stays generic/any-destination by design; sale-limit rule is a soft, non-blocking inline notice on the 4th duplicate, no hard block. "Magical vs. muted" reconciliation (§3) still open. |
