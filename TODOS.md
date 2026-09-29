# TODOS

## Offline scan queue (deferred 3A, approved D11 — 2026-08-21)

**What:** Full offline scanning with pending-op queue + bidirectional sync.

**Why:** Sourcers scan at card shows/warehouses with dead zones; v1 is
online-required with durable retry (D9), so a true dead zone means scanning stops.

**Pros:** Restores the scan-anywhere guarantee; strongest field UX.
**Cons:** Sync/conflict complexity (multi-device semantics, server-wins rules).

**Context:** v1 ships online-required with a durable retry queue for failed
requests. This TODO is the upgrade path if buyer feedback shows connectivity pain
in the field. Start from `ios/` LocalStore retry queue — extend it into a full
pending-op queue with sync on reconnect.

**Blocked by:** v1 local store shape shipping first.

## Courtyard scanner API — RESOLVED 2026-08-31, shipped in 0.3 (build 3)

Phases 1-3 are done. The endpoint is
`GET api.courtyard.io/scanner/card-details?cert=&grader=` — unauthenticated,
cert-keyed, one call for price + identity + grade-split comps. Found by tearing
down the Android app (Hermes bytecode: `strings`, not `grep`). The acceptance bar
is met live: cert 96679812 = $50.80 / confidence 2, what their own app shows.
Full record: `spike/README.md` §2b. Code: `_shared/courtyard-scanner.ts`,
`courtyard-price`, `CourtyardScannerClient.swift`.

**Phase 2 (account connect) is retired, not deferred** — the endpoint is public,
and anonymous and bearer responses are byte-identical. Do NOT build
`courtyard-connect` for pricing. The Privy OTP relay (§2a) still works if some
future feature needs a user session.

**Phase 4 (simulator QA) is still open** and independent. Slabs test account is in
`spike/.env` (`SLABS_EMAIL`/`SLABS_PASSWORD`), so the UI can be driven in the
simulator without the owner's phone — **but those credentials no longer work**:
`/auth/v1/token?grant_type=password` returned `invalid_credentials` on 2026-09-03.
The account needs recreating or the password resetting before Phase 4 can run, and
before any Edge Function can be smoke-tested end to end from this machine (see
`supabase/EMAIL.md` — nothing sends until a confirmation flow is turned on). Pairs with
`ios/Tests/DetailScreenRenderTests.swift`, which renders panels to PNG — layout
bugs shipped green three times because nothing asserted on layout.

## Teams — deferred from the teams-first overhaul (2026-09-28)

Everything Teams is LOCAL-only until the owner ships it (CLAUDE.md, "Teams").

- **Going live** is a separate, owner-approved release: `db push` of the four Teams
  migrations, then a build with `TeamsFeature` answering from something other than
  `Backend.isLocal`. Plan it as its own step; nothing here assumes it.
- **Team Card Ladder budget.** Every lot claim may refresh CL on a cold cache, against
  the 200/day per-user budget. Raising it for team members is an Edge Function deploy.
- **`lot_bands` is unread** since `20260928000000_bucket_band.sql` (bands are a label on
  the bucket). Drop the table once nothing needs its history.
- **Closed-lot claims load with every refresh** (`LotStore.load` fetches all lots'
  claims). Fine at a few lots; fetch closed ones lazily when Team activity opens.
- **Reported numbers UI is hidden** (owner, D23): `RangeReport`, `LotDashboard.reported`
  and `lot_range_reports` are kept; bringing them back is only `LotDashboardView`.
- **Screenshot import** of the lot buyer's allocation screen (teams.md §7) — not built.
- **The two-account end-to-end check** (lead + buyer, real CL-connected claims, the
  3-per-lot block, an offline release draining on reconnect) needs a Card Ladder
  account on the local stack; the Simulator runs so far used seeded claims.

## Courtyard cleanup — three known gaps (deferred 2026-09-03)

Found while fixing the User-Agent wall (`spike/README.md` §2c). All three were
assessed and **none blocks basic workability**, which is why they are here and not
in that fix. Listed most-worth-doing first.

### 1. `loadSales` still falls back to the legacy Algolia comps path

`PriceService.loadSales` (`ios/Slab3/Pricing/PriceService.swift:284`) calls
`courtyard.recentSales(...)`, the pre-scanner Algolia path, which hits
`api.courtyard.io/index/*` **directly from the phone** — the prefix that is
IP-blocked on consumer networks. The scanner already returns comps, and
`applyScannerSales` stores them on both the `.ok` and `.noPrice` paths.

**Why it is not urgent:** dormant in practice. `loadSales` is only called from
`CardDetailScreen.swift:63`, always with the default `force: false`, so the legacy
branch runs only when `card.courtyardSales == nil` — which now happens only on the
`.unavailable` path. Worst case it returns `[]` and the user sees an empty comps
panel, never another card's sales.

**Why to do it anyway:** it is dead weight on a wrong-source path, and it would
wake up if anyone ever calls `loadSales(force: true)` — which WOULD overwrite good
scanner comps with the Algolia answer. Delete the fallback and let the scanner own
Courtyard comps outright.

### 2. The server's `stale` flag never reaches the app

`courtyard-price` returns `stale: true` when it serves a cached row because the
source is failing right now (`supabase/functions/courtyard-price/index.ts`), but
`CourtyardScannerClient.Reply` does not decode the field, so the app cannot tell a
live number from a last-known one and shows both as current.

**Why it is not urgent:** the number displayed is real, just possibly up to 24h
old. Nothing is wrong-valued.

**Why to do it anyway:** the price rules say a transient failure "keeps the last
value and marks the column stale" — the marking half is currently missing, and
this codebase holds itself to that line explicitly.

### 3. No retry on a transient 502

`fetchCardDetails` is single-attempt. A 502 from Courtyard's GemRate upstream on a
**freshly scanned** card — one with no cached row and no last value — shows an em
dash until the user manually refreshes.

**Why it is not urgent:** the 24h cache and the never-blank rule already cover any
card priced once, and this is pre-existing behaviour, not a regression.

**Why to do it anyway:** one bounded retry with a short backoff would close the
worst case, which is the first impression of a brand-new scan. Keep it bounded —
Courtyard 403s an IP that hammers it.

### 4. CGC qualifier grades collapse, and show the WRONG comps (found by codex review, 2026-09-05)

**Verified against the checked-in fixture, not theory.** `gradeLabel()` reduces any
grade to its first number, so CGC's `g10pristine` becomes `"10"` — identical to an
ordinary CGC 10. `worker/test/fixtures/courtyard-scanner-cgc.json` contains BOTH
groups:

```
grader=CGC raw_grade='10'          -> "10"   pop=97  9 sales
grader=CGC raw_grade='10pristine'  -> "10"   pop=0   3 sales
```

`salesForGrade` selects with `.find()`, so a **Pristine 10 slab is shown the ordinary
CGC 10 sales and population 97** — another grade's numbers presented as this card's.
That is the same class of error as pricing the wrong card, which this codebase treats
as the cardinal sin. `card_key` collapses the two grades too, so the sale-limit rule
counts a Pristine 10 and a regular 10 as the same card.

**Pre-existing** — not introduced by the grader-fallback work — and it affects only
CGC qualifier grades (pristine/perfect), which is why it has gone unnoticed.

**Why it is not a one-line fix, and needs a decision:** the app only ever receives the
NORMALIZED grade, so the qualifier has to survive the whole path — a `gradeRaw` on
both `CyIdentity` and `CySaleGroup`, a column on `cy_scan_cache`, the `courtyard-price`
reply, and `CourtyardScannerClient`. Changing `gradeLabel` itself is the wrong fix:
it is one of the three byte-identical `card_key` implementations
(SQL / Swift / TypeScript), so touching it changes every existing key.

### 5. Use `/scanner/card-grader-image` for slab photos — DONE 2026-09-05

**The opportunity, found while replaying two production certs** (`spike/README.md`
§2e): Courtyard has a THIRD scanner endpoint that returns real front AND back slab
photographs, cert-keyed, and it answers 200 even for certs whose pricing 404s.

Today `fillCourtyardImage` sources Courtyard imagery from ALGOLIA — the marketplace
index — so it misses precisely the cards Courtyard cannot price, and those rows fall
back to the camera capture. PSA's cert page is 403-walled (§4a) and carries no photo
without SecureScan, so for many slabs there is no official image at all.

Because it is cert-keyed it clears the standing "official image only on an exact cert
match" rule by construction. It also returns the BACK of the slab, which no current
source does.

**Worth doing because it is the difference between a demo row that looks empty and one
that looks right**, even when Courtyard has no price for the card.

**SHIPPED.** `fetchGraderImages` in `_shared/courtyard-scanner.ts`, wired into
`courtyard-price` on BOTH the priced and the 404 paths (and passed through on a
cached 404, or a cache hit would be worse than a miss), consumed by
`PriceService.fillCourtyardImage`, which now prefers the cert-exact URL and keeps
Algolia only as a fallback. Fixtures captured from the live endpoint. Still open: the
BACK of the slab is fetched and parsed but has nowhere to go in the UI, and is not
persisted — `cy_scan_cache.image_url` holds the front only. Adding it is a migration
plus a place to put it, so it waits for a design decision.

### Also unresolved from the same investigation

* **`PriceRefresher.fastGap` is 120 ms** on a Courtyard-only bulk run
  (`ios/Slab3/Pricing/PriceRefresher.swift:26`). Whether the `/scanner/*` wall is
  also rate-scored on top of the UA rule is **unknown** — worth settling before a
  user runs a 200-slab stack.
* **The deployed function's outbound User-Agent was never observed.** The CLI here
  (2.98.2) has no `functions logs`, and reading the PAT was blocked. Upgrading the
  CLI would let us confirm the 403 rate before/after the fix, i.e. whether the UA
  wall was *the* bug or merely *a* bug.
