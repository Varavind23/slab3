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
| 133653550 | PSA | 404 not found — **WRONG, see §2f**: prices at $125.40 once the request sends `cy-supports-acquisition-status: 1` |

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
**Superseded in one respect — see §2c: plain curl is now 403, and the reason is
the User-Agent.** Everything else in this section still holds.

### 2c. `/scanner/*` is now User-Agent-walled — 2026-09-03

**The endpoint is unchanged; getting to it is not.** Sometime after 2026-08-31 a
WAF appeared in front of `api.courtyard.io/scanner/*` that **blocks by
User-Agent**. This is what §2b's "it answered plain curl throughout" no longer
describes.

Measured from one machine, within one minute, same URL
(`/scanner/card-details?cert=96679812&grader=PSA`), varying ONLY the UA:

| User-Agent | result |
|---|---|
| `curl/8.7.1` | **403** |
| `python-requests/2.32.3` | **403** |
| `Go-http-client/2.0` | **403** |
| `node` | **403** |
| **empty / absent** | **403** |
| `Mozilla/5.0 …Chrome/126…` | 200 |
| `Deno/1.45.5` | 200 |
| `supabase-edge-runtime-1.69.12 (compatible; Deno/1.45.5)` | 200 |
| `undici` | 200 |
| `okhttp/4.9.2` | 200 |
| `Slabs/1.0 (graded-card inventory)` | 200 |

**It is a blocklist of obvious tool agents, not an allowlist of browsers** — a
plain custom string passes. So there is nothing to gain by impersonating a
browser or Courtyard's own app, and the adapter deliberately sends a truthful
`SCANNER_UA` instead (`supabase/functions/_shared/courtyard-scanner.ts`).

**How to tell this wall from the §2a one:** the 403 here is bare HTML with every
header stripped — no `server: Google Frontend`, no `via: 1.1 google`, which a 200
from this host does carry. It sits in FRONT of their stack, and it is not IP-based:
the 403 and a 200 were obtained from the same IP seconds apart. `npm run
courtyard:probe` gets a 200 on this endpoint because it happens to set a browser
UA — that is why the wall was invisible until the two were compared directly.

**Why it read as an intermittent app bug.** `fetchCardDetails` sent no User-Agent
at all, leaving it to whatever the runtime defaults to — and this module runs under
three runtimes on purpose. An absent UA is a 403, a 403 is `!res.ok`, and that
lands on `CyError("source_error")`, the SAME path a genuine GemRate 502 takes. The
app then keeps the last value and marks it stale, or shows an em dash on a card it
has never priced. Nothing anywhere says "blocked" — it looks exactly like
"Courtyard sometimes doesn't work for no reason".

**Verified after the fix** (2026-09-03), live, with the UA the code actually sends
— the same four certs §2b recorded, all unchanged:

| cert | grader | result |
|---|---|---|
| 96679812 | PSA | 200, `price: 50.8`, conf `"2"`, g10, pop 38, 5 groups — **the bar** |
| 154334127 | PSA | 200, `price: 0`, conf `"0"` ("not applicable"), g9, 1 group |
| 4260611176 | CGC | 200, `price: 111`, conf `"5"`, `g10pristine`, pop 380, 9 groups |
| 133653550 | PSA | 404 not found — **NOT authoritative, see §2f**: $125.40 with `cy-supports-acquisition-status: 1` |

**Standing rule:** before recording any Courtyard 403 as a finding, check the UA
you sent. A 403 on `/scanner/*` from a tool agent says nothing about access; a 403
on `/index/*` or `/users/*` is the separate IP block of §2a and is likewise
inconclusive from this machine.

### 2d. A wrong GRADER is a 400, and 400 was being retried forever — 2026-09-05

**This is the cause of "some cards never show a Courtyard value, and refreshing
does nothing", reported while Card Ladder priced the same slabs fine.**

The grader is a GUESS. Nothing in a slab barcode identifies the grader —
`CertParser` infers it from digit count (10 -> CGC, 7-9 -> PSA). Send GemRate a
cert with the wrong grader and it does NOT say "not found"; it says:

```
400 {"message":"unable to query gemrate for cert: rpc error:
     code = InvalidArgument desc = gemrate cert lookup ..."}
```

Verified live 2026-09-05, same minute, same UA:

| request | result |
|---|---|
| `cert=96679812&grader=PSA` | 200 — $50.80, conf 2 |
| `cert=96679812&grader=CGC` | **400** |
| `cert=96679812` (grader omitted) | 200 — $50.80 |
| `cert=4260611176&grader=CGC` | 200 — $111, conf 5 |
| `cert=4260611176&grader=PSA` | **400** |
| `cert=4260611176` (grader omitted) | **400** |
| `cert=0096679812&grader=PSA` (zero-padded) | **400** |
| `cert=133653550&grader=PSA` (assumed unknown) | 404 — **only without the §2f header**; it is a known, priceable cert |
| `grader=psa` (lowercase) | 200 — case does not matter |

**Why it was permanent and silent.** `fetchCardDetails` mapped everything that was
not 404 to `source_error`, which `courtyard-price` treats as TRANSIENT: never
cached, serve the last value if any. So every refresh re-sent the identical doomed
request, got the identical 400, and wrote nothing. The card showed an em dash
forever. Card Ladder resolves the same slab through its own cert lookup, so it kept
working — which is exactly why the failure looked card-specific and random rather
than systemic.

**Note the two asymmetries**, both counter-intuitive and both load-bearing:
1. **Omitting the grader is NOT a universal fallback.** It resolves the PSA cert
   and 400s the CGC one. So the recovery flips the grader rather than dropping it.
2. **Leading zeros are rejected on their own** — and a zero-padded barcode read
   also changes the digit count, which flips the grader guess. Hence a
   zero-stripped attempt as well.

**The fix** (`_shared/courtyard-scanner.ts`): `attemptsFor()` produces the pairings
to try — the caller's guess first, then the other grader, then zero-stripped
variants when the cert has leading zeros — and `fetchCardDetails` walks them, but
ONLY past a 400. A 404 is authoritative about the cert and a 5xx is their upstream;
neither is improved by different parameters, and retrying them would multiply load
on an endpoint that 403s an IP which hammers it. The result is parsed against the
pairing that ANSWERED, so `sourceKey` and `identity.grader` describe the real slab.
If every pairing 400s, that is the new `unresolvable` kind — authoritative, cached
like a 404, so it stops being re-asked.

Verified live through the real client after the fix: cert 96679812 scanned as CGC
returns `PSA_96679812` $50.80 conf 2; cert 4260611176 scanned as PSA returns
`CGC_4260611176` $111 conf 5; `0096679812` scanned as CGC returns
`PSA_96679812` $50.80. A correct guess still costs exactly one request.

**Two guards the fallback cannot ship without** (added after an independent review,
2026-09-05):
1. **The response must be about the slab we asked for.** Retrying under a different
   grader means nothing proves the PSA and CGC cert namespaces are disjoint — a
   number valid for both would let the fallback price a DIFFERENT card, the exact
   failure `identify()` exists to prevent, reintroduced by the back door. Courtyard
   echoes `graderData.cert` and `graderData.grader`, so both are checked; only a
   PRESENT-and-disagreeing value is rejected, so a response-shape change cannot
   blank every card at once. Verified live: all three sample certs echo exactly.
2. **A 400 never overwrites a price we already hold.** 400 and 404 are not equally
   trustworthy — a 404 is the catalog speaking about the CARD, a 400 is GemRate
   refusing the QUERY, classified from a status code alone. If their upstream or the
   WAF ever answers 400 broadly, caching it as `not_found` would blank good prices
   for 24h. A slab with a stored `ok` row keeps serving it, marked stale, exactly
   like a 5xx; a 400 is cached only when there is no value to protect.

**Still open:** the app is never told the grader was wrong. `identityOf` in
`courtyard-price` does not return `grader`, so `Card.grader` keeps the bad guess —
and `grader` is a `card_key` segment, so the key stays wrong even though the price
is now right.

### 2e. Two certs their app prices that `/scanner/card-details` 404s — **SOLVED by §2f** — 2026-09-05

**STATUS: RESOLVED 2026-09-06 — the cause is a missing REQUEST HEADER, see §2f.**
Everything below is the hunt that led there; the conclusions it reaches about
*coverage* ("the data exists and we are asking for it wrongly") were right, and the
thing being asked wrongly was the header, not the URL, the grader or the account. The first version of
this section concluded "Courtyard has no data, the em dash is correct". The OWNER
then scanned both slabs in Courtyard's own app and **both displayed values**. So the
data exists and we are asking for it wrongly — the same shape as §2b, where the
answer was an endpoint the web API did not have.

Two production certs reported as "Card Ladder shows a value, Courtyard shows an em
dash" were replayed live. Both 404 with the CORRECT grader, from this egress, on
every parameter shape tried.

| cert | card | Courtyard `card-details` |
|---|---|---|
| 129123650 | 2025 Pokemon Destined Rivals #190 Ethan's Typhlosion, Illustration Rare, PSA 9 | **404** |
| 110578584 | 2023 Pokemon SWSH Crown Zenith #GG45 FA/Deoxys VMAX, PSA 10 | **404** |

Ruled out, each by live probe: the grader guess is right (both 9-digit -> PSA, and
PSA is what the slab says); omitting the grader still 404s; `SGC`/`BGS` 400; the
control cert 96679812 returned 200 in the same run, so no wall was active.

**It is NOT a Pokemon gap, and NOT a PSA gap.** Three PSA Pokemon certs from §1b
price fine:

| cert | card | result |
|---|---|---|
| 98881872 | 2021 Celebrations Classic Collection #4 Charizard-Holo | 200, $513.10 conf 5 |
| 77286827 | 1999 Pokemon Game #4 Charizard-Holo (PSA 6) | 200, $538.70 conf 5 |
| 51203633 | 2002 Expedition #40 Charizard-Reverse Foil | 200, $6255 conf 3 |
| 96679812 | 2022 Donruss Optic Curry (basketball-cards) | 200, $50.80 conf 2 |
| 154334127 | 2022 Topps Chrome F1 Sapphire Hamilton (misc) | 200, price 0 = n/a |

**RULED OUT so far** (all live, 2026-09-05, control cert 96679812 returned 200 in the
same runs so no wall was active):
* Grader guess — both are 9-digit -> PSA, and the slab labels confirm PSA.
* `grader` omitted, lowercase, trailing-space, `SGC`, `BGS`, `PSA_`-prefixed cert,
  zero-padded cert, `certNumber=`/`number=`/`gemrateId=` param names.
* POST to `/card-details` (405) and OPTIONS (405).
* **Route enumeration:** `/scanner/*` has exactly TWO routes. Express answers a
  missing route with `Cannot GET /scanner/x` and a missing RECORD with
  `{"message":"card details not found"}`, which separates the two cleanly. Probed and
  absent: `card`, `cards`, `lookup`, `scan`, `price`, `card-price`, `v2/card-details`,
  `card-market-value`, `card-sales`, `card-grader-data`, `/scanner` root,
  `/pricing/card-estimate`, `/pricing/estimate`.
* **Auth** — replayed with the stored Privy bearer from `.state/courtyard-session.json`:
  identical 404. **CAVEAT: that token was captured 2026-08-29 and is probably expired,
  so this rules out nothing.** A fresh session via the OTP relay is the real test.
* **Lazy backfill** — re-queried after the owner's app scan; still 404. Their scan does
  not populate the record we read.

**A warning that came out of this probing:** the CDN path in `card-grader-image`
exposes a second id (`/cert/188382772/` for cert 129123650). Querying THAT as a cert
returned **a valid 200 for a completely different card** (1979 O-Pee-Chee Willie).
Cert numbers are dense — a plausible 9-digit number is often somebody else's real
cert. Any lookup that retries with a mutated cert MUST verify the echoed
`graderData.cert`, which is why `attempt()` does.

**CONFIRMED BY SCREENSHOT — their app prices BOTH of these certs** (owner's device,
2026-09-05):

| cert | their app shows | confidence | our anonymous call |
|---|---|---|---|
| 129123650 | **$36.90** | 3 dots | 404 |
| 110578584 | **$172.30** | 3 dots | 404 |

The row thumbnails in that screenshot are the SAME `card-grader-image` photographs,
and the app also shows catalog identity (`Dri EN-Destined...`, `Sword and Shiel...`)
— fields that live in `card-details.graderData`, the call that 404s for us. So the
data exists, keyed by these certs, and we are being refused it.

**Also eliminated, live 2026-09-05** (control 96679812 returned 200 throughout):
* **Alternate hosts.** `scanner.`/`api2.`/`mobile.`/`api-mobile.courtyard.io` are all
  NXDOMAIN. `app.courtyard.io` resolves but fails TLS verification for this path.
* **Versioned/prefixed paths.** `/v1/`, `/v2/`, `/api/`, `/mobile/` prefixes and
  `/scanner/v1/`, `/scanner/card-details/full` all answer `Cannot GET` — route absent.
* **Client headers.** `x-platform: ios`, `x-app-version: 1.7.00`, `x-client: mobile`,
  `Origin: https://courtyard.io`, an Expo/CFNetwork UA, an okhttp UA, and all of them
  together: still 404.

**That leaves AUTHENTICATION as the only untested variable, and it is now the leading
hypothesis** — with a mechanism that makes commercial sense: a GemRate cert lookup
costs Courtyard money, so a signed-in app user triggers a live (paid) lookup while an
anonymous caller is served only from what Courtyard already holds. The certs that
answer us anonymously are ones already in that store; these two are not. Note this
would REVERSE §2b's "anonymous and bearer responses are byte-identical" — which was
only ever tested on a cert already in the store, where both paths hit the same cache.

**The one experiment that settles it, and it needs the owner's inbox:**
```sh
cd spike && CY_CAPTURE_ONLY=1 npm run courtyard:auth   # emails a code
CY_CODE=123456 npm run courtyard:auth                  # completes, writes .state
```
then replay cert 129123650 with the FRESH bearer. The stored session in
`.state/courtyard-session.json` was captured 2026-08-29 and Privy access tokens live
about an hour, so the earlier "authed 404" result proves nothing at all.

**If auth turns out to be the unlock, the product consequence is large**: pricing
would require every user to connect a Courtyard account, exactly the
`courtyard-connect` work §2b retired. The Privy OTP relay in §2a is the design for
it and still works.

**What the two misses have in common** (n=2, a lead only): both are MODERN
SPECIAL-SUBSET Pokemon — a Galarian Gallery card (`GG45`) and an
Illustration Rare numbered `#190` in a 182-card set. Both carry numbering outside the
base set, which is exactly what a catalog keyed on set+number would fail to match.
Everything that priced is conventionally numbered. Collect more failing certs before
treating this as the rule.

**`/scanner/card-grader-image` is a THIRD scanner endpoint, and it answers when
pricing does not.** For both 404 certs it returns 200 with real front AND back slab
photographs:

```
GET /scanner/card-grader-image?cert=129123650&grader=PSA
{ "cert","grader","status":"OK",
  "primaryImages":[ {imageSide:Front|Back, imageSize:Thumbnail|None, imageUrl} x4 ] }
```

Images only — no price, no identity beyond cert+grader — and the CDN path carries a
DIFFERENT internal id (`/cert/188382772/`) than the cert.

**Validated and SHIPPED 2026-09-05.** Measured before building, which is the only
reason it was worth building:

| | `card-grader-image` | Algolia (what it replaces) |
|---|---|---|
| certs answered | **9 of 9** (PSA + CGC, priced and unpriced, incl. one `card-details` 404s) | **1 of 4** exact-cert |
| cert 96679812 (prices fine) | front + back | **no image at all** |

The image gap was always far wider than the price gap — Algolia indexes the
MARKETPLACE, so it misses any card Courtyard has not vaulted, which is most of them.

**Behaviour that the implementation depends on, all measured:**
* **It verifies the cert.** A made-up cert returns `200` with `primaryImages: []` and
  `status: "ERROR"`; cert+1 returns a different card's images. So it clears the
  "official image only on an exact cert match" bar by construction — but **200 is NOT
  a hit**, the array length is the only thing that decides.
* **The full-size entries carry NO `imageSize` key.** Only thumbnails are labelled
  `"Thumbnail"`. Matching on the string `"None"` finds nothing and silently leaves
  every card thumbnail-only. There is a regression test for exactly this.
* **The URLs are free to serve**: no query string, no signature, no expiry, and they
  fetch anonymously with no User-Agent (CloudFront, not api.courtyard.io). So we store
  the URL and the phone fetches the bytes — ONE api.courtyard.io call per cert, ever,
  on an endpoint that 403s an IP which hammers it.
* Sizes: `/thumbnail/` ~21KB, `/small/` ~74KB (the one returned unlabelled and the one
  we show). `/large/` ~530KB resolves by path substitution but is NOT in the response,
  so we do not synthesise it; `/original/` 404s, which is the reminder why.
* The slab photo has the cert number printed on the label, so an exact-cert match here
  is verifiable by eye — rare, and worth using when checking this by hand.

`fetchGraderImages` **never throws**: a missing picture must never reach the
`source_error` path and blank a price.

**The account theory is retired, with evidence.** Connecting a Courtyard account
is NOT required for pricing — the endpoint is public. The Privy OTP relay in
§2a still works and is still the right design *if* a future feature needs a user
session, but nothing in the price path needs it. Do not build
`courtyard-connect` for pricing.

### 2f. THE 404s ARE OURS: `/scanner/*` needs `cy-supports-acquisition-status: 1` — 2026-09-06

**One request header decides whether a cert resolves at all.** Courtyard's app sends
it on every `/scanner/*` call; we never did. Without it a large class of certs
answers `404 {"message":"card details not found"}` — indistinguishable from a cert
their catalog genuinely does not know. With it, the same certs return a full priced
record. This is the cause of §2e and of every "Courtyard shows an em dash while Card
Ladder prices it fine" report.

```
GET /scanner/card-details?cert=60928769&grader=PSA
  (no header)                          -> 404 {"message":"card details not found"}
  cy-supports-acquisition-status: 1    -> 200 $144.40 confidence 5
```

**Measured 2026-09-06, live, same minute, varying ONLY that header:**

| cert | grader | without | with |
|---|---|---|---|
| 60478273 | PSA | 404 | **200 $183.90 conf 5** |
| 62320645 | PSA | 404 | **200 $16.90 conf 5** |
| 60928769 | PSA | 404 | **200 $144.40 conf 5** |
| 60928772 | PSA | 404 | **200 $180.90 conf 5** |
| 60928787 | PSA | 404 | **200 $70.50 conf 5** |
| 66581638 | PSA | 404 | **200 $155.40 conf 5** |
| 129123650 | PSA | 404 | **200 $38.40 conf 5** | (§2e cert 1 — their app showed $36.90)
| 110578584 | PSA | 404 | **200 $174.10 conf 5** | (§2e cert 2 — their app showed $172.30)
| 133653550 | PSA | 404 | **200 $125.40 conf 5** | (the cert §2b recorded as an authoritative 404)
| 96679812 | PSA | 200 $50.80 conf 2 | 200 $50.80 conf 2 |
| 154334127 | PSA | 200 price 0 (n/a) | 200 price 0 (n/a) |
| 4260611176 | CGC | 200 $111 conf 5 | 200 $111 conf 5 |

**It is a strict superset.** No cert that already answered changed price, confidence
or response shape — the `acquisition` block is present either way on 96679812. So the
header does not select a different document; it gates which certs the backend will
resolve at all. The consistent reading is that it opts into a newer resolution path
(the one that will do a live GemRate lookup for a cert not already in their store),
and clients that do not announce support are served only the pre-populated subset.

**Where it came from.** Torn out of the Android app, `io.courtyard.app` 1.7.10 (91),
Hermes bytecode as in §2b — but the string table alone is not enough this time, the
header is assembled in code. Disassembled with `hermes-dec`; the chain is:

```
ApiConfigProvider          -> OpenAPI.HEADERS = getCustomHeaders
getCustomHeaders(options)  -> { 'cy-client-id': statsigUser.customIDs.segmentAnonymousId ?? '' }
                              if (url.includes('/checkout')) Object.assign(h, getCheckoutTraceHeaders())
                              if (url.includes('/scanner/')) h['cy-supports-acquisition-status'] = '1'
ScannerService.getScannerCardDetails(cert, grader)
                           -> { method:'GET', url:'/scanner/card-details',
                                query:{cert,grader}, errors:{400,404,429,500} }
OpenAPI.BASE = ENV.apiUrl  -> production 'https://api.courtyard.io'   (identical to ours)
```

`cy-client-id` is the Statsig anonymous id and is **not** the gate — sending it alone
still 404s. Only `cy-supports-acquisition-status: 1` matters. Sending it is truthful:
we already read `acquisition.accepted` and surface it.

**Ruled out before the header was found** (all live 2026-09-05/06, control 96679812
answering 200 throughout, so no wall was active):
* **Authentication.** A FRESH Privy bearer (OTP relay, token minted ~60s earlier)
  returns the identical 404. This finally settles the question §2e left open and
  confirms the account theory's retirement for a different reason than it was retired.
* **The grader.** GemRate's own error names the supported set — `BCCG, BECKETT, BGS,
  BVG, CGC, CSG, PSA, SGC`. All eight tried on 60928769: PSA 404s, the other seven
  400. So the grader guess was right and there was no pairing left to walk.
* **User-Agent.** Seven agents (ours, okhttp, a Courtyard/CFNetwork string, desktop
  Chrome, iOS Safari, Deno) all 404. Absent UA still 403s, per §2c.
* **The URL.** `OpenAPI.BASE` in the production config is `https://api.courtyard.io`,
  byte-identical to ours. `api.dev.courtyard.io/forwarder` exists only in the dev
  config; the production host has no `/forwarder` route (404 on GET and POST).
* **Extra query params** (`refresh`, `force`, `live`, `manual`, `source`) — no effect.
* **Lazy backfill.** Re-probed 10 and 40 minutes after the owner scanned all six in
  Courtyard's own app: still 404 without the header. Their scan does not seed what we
  read, which is why the §2e "re-queried after the owner's app scan" test misled.
* **A dropped digit.** Restoring a leading `1` resolves two of the six, but to 2025
  football cards, not the Pokemon the slabs actually are. Cert space is dense (§2e).

**Consequences to carry into the code:**
1. **Send the header on BOTH `/scanner/*` calls** in
   `supabase/functions/_shared/courtyard-scanner.ts` — `attempt()` and
   `fetchGraderImages()` — beside `SCANNER_UA`. Treat it as load-bearing exactly like
   the UA: absent, it silently halves coverage.
2. **`133653550` IS NOT A NOT_FOUND CERT.** It is used as the authoritative-404 case
   in §2b's table and in `supabase/functions/README.md`'s smoke test. It prices at
   $125.40 with the header. A new fixture cert is needed for the 404 path, and it
   must be verified WITH the header.
3. **The 400/`unresolvable` machinery of §2d stays.** A wrong grader is still a 400
   and `attemptsFor()` still earns its place — the header changes the 404 class only.
4. **Cached `not_found` rows are now wrong.** `cy_scan_cache` held 15 of them at the
   time of this finding; they must be purged, not waited out, or they serve an em dash
   for their full 24h TTL.
5. **This does NOT explain the missing slab photographs.** `card-grader-image` returns
   `200 {"primaryImages": null, "status": "NO_IMAGE"}` with or without the header, on
   certs that price perfectly. That gap is genuinely upstream — see the §2e note that
   "200 with an EMPTY array" is really `null` plus `NO_IMAGE` for these.

**Standing rule, alongside §2c's:** before recording ANY Courtyard `/scanner/*` result
— a 404 especially — check that the request carried both `SCANNER_UA` and
`cy-supports-acquisition-status: 1`. A 404 without the header says nothing about
whether Courtyard knows the cert.

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

