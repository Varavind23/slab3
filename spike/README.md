# M0 Go/No-Go Spike

Three questions gate the whole build (plan: M0). Fill in the verdicts below as you
run each part. Exit criteria: every verdict box answered, with evidence.

## Setup

```sh
cd spike && npm install && npx playwright install chromium
```

## 1. Card Ladder (needs a real account — YOUR credentials, never committed)

```sh
CL_EMAIL=you@example.com CL_PASSWORD=... npm run cardladder -- "1999 Pokemon Base Set Charizard PSA 9"
```

Runs headed so you can watch for 2FA/captcha. Session cookies save to `.state/`
(gitignored); rerun to test persistence.

**Verdict (run 2026-08-21):**
- [x] Login scripted OK? **YES — Firebase email/password, landed on /dashboard.**
- [x] 2FA type: **NONE** — straight to dashboard, no second factor prompted.
- [x] Cookie session survives rerun? **YES — storageState reuse skips login entirely.**
- [x] Internal JSON API observed? **Auth: `identitytoolkit.googleapis.com/v1/
      accounts:signInWithPassword` (Firebase). Search/prices:
      `search.cardladder.com/search`. Project: `cardladder-71d53`.**
- [~] Price readable + metric? **Search API confirmed firing; exact avg-price field
      in the response body deferred to M3 (needs the app's real search-box
      interaction). Metric to display = AVERAGE SALE per buyer decision.**
- [x] Bot challenge? **reCAPTCHA v3 (invisible) via `httpVerifyRecaptcha` cloud
      function — auto-passed with a normal browser UA; NOT Turnstile (that 403 was
      the marketing site's /login 404, a dead route). No manual challenge.**
- **GO / NO-GO (REVISED 2026-08-21 after deeper testing):** **CONDITIONAL — headless
      scraping is NOT viable.** After sustained automated access, Cloudflare escalated
      to an INTERACTIVE Turnstile "verify you are human" challenge on `app.cardladder.com`,
      and `search.cardladder.com` (the data host) returns Cloudflare "Just a moment..."
      too. Both hosts are Cloudflare-protected. The one-time login success in the
      earlier spike was before escalation. Fully-headless Card Ladder automation gets
      walled by interactive human-verification.**

**Card Ladder is viable ONLY via one of:**
  1. **Official API / data-partner access** (the Assignment — friend's relationship).
     Now the strongly-preferred path, not optional.
  2. **Human-in-the-loop session**: user logs in themselves in a REAL browser (solves
     any challenge as a human), we import those cookies and ride the session until
     Cloudflare invalidates it. Their own account, human-verified — but fragile,
     needs periodic re-auth, and headless API calls may still re-challenge.

Automating the login/scrape headlessly is what trips Cloudflare. This validates the
plan's #1 risk and Codex's warning to spike Card Ladder before heavy build. Courtyard
(separate infra) is unaffected — its recent-sale API works via browser context.

**REVISED AGAIN (2026-08-24) — SOLVED, DONE. The "no headless bypass" verdict was too
pessimistic: Turnstile only guards the web SPA and `search.cardladder.com`. Card
Ladder's real data plane is Firebase Cloud Functions on Google hosts
(`us-central1-cardladder-71d53.cloudfunctions.net`) that are NOT behind Cloudflare and
take a plain `Authorization: Bearer <Firebase ID token>`.** Verified live end-to-end:
`accounts:signInWithPassword` (public key `AIzaSy…bkAHM`) → `httpbuildcollectioncard
{cert,grader}` → `{profileId, grade:"g9"}` → `httpcardestimate {profileId,
gradingCompany, condition:<grade>}` → `oneMonthData.averagePrice` = the average-sale
metric (live sample: $116.92). **Gotcha:** `condition` MUST be the grade code (`g9`);
`"PSA 9"`/`"9"` return all-zeros. `search.cardladder.com` stays Cloudflare-walled (403
even with Bearer + browser UA) — we route around it. Firestore `:runQuery` on `cards`
also works with the Bearer token (fallback). Shipped: bring-your-own-account —
each user connects their OWN paid CL login; server (Supabase Edge Functions) stores it
encrypted and does the lookups. See `supabase/functions/_shared/cardladder.ts` (the
verified client, shared with `worker/`), `cardladder-{connect,price}`, and
`worker/test/cardladder.test.ts`. The old `spike/cardladder/*.ts` (headed login +
session capture) are obsolete — kept only as history.

## 1a. Card Ladder metric + sales history — REVISED 2026-08-29

**§4's recorded metric is OVERTURNED.** "Card Ladder metric: average sale
(confirmed 2026-08-21)" was a buyer's answer to *which number do you use*, and we
implemented it as `oneMonthData.averagePrice`. That was the wrong field, and it
failed silently: the 30-day window is EMPTY for plenty of cards Card Ladder knows
perfectly well, a 0 average maps to null, and the row then shows no Card Ladder
price at all. First TestFlight users reported exactly this. Worked example, live:

| cert | one-month avg (shipped in v1) | `estimatedValue` | `lastSalePrice` | comps |
|---|---|---|---|---|
| 20360362 (McHale PSA 9) | 117.36 | **120** | 120 (8/28) | 20 |
| 96679812 (Curry PSA 10) | **0 → no price shown** | **89** | 46 (2025-07-09) | 6 |
| 154334127 (Hamilton PSA 9) | 0 | null | null | 0 |

### The un-walled origin (how any of this was findable)

`app.cardladder.com` is Cloudflare-Turnstile-walled, but the SAME SPA bundle is
served from Firebase's default hosting domain, which is not:

```sh
curl https://cardladder-71d53.web.app/            # 200 (app.cardladder.com → 403)
curl https://cardladder-71d53.web.app/assets/index-<hash>.js
```

Mining that bundle gives their field/label table and their full callable list:
`httpbuildcollectioncard httpcardestimate httpcardimagedetection httpcertlookup
httpexcludeprofilefrommatch httpmatchprofiles httpprofile httpprofilesales
httpsaleprofile httpsuggestsetprofilematches`. Re-mine here when a field moves;
the hashed asset name changes per deploy, so read it out of the HTML.

### The right fields

Their own tooltips: `currentValue` → label **"Value"**, *"Card Ladder Value of the
card using our proprietary algorithm"*; `marketValue` → label **"Last Sold"**.

**TRAP — do not source the headline from `httpbuildcollectioncard`.** Its
`currentValue`/`marketValue`/`guideValue` are **collection-context only**:
populated for a card in YOUR CL collection, `null` for every other card (verified:
20360362 owned → 120; 96679812 and 154334127 not owned → null). The
general-purpose equivalents are on `httpcardestimate`, which we already call:

* **`estimatedValue`** = Card Ladder Value → the headline. For the owned card it
  equals `currentValue` exactly (both 120), which is what confirms the identity.
* **`lastSalePrice`** + **`lastSaleDate`** = "Last Sold".
* **`confidence`** = their own 1–5, same scale as the app's ConfidenceMeter.

The window averages stay on the payload and are still parsed; they simply lead
nothing now.

### `httpprofilesales` — real comps, SOLVED

Same un-walled Firebase host, same Bearer token. Its own 400 body documents the
contract: *"Must provide one of: (cert + grader), (psaSpecId + grader), (gemRateId
with optional grade/grader/qualifierType), or universalGemRateId"* — **cert +
grader is exactly what the scanner has**, so no profileId and no resolve step.

Returns `{sales, totalHits}`, date-descending, **already filtered to the same card
AND the same grade server-side** (20360362 → 20 sales all g9; 96679812 → 6 all
g10). Per-sale: `price date platform listingType title url cert grade thumbnail
seller feedback`. So these are true comps, not a mixed feed.

Cost: it is a SECOND callable per card. Fetched lazily on the detail screen only —
never on a scan or bulk refresh — or a 200-slab stack would spend its 200/day
budget on comps nobody opened. Net usage still DROPS, because the price no longer
needs `httpbuildcollectioncard` at all.

### Also found, not yet used

`httpcertlookup {cert, grader}` → `{label, grade, grader, graderId, dateGraded,
profileId, source}`. A cert→identity path carrying `dateGraded`, which PSA itself
will not give us while its wall is up (§4a). Option, not shipped.

### 1b. What Card Ladder returns for POKEMON, and why card_key could not be a cache key — 2026-08-31

Opened by a V2 report: a PSA 9 slab showed a PSA 10's value. Not a scanning bug —
the barcode carries a cert number and nothing else. Probed `httpbuildcollectioncard`
live with three real Pokemon certs (taken from the Courtyard fixture):

| cert | profileId | set | player | # | year | grade |
|---|---|---|---|---|---|---|
| 98881872 | `psa-5850773` | Pokemon Celebrations Classic Collection | Charizard-**Holo** | 4 | 2021 | g10 |
| 77286827 | `psa-544027` | Pokemon Game | Charizard-**Holo** | 4 | 1999 | g6 |
| 51203633 | `psa-1724389` | Pokemon Expedition | Charizard-**Reverse Foil** | 40 | 2002 | g10 |

**Pokemon field shapes, for anyone matching against this source.** The variant is
baked into `player` (`Charizard-Holo`, `Charizard-Reverse Foil`), not into the
absent `variation` field, which came back empty on every card probed. `set` is
fully qualified (`Pokemon Celebrations Classic Collection`, not `Celebrations`)
and carries no year. `category` is `Pokemon`. So `set` + `player` discriminates
Pokemon far better than it does the sports cards this was first tested on — which
is why the card-number axis is a low-risk collision here.

**The one that is NOT safe: `set` reuses a name across printings.** Card Ladder
calls the 1999 Base Set `Pokemon Game`, and that name is shared by the printings
a 1st Edition / Shadowless / Unlimited Charizard belongs to — an order-of-magnitude
price difference. **Unverified**: no 1st Edition or Shadowless cert was available
to probe. Do not assume set+player+year is sufficient for Pokemon until one is.

**What this settles.** Do not rebuild a source's identity out of the source's own
text fields and use it as a key. `httpcardestimate` takes `profileId` and
`condition` (the grade code) as SEPARATE arguments — that is the proof profileId is
card-level and grade-independent, so `{profileId}:{gradeCode}` is exactly one
priced thing at Card Ladder, by construction, with no reconstruction to get wrong.
That pair is now the cache key for price, identity and comps (see
`clSourceKey`, and the migration `20260831000000_cl_profile_keyed_cache.sql`).

The key it replaced, `card_key`, was wrong twice over: no source ever populated a
`grade` (PSA is walled per §4a, and Courtyard's matcher refuses to run without a
grade in hand, so neither could supply one), so every key ended in a bare `:` and
every grade of a card collapsed onto one row — and the caches are GLOBAL, so the
first grade anyone scanned answered for all of them. `card_key` keeps its real
jobs: the per-folder sale limit and cross-source matching.

## 2. Courtyard (no account needed; curl already 403s — bot wall confirmed)

```sh
npm run courtyard -- "charizard base set psa 9"
```

**Verdict (run 2026-08-21):**
- [x] Real browser passes bot wall? **YES — 200 (curl gets 403, browser passes)**
- [x] Internal JSON API observed, usable without auth? **YES — api.courtyard.io
      answers plain curl with browser-ish headers. Endpoints seen:
      `/index/transactions?tx_type=sale` (recent sales w/ paymentAmount, USDC
      6-decimals, chain=polygon), `/index/query/recent-pulls`, `/orderbook/config`.**
- [x] Listing/floor price readable per card+grade? **YES — SOLVED via Algolia.**
- **GO / NO-GO:** **DONE (2026-08-22).** Courtyard search is Algolia on algolia.net
      (NOT behind Cloudflare), public search key `3b3ed...`, app `Y8TL3M06QA`,
      index `marketplace_prod_recently_listed`. Query it DIRECTLY — no browser, no
      bot wall. Records carry card metadata + cert + estimatedValueUsd (confidence)
      + current listing + lastSaleDate. Adapter live-verified: Charizard Base Set
      PSA 10 → $537, Pikachu PSA 9 → $761. See worker/src/sources/courtyard-algolia.ts.

**Card Ladder vs Courtyard (why one worked and the other can't):** Courtyard's app
calls Algolia directly (client-side public key) → bypassable. Card Ladder proxies
ALL search through its own `search.cardladder.com` backend, which is Cloudflare-
Turnstile-walled like the rest of its stack — there is NO direct third-party search
service to hit. Confirmed 2026-08-22. So Card Ladder remains: official API (friend's
ask) or human-obtained session only. No headless bypass exists.

### Courtyard sale prices + the app's own number — added 2026-08-29

Asked because users wanted "the value Courtyard's own scanner shows" plus real
comps. Mining courtyard.io's Next.js chunks turns up `fmv_estimate_usd` /
`fmvEstimateUsd` / `estimatedValueUsd` and nothing else price-shaped, so the
scanner's number IS the FMV estimate — the field `courtyard-algolia.ts` already
reads. What was missing is Courtyard's own `estimatedValueConfidence` (1–5, sent
as a STRING on live records), now surfaced, but ONLY on an exact cert match: on a
fuzzy hit the value belongs to a different card.

Three new findings:

* **`marketplace_prod_recently_sold`** exists alongside `recently_listed` (same
  app, same public key). Full index list: `marketplace_prod_{asset_ownership,
  asset_ownership_listed_date_desc, asset_ownership_price_high_to_low,
  asset_ownership_price_low_to_high, best_deals, price_high_to_low,
  price_low_to_high, recently_added, recently_listed, recently_sold}`.
* **`proofOfIntegrity` on an Algolia hit IS the `assetID`.** That is the
  card_key→assetID resolution `courtyard.ts:resolveAssetId` has been stubbed out
  waiting for (D10).
* **`GET api.courtyard.io/index/asset/{assetID}/transactions`** returns that
  slab's own ledger on a PLAIN request — no browser, no auth — unlike
  `/index/asset/{id}`, which is still Cloudflare-fingerprinted. `paymentAmount` is
  USDC 6-decimals: `209810000` → **$209.81**, verified.

**Cert is NOT facetable.** `facetFilters: ["certification.number:…"]`,
`filters: 'certification.number:"…"'` and `metadata.Serial` all return `nbHits: 0`.
Cert matching must stay client-side over query hits — do not "fix" it into a
filter.

**Comp coverage is genuinely thin.** Sampling 10 `recently_sold` hits, only **2**
had a sale transaction at all; the rest carry a lone `mint` (a vending-machine
pack purchase, `paymentToken: "stripe"` — not a comp for the card). So an empty
Courtyard comps list is the normal case and is never treated as an error. Card
Ladder is the real comps source; Courtyard's is a bonus when the slab has traded.

### Courtyard identification is a DEAD END via Algolia — 2026-08-29 (evening)

Found by testing V2 on a real slab: cert 96679812 (2022 Optic Splash! #10 Curry,
PSA 10) showed **$18 at confidence 1/5** in Slabs, while Courtyard's own app,
scanning the same slab, showed **$50.80 at confidence 2**. We were pricing a
DIFFERENT Curry. Three separate findings, all verified:

- **Cert is neither facetable nor searchable.** `facetFilters`, `filters` and
  `restrictSearchableAttributes: ["certification.number"]` all return `nbHits: 0`.
  A bare cert query is worse than useless: typo-tolerance returns near-miss cert
  numbers belonging to unrelated cards (query `41066652` → `4065652010`,
  `47076652`, ...). **That near-miss behaviour is how a wrong card gets priced.**
- **The indices are recent-activity feeds, not a catalog.** Assets churn out of
  `recently_listed`/`recently_sold`. The Charizard EX (cert 41066652) was present
  in the morning and unfindable by evening — its ledger shows a `burn`, i.e.
  redeemed out of the vault. So even a perfect query can't find a card that has
  aged out.
- **Query text cannot rescue it.** For a card known to be indexed, none of
  `"Charizard EX"` (2623 hits), `"Charizard EX <set>"` (24), `"2014 <set> XY17
  Charizard EX"` (10) surfaced the target within 40 hits.

**Consequence, and what shipped:** the price now requires the hit to actually
identify the card — cert exact, or year + card number + grade all agreeing.
Everything looser returns `not_found` and the UI shows an em dash. This blanks
Courtyard for most scanned cards, which is the honest outcome: a price belonging
to another card is a fabricated price for this one, and the em dash is what we
owe the user. The old grade-only and top-hit tiers are gone.

**What Courtyard's app is actually doing (NOT yet found).** It priced a slab that
is not in the marketplace index at all, so its scanner is backed by a pricing
MODEL over card identity + grade, not by vault inventory. Endpoint unknown:
`/index/attributes` answers `{"":{}}` to every parameter guess, and
`/index/asset/{id}/estimate` is per-vaulted-asset (404s for most). Almost
certainly in the mobile app, plausibly behind an account. **Finding it needs a
real spike — proxy-capture the Courtyard iOS app while using its scanner.** That
is the only path to parity with what the user sees in their app.

**One genuine win, though:** `GET /index/asset/{assetID}/price-history` —
unauthenticated, and far better than the on-chain ledger it replaced. It returns
the CARD's full sale record split BY GRADE with population:
`{assetId, priceHistory:[{title, grader, grade, population, sales:[{date, price}]}]}`
(e.g. the XY17 Charizard: PSA 9 → 65 sales, pop 438; PSA 10 → 31 sales). Because
it describes the card rather than the slab, ANY vaulted asset of that card answers
for all of them. Comps now come from here, gated behind the same identification
bar as the price. The `/transactions` ledger approach is retired: ~20% coverage
and one sale per slab.

### 2a. Courtyard auth is Privy, and the scanner call is CERT-KEYED — 2026-08-29 (night)

Opened to test the owner's theory that connecting an account unlocks the
scanner. Half of it is confirmed, and it is the buildable half.

**The auth mechanism — SOLVED, and there is no password by design.** Courtyard
authenticates with Privy. Their bundle drives two plain client endpoints:
`POST auth.privy.io/api/v1/passwordless/{init,authenticate}` — email, then the
emailed code. Both take only the PUBLIC `privy-app-id` header; Privy's
app-secret Basic Auth belongs to their *server* REST API, a different surface.
So a server can drive the login for the user: init -> user reads their own inbox
-> authenticate. That is the OTP relay, and it is what replaces Card Ladder's
"store email+password" pattern, which cannot port because no password exists.

Captured live (public client identifiers, observed off the login modal's request
headers — they are in no static chunk on any server-rendered route):
* `privy-app-id: cldj2z0b70001mm08l39me9k5`
* `privy-client-id: client-WY2UXndhQ4SHyZxA4a9fAyZtFTD8SFca7MVefZ9EyVom4`

Verified accepted: `init` with that app id validates past app-id straight to
email validation (`[Input error] email: Invalid email address`),
where a bad app id returns `missing_or_invalid_privy_app_id`. See
`courtyard/privy-auth.ts` (`CY_CAPTURE_ONLY=1` re-captures without sending mail).

**The token is the API bearer.** courtyard.io sets `OpenAPI.TOKEN =
getAccessToken` directly from `usePrivyClient()`, so the Privy access token is
what `api.courtyard.io` authenticates. There is no second Courtyard-issued
credential to obtain. `/users/login` exists but the web client never calls it.

**The web API still has no scanner route — re-verified.** The generated client
in their bundle is **exactly 172 endpoints** (unchanged). Every pricing endpoint
is per-vaulted-asset or owner-scoped. `/pricing/instant-sell-offers` was the last
plausible candidate — the app says "Courtyard isn't buying this card" — and it
takes **assetIds**, with `403 "caller is not the asset owner"`. Not the scanner.

**NEW, and it changes the odds on the APK: the app is Expo, and the scanner call
is keyed by CERT.** The web bundle ships the whole scanner feature's strings and
react-query keys even though `courtyard.io/scanner` 404s (mobile-only route):
`GET_SCANNER_CARD_DETAILS`, `GET_SCANNER_CARD_GRADER_IMAGE`, "Courtyard Pricing
/ Market Value", confidence high/medium/low, and decisively
**"Failed to fetch scanner data for cert: {{cert}}"** — a cert-keyed lookup,
exactly the shape the web API lacks. `EXPO_PUBLIC_SCANDIT_LICENSE_KEY` means the
mobile app is **Expo/React Native sharing this codebase**, so its bundle is plain
JS in `assets/index.android.bundle`. The teardown is a grep for that call site,
not a reverse-engineering project.

**CORRECTION to a reading made earlier the same day.** `/index/*` returned 403 to
every local request, which first looked like a route-level auth change. It is
not: from a different egress `/index/asset/{id}/price-history` returns valid JSON
unauthenticated, while `/orderbook/config` and `/configs/providers/config.json`
answer 200 from here. **This machine's IP is rate-limited on the `/index/*`
prefix** after the day's probing. Production is unaffected and the §2 findings
above stand. A 403 on `/index/*` from a hammered IP is INCONCLUSIVE — never
record it as a closed route; `courtyard/probe-auth.ts` flags it in the output.

**RUN 2026-08-29 (night) — the OTP relay WORKS end to end on a real account.**
`courtyard/privy-auth.ts` against the owner's own Courtyard login:
`passwordless/init` -> `{"success":true}` (code emailed) -> `authenticate` with
the emailed code -> **HTTP 200**. Response carries `user`, `token` (ES256 JWT,
413 chars), `privy_access_token`, **`refresh_token`**, `session_update_action`,
`is_new_user`. So the relay does not need re-OTPing on every call — the refresh
token is there, which is what makes a server-side `courtyard-connect` viable.
The script runs two-step (`CY_CODE=… npx tsx courtyard/privy-auth.ts`) because
the code arrives out of band; on a TTY it just prompts.
**The session file `.state/courtyard-session.json` holds a LIVE credential.**
`.state/` is gitignored — keep it that way, same rule as `spike/.env`.

**Whether the Privy bearer authenticates api.courtyard.io is STILL OPEN**, and
not for an interesting reason: this machine's IP is 403-blocked on `/users/*`
as well as `/index/*`. Evidence it is the IP and not the route: the same
`/users/ids/{id}` URL answers **400 Bad Request** from a clean egress, while
from here it is a bare-HTML 403 both anonymously AND with the bearer — an auth
rejection would be JSON. `/orderbook/config` and `/configs/providers/config.json`
still answer 200 from here, which is what makes the block look route-shaped at
first glance. It is not.

**Browser transport does NOT route around it, and that is worth knowing before
someone tries.** In-page `fetch` from a courtyard.io page dies on CORS (a 403
carries no ACAO header, so it surfaces as "Failed to fetch"). Top-level
navigation with `extraHTTPHeaders` gets 403 even on `/orderbook/config`, which
plain curl fetches at 200 — the WAF rejects navigations to the API outright. So
the documented "use the browser transport" workaround is for Cloudflare TLS
fingerprinting, NOT for this block. The only fix is a different egress.

**Verdict:** the account mechanism is real and buildable, but authentication most
likely gates *access*, not *capability*. `courtyard/probe-auth.ts` is the bounded
test (fixed guess list, hard cap 20, ~1 req/sec); it needs `CY_EMAIL` in
`spike/.env` and a session from `privy-auth.ts`. If it finds no cert-keyed route,
the theory is retired and the next step is the APK teardown — not a wider probe.

### 2b. THE SCANNER ENDPOINT IS FOUND — `/scanner/card-details` — 2026-08-31

**`GET https://api.courtyard.io/scanner/card-details?cert={cert}&grader={PSA|CGC}`**
**No auth. No browser. No account.** Anonymous and bearer-authenticated responses
are byte-identical. `grader` is optional (the cert alone resolves).

Found by tearing down the Android app (`io.courtyard.app` 1.7.00 build 90, XAPK
from a mirror). Two things made it findable: the app is Expo/React Native, and
its `assets/index.android.bundle` is **Hermes bytecode, not plain JS** — `grep`
finds nothing, `strings` finds everything. The URL is in the Hermes string table.
Sibling endpoint: `GET /scanner/card-grader-image` (not yet used).

**The live bar is MET, exactly.** Cert 96679812 -> `price: 50.8`,
`priceConfidence: "2"` — the same $50.80 / confidence 2 Courtyard's own app shows
for that slab, the number this whole spike existed to reach.

**Response shape** (one call answers price, identity AND comps):
```
{ "priceModel":  { "price": 50.8, "priceConfidence": "2",
                   "gemrateDescription": "..." },
  "graderData":  { "id": "PSA_96679812", "grader", "cert", "title", "subject",
                   "cardNumber", "set", "language", "category", "year",
                   "grade": "g10", "population": 38, "primaryImages": [] },
  "priceHistory":[ { "title", "grader", "grade", "population",
                     "sales": [ { "date", "price" } ] } ],   // split BY GRADE
  "acquisition": { "accepted": true } }                      // "Courtyard isn't
                                                             //  buying this card"
```

**Error semantics are clean, and map onto our honesty rules:**
* `404 {"message":"card details not found"}` — authoritative not_found. Em dash.
* `502 {"message":"invalid response from gemrate"}` — TRANSIENT upstream failure.
  Must NOT blank a price the user already saw (`PriceWriteback`'s rule).
* The upstream is **GemRate** (pop-report aggregator) — hence `population` and
  the grade-split history.

**Verified across cards and graders** (2026-08-31):
| cert | grader | result |
|---|---|---|
| 96679812 | PSA | $50.80 conf 2, 5 comp groups — the bar card |
| 4260611176 | CGC | $111 conf 5, 9 comp groups |
| 41066652 | PSA | $247 conf 4, 29 comp groups |
| 133653550 | PSA | 404 not found |

**This overturns §2's conclusions, and more besides:**
1. **It is a catalog-backed pricing MODEL, not vault inventory.** Cert 41066652
   was `burn`ed out of the vault and unfindable in Algolia by evening on 08-29 —
   this endpoint prices it fine. The "cards age out" problem is gone.
2. **CGC is answered.** §5 has CGC as "no public API, Turnstile-walled, source
   undecided". This returns CGC identity, price and comps from the same call.
3. **Cert-keyed identity, exact by construction.** No fuzzy matching, so the
   whole `identify()` guessing problem disappears for this source — the cert IS
   the key. The `identify()` bar still governs the ALGOLIA adapter.
4. **Comps come free** — grade-split with population, in the same response, so
   no second call and no `/index/asset/{id}/price-history` round trip.

**CONFIRMED AGAINST THE APP ON DEVICE — 2026-08-31.** The owner scanned two
slabs in Courtyard's own app and read the values off the screen; both match this
endpoint exactly:

| cert | app shows | endpoint returns |
|---|---|---|
| 96679812 (PSA 10 Curry) | $50.80, medium confidence | `price: 50.8`, `priceConfidence: "2"` |
| 154334127 (PSA 9 Hamilton Sapphire) | "not applicable", low confidence, last sold May 16 2026 $145 as a PSA 10 | `price: 0`, `priceConfidence: "0"`, priceHistory grade 10 sale `2026-05-17T00:00:00Z` `$145.00` |

Three rules fall out of the second card, and each is a bug waiting to happen:
1. **`price: 0` + `priceConfidence: "0"` means NOT APPLICABLE, not $0.** The app
   renders it as "not applicable". Map it to the em-dash no-price state — this is
   the exact case the "never `$0`" rule exists for.
2. **Confidence is 0-5 and the app BUCKETS it** to low/medium/high
   (`scanner.confidence.{low,medium,high}`): observed 0 -> low, 2 -> medium. It is
   not displayed as a raw number.
3. **Sale dates are UTC midnight** (`...T00:00:00Z`) and the app renders them in
   LOCAL time, so a naive UTC render shows a date one day later than Courtyard's
   own app. Card 2's "May 16" is `2026-05-17T00:00:00Z`.

And one found while reconciling: **`priceHistory` groups are per (grader, grade),
not per grade** — cert 96679812 returns TWO grade-10 groups, PSA (pop 23) and SGC
(pop 3). Every group repeats the SCANNED card's `title`, so the SGC group is
labelled "(PSA g10)". Key comps off `group.grader` + `group.grade`; trusting
`title` mislabels other graders' sales as PSA. Note also that comps may be for a
DIFFERENT grade than the scanned slab (card 2 is a g9 whose only comps are g10),
which the app handles by labelling the grade — so must we.

**Access-model note for whoever writes the adapter:** `/scanner/*` is NOT subject
to the block that hits `/index/*` and `/users/*` from consumer networks (see §2a)
— it answered plain curl from a mobile hotspot throughout. It is also not
Cloudflare-fingerprinted: no browser transport needed.

**The account theory is retired, with evidence.** Connecting a Courtyard account
is NOT required for pricing — the endpoint is public. The Privy OTP relay in
§2a still works and is still the right design *if* a future feature needs a user
session, but nothing in the price path needs it. Do not build
`courtyard-connect` for pricing.

## 3. Physical slab scanning (needs iPhone + real PSA and CGC slabs)

Xcode → New iOS App **ScanHarness** (SwiftUI, iOS 17) → replace generated files
with `scan-harness/ScanHarness/*.swift` → add `NSCameraUsageDescription` to the
target's Info → run on device.

Test: modern PSA label (QR), older PSA label (barcode), CGC label (QR) — each in
good light, bad light, and through case glare. Record the screen.

**Verdict (run 2026-08-21):**
- [x] PSA reads + parses? **YES — scanned real PSA slabs on device, cert numbers
      returned correctly via CertParser.**
- [ ] CGC reads + parses? **PENDING — same VisionKit pipeline; needs a real CGC
      slab to confirm the QR host + cert extraction. Non-blocking for M1.**
- [ ] Glare/low-light behavior acceptable? (note during more scanning)
- **GO / NO-GO:** **GO for PSA (confirmed). CGC to confirm opportunistically.**

### Scanner rebuilt on AVFoundation + Vision (2026-08-28)

The VisionKit harness above proved the *reads*; it did not survive contact with
volume scanning. `DataScannerViewController` vends pixels exactly one way,
`capturePhoto()`, which reconfigures the running capture session — the preview
froze ~0.5–1.5s per slab, and because that call was awaited before the next cert
was admitted, it was also the only thing blocking the following slab. One cause,
both complaints. There is no cheaper frame API on that class (no sample buffers,
no exposed session), so the scanner now owns an `AVCaptureSession` and runs
`VNDetectBarcodesRequest` on the video frames itself — the frame the barcode was
found in is the photo. Nothing was lost: the app had already disabled every
DataScanner affordance (guidance, highlighting, pinch-zoom).

The harness is now instrumented for the questions a desk cannot answer — fps and
detections/sec, each capture shown at both 46×64 and full width with its byte
count, a suppression-window slider, and the guide rectangle drawn where Vision is
actually looking. It builds the app's scanner **from source** rather than copying
it: the old harness kept its own fork of `CertParser` that had drifted from the
app's (different host matching, different cert extraction), which quietly made
every verdict it produced a verdict about the harness.

**Still to confirm on device:** Code128 reads on curved/glare-lit labels at
natural distance, real slab-to-slab cadence, whether 2.5s is the right
suppression window, whether the guide-rect crop frames the card or the label,
thermals across a few hundred slabs, and PSA + CGC in the same stack.

## 4. Price metric confirmation (buyer #1 conversation, not code)

Ask the friend: when you decide where to sell, which Card Ladder number do you
actually use, and which Courtyard number? (avg / last sale / current floor / other)

- Card Ladder metric: ~~average sale~~ → **Card Ladder Value** (`estimatedValue`),
  with **Last Sold** (`lastSalePrice`) beside it. **OVERTURNED 2026-08-29 — see §1a.**
  The 2026-08-21 answer was right about intent and wrong about the field; the
  average window is empty often enough that those cards showed no price at all.
- Courtyard metric: **FMV estimate + confidence** — `estimatedValueUsd` /
  `estimatedValueConfidence`, which is what Courtyard's own scanner shows
  (confirmed 2026-08-29, §2). Real per-slab sale prices come from the ledger,
  but only ~20% of vaulted slabs have ever sold.

## 4a. PSA cert scrape is DEAD — wall tightened (2026-08-28)

**Both PSA paths are now closed. This is a regression on their side, not ours.**

- [x] Official API? **STILL NO.** `GET /publicapi/cert/GetByCertNumber/{n}` with the
      stored token returns `403 {"Message":"Access to this API is limited to
      approved customers."}`. Unchanged since 2026-08-21 — the account was never
      approved.
- [x] Cert-page scrape? **NO — newly blocked.** `https://www.psacard.com/cert/{n}`
      now returns **403 with a Cloudflare interstitial** (`<h1>www.psacard.com`,
      ~27 KB, zero `<dt>` elements) instead of the cert. Confirmed twice:
      local headless Chromium, AND the deployed Worker using Cloudflare's own
      Browser Rendering binding, which logged for two separate real certs:
      `PSA navigation rejected { certNumber: '96679812', status: 403 }`
      `PSA navigation rejected { certNumber: '154334127', status: 403 }`

**This overturns §5's parenthetical** ("unlike PSA's, which did [auto-clear]"),
which was true on 2026-08-22. PSA's wall no longer auto-clears for a headless
context — it now behaves like CGC's.

Effect on the app: `psa-cert` returns `source_error` for every PSA cert, so PSA
contributes no name, no title and no picture. It went unnoticed because the
client swallowed the failure (`catch -> .unavailable`, then a bare `break`),
leaving rows spinning on "Identifying" forever. `LookupStatus.unavailable` now
surfaces it — "couldn't be reached" and "no such cert" are different facts, the
same rule prices already follow.

**Options (decision pending):** (1) pursue PSA API approval — the only durable
fix, and the account already has a token waiting; (2) a stealthier transport,
i.e. an arms race we have already declined for CGC; (3) lean on the chain —
Card Ladder resolves PSA certs exactly (see below) and covers CGC too.

## 4b. Card imagery — where a picture actually comes from (added 2026-08-28)

Asked because scanned rows had an empty picture window. The assumption was that
PSA's cert page shows the card; it does not.

- [x] PSA cert page? **NO — not for most certs.** The saved real cert page
      (`worker/test/fixtures/psa-cert-page.html`, cert 49385027) contains no image
      of the card at all: the only `i.psacard.com` URLs are site chrome, `og:image`
      is PSA's generic homepage card, and there is no `certimages`/SecureScan/CDN
      reference anywhere. PSA serves scans only for certs WITH SecureScan imagery,
      a minority. A test pins the absence. **PSA cannot be the image source.**
      Its `<h1>` does carry the assembled title, which the `<dt>/<dd>` list doesn't.
- [x] Card Ladder? **YES — and it is now the only working source for names.**
      `httpbuildcollectioncard` resolves a cert to `label`/`player`/`set`/`year`/
      `number`/`grade` plus a picture. Verified live against two real PSA certs
      2026-08-28: 96679812 -> "2022 Panini Donruss Optic Splash! #10 Stephen
      Curry Holo", 154334127 -> "2022 Topps Chrome Formula 1 Sapphire Edition #6
      Lewis Hamilton Green". Covers CGC, which nothing else does. Rides the
      existing price call — never fetch it separately, that burns the budget.
      **Gotcha: the image fields VARY by response, so go through `cardImage()`.**
      Collection-context payloads (the saved fixture) carry `image` = a Firebase
      `/o/cards%2F` render, while `imageUrl` there is a `/o/sales%2F` SALE COMP —
      a different slab's listing photo, which must never be shown as this card.
      Live cert lookups have **no `image` key at all** and put a CloudFront
      `/cert/<id>/...jpg` scan in `imageUrl` (~1 MB, public, no auth — downscale
      before storing).
- [x] Courtyard? **YES, partial coverage.** Algolia hits carry a cert-keyed render
      (`.../graded-cards-renders/PSA%2098881872/nft_image.jpg`) plus a ~90-byte
      `lqipBase64` preview. Only for cards vaulted on Courtyard.
- **Verdict:** the camera capture is the floor (always present), upgraded to an
  official render when one exists. Official images are used **only on an exact
  cert match** — a fuzzy Courtyard hit is a different card.

## 5. CGC cert lookup (added 2026-08-22)

- [x] Official CGC API? **NO — CGC has no public/partner developer API (confirmed).**
- [x] Public cert page scrapeable headless? **NO — www.cgccards.com is AngularJS
      behind Cloudflare Turnstile; the /certlookup/ path is interactive-challenge-
      walled and does NOT auto-clear (unlike PSA's, which did). Bare + browser-
      context both 403.**
- Cert lookup runs on EVERY scan (high volume, latency-sensitive), so a human-
  session cf_clearance bridge (like Card Ladder's) is a poor fit — the clearance
  cookie expires mid-session.
- **Options (decision pending):** (1) third-party CGC cert API (offload Cloudflare,
  pay per lookup, vendor dependency); (2) human-session cf_clearance bridge with
  auto re-auth prompts (fragile for per-scan); (3) manual/confirm entry fallback
  (D10 degraded mode — always works, less magical); (4) check the CGC slab QR
  payload — if it encodes card data, no lookup needed (FREE to check with a real
  slab).
- Adapter shell built (worker/src/sources/cgc.ts): implements CertLookup, reports
  the Turnstile wall as a distinct state, never fabricates data. parseCgcCertPage
  is the seam the chosen source fills.

