# Verified Max Buy Price (pilot V5 2026-09-16; a lens 2026-09-22; for everyone since 0.9, 2026-10-01)

Moved out of CLAUDE.md (2026-10-01) verbatim. The per-file reasoning also lives in the headers of `MaxBuyPrice.swift`, `MaxBuyValue.swift`, `MaxBuyPanel.swift` / `ValueBlock.swift` and `MaxBuySettings.swift`.

**0.9 (2026-10-01, owner): the testing passcode is gone** — every user gets the MAX lens,
the panel and the CSV column, on the shipped weights (the tester judged them "about
right"). Passages below that describe the gate are history. Teams integration (team
skew/margin, per-lot CL/CY basis) is planned in
`~/.claude/plans/max-buy-for-teams-and-lot-basis.md`.

The one number in the app that is **ours**, not a source's: the most a sourcer
should pay for a slab and still clear his cut. It answers a different question from
every source price, and that premise is the thing to hold on to — **the sourcer is
PAID in Card Ladder Value**, so CLV is his revenue, not a reference price, and what
he needs is a ceiling on his offer. Entirely client-side from comps already on the
device: no Edge Function, no migration, no new request, so none of the deploy
caution in CLAUDE.md applies to changing it. Beyond this doc, the reasoning lives in
the headers of `MaxBuyPrice.swift` (the formula), `MaxBuyValue.swift` (which comps,
and the memo), `MaxBuyPanel.swift` / `ValueBlock.swift` (what is shown) and
`MaxBuySettings.swift` (the baseline and its Settings sheet).

`MaxBuyPrice` (`ios/Slab3/Pricing/MaxBuyPrice.swift`) is the whole formula, pure and
Foundation-only so the vectors test off-device the way `PriceWriteback` does:

    base = mean(newest N comps);  room = base - lowest of those N
    s    = skew + 0.80*dispersion + 0.40*bottomHeaviness + 0.35*thinness  (clamp 0…1)
    VMB  = (base - s*room) * (1 - margin),  capped at CL Value

**`s = 1` is the lowest recent sale, so at `margin = 0` the answer is always a
figure this card actually sold for.** That floor is what makes the number
defensible to the seller it gets shown to, and `margin` is the only term allowed to
cut below it — keep that property if you touch the algebra. The three weights are
**best guesses shipped to be tuned live** against the tester's own numbers (owner
decision), not fitted to data we have, so expect to move them — and move
`MaxBuyPriceTests`' three worked cases (tight/high-pop, scattered/low-pop,
bottom-heavy) with them, since those are relative assertions, not golden figures.
There is deliberately **no recency decay**: the window is "the newest N", which is
how the sourcer already thinks, and `Breakdown.newestSoldAt` rides up so the panel
can show how old the evidence is instead of hiding a second opinion in a half-life.

Same honesty rules as prices: no usable comps is **no number** (`.unavailable(.noComps)`
→ em dash + a reason, never `$0`), and an **unknown population contributes zero**
rather than being read as a small one — while a real `0` (CGC pristine-10 groups
report one) is the thinnest market there is.

`MaxBuyValue` (`ios/Slab3/Pricing/MaxBuyValue.swift`) is the ONE place that decides
which comps, which cap and which population — six consumers now show this figure and
six copies of that rule is six chances for the list and the screen being held out to a
seller to disagree. Inputs:
- **Comps**: Card Ladder's when the card has any, else Courtyard's; an **empty** CL
  list means "CL answered and has none" and falls THROUGH rather than answering. They
  are already filtered to this slab's own grader AND grade — `applyScannerSales` for
  CY, server-side for CL — so `[]` is a real answer, not a bug. Consequence to know:
  CY comps arrive on the scan but CL comps only when a card's detail screen is opened
  with an account connected, **so a card re-prices the first time it is opened**. That
  is accepted, not a defect; fetching comps in bulk is what the 200/day budget forbids.
- **The cap** is always `card.prices[.cl]`, whichever source supplied the comps; no
  CL Value means no cap, not no number.
- **Population** is `card.courtyardPopulation`, and **Courtyard is the only source
  that carries one** — a card CY 400s on has CL comps and no census, and the
  thinness term just goes quiet. Written only on the two authoritative scanner
  branches (`PriceService.applyScannerPopulation`, so an outage keeps the last
  figure), grade-group first then the card-level total, mirroring `populationForGrade`
  in the worker adapter. It is `Int?` and additive per the SwiftData rule in CLAUDE.md.

**The lens.** `PriceLens` (`.maxBuy`/`.cl`/`.cy`, in `DesignTokens.swift`) sits ABOVE
`PriceSource` and drives the header toggle's third segment, `MAX`, leftmost. It is deliberately **not** a third `PriceSource` case:
that enum indexes stored per-source data (`PriceSet`, `ConfidenceSet`,
`Card.sales(for:)`, `PriceRest`'s "every other source"), and max buy has no stored
price, no confidence and no comps of its own — a third case there compiles and is then
silently wrong in ~10 `source == .cl ? … : …` ternaries. `AppState.activeSource` keeps
its exact meaning and all 13 read sites; `lens` persists ONLY max buy, and a CL/CY lens
is always derived from `activeSource` — a stored source lens let Settings' "Default
emphasis" and the comps toggle move the sort and totals while the header kept the old
source. Choosing max buy writes NO source, which is what makes flipping back land where
you were. `SalesPanel` keeps its own two-way `SourceToggle` — which comps you are
*reading* is a different question from which figure *leads*, and writing `activeSource`
there must not knock you off max buy (under a CL/CY lens it moves the hero with it).

Under the lens: the row's lead figure, the detail hero, the scan toast, selection
mode's running total, the price sort AND the Cards summary total all become max buy
(the summary since 2026-09-25, owner decision — it headlines "Max buy total" and hides,
without collapsing, its payout half, since payout is a share of CL value, not of what he
pays); Export's footer total deliberately does **not**, because the CSV is what a buyer
sees. Both on-screen totals go through `LensTotal` and LABEL their basis ("MAX BUY" /
"EST. VALUE", plus "12 selected · 9 priced" when cards lack a figure): testers read
max-buy rows while an unlabelled bar summed CY value, and called it a broken sum. Row line 2 shows BOTH source prices
(nothing may hide a source), and the confidence slot goes **blank at its full 43pt** —
a meter grades a source's OWN confidence in its price (CL's real 1–5 since 0.7 — it
was pinned at 5 before), not our arithmetic, and borrowing one would also leak
which source answered, since CL draws five segments and CY three. Nothing on the row
names the comps basis, by owner decision: the screen gets held out to the person being
bought from, and that disclosure lives behind the panel's "More".

**`MaxBuyCache` is required, not an optimisation.** `card.cardLadderSales` /
`courtyardSales` run a `JSONDecoder` on EVERY property read, `CardsScreen.visible` is
evaluated several times per body pass, and sorting values every card in the store — so
an uncached lens costs tens of thousands of decodes a frame. The memo is stamped on
`(compsRevision, cardLadderPriceCents, courtyardPopulation, knobs)`; the row reads those
inside `body`, so a write both redraws the row and misses the cache on the same pass.
`Card.compsRevision` is bumped inside the two comps SETTERS — never write the
`…SalesData` blobs directly or a stale figure stays on screen. Keep the cache a
`@MainActor enum`, never `@Observable`: it is written during `body`.

`CSVExport` stays **nonisolated** and takes max-buy values as a `[UUID: Int]` the caller
resolves (`MaxBuyValue.centsByCard`). Isolating it to reach the main-actor memo
isolated `filename`/`rows` too and broke the offline CSV tests. The `max_buy_price`
column is never on by default (`CSVColumn.defaults`) — the CSV is the part of this app a
buyer sees, and it states the most you were willing to pay.

`MaxBuyPanel` shows **nothing but the number until "More" is tapped**, and that is
the feature, not a default: the tester holds this screen out to the person he is
buying from, so sliders, his margin and the weights must not be in frame. It is a
deliberate exception to SalesPanel's "empty is REAL CONTENT, never a hidden panel"
rule — that rule is about hiding data a user knows exists, and this whole feature is
undisclosed. The figure takes `.figureSmall` and `Caliper.textPrimary`: never the
screen's one hero `.figure` (that is `valueBlock`'s), and never a source hue, which
would claim CL or CY asserted it.

Knobs live on `CardDetailScreen` (not the panel) so the **hero follows the sliders
live** — two differently-tuned figures on one screen, both labelled "Max buy", is the
misreading the hero's toggle-following rule exists to prevent. The list always shows the
baseline figure, so a tuned card legitimately reads differently there: the panel is the
negotiation scratchpad, the list is one consistent basis. They are **per-card and reset
from `MaxBuyDefaults` on every card** so a figure tuned in one negotiation cannot silently
follow him into the next; the baseline itself is edited once, in Settings → Max buy
(`MaxBuySettingsSheet`). Until 0.9 the feature sat behind a plain-text passcode
(`TestingGate`, removed); old installs may still carry a `caliper_testing_unlocked`
key that nothing reads.
