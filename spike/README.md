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

