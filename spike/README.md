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
- [ ] Listing/floor price readable per card+grade? **PARTIAL — sales feed confirmed;
      card-identity → assetID mapping + listing/search endpoint still to trace
      (browse a specific card page and watch `[api]` lines).**
- **GO / NO-GO:** **GO — adapter can likely be plain HTTP, no Playwright.**

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

## 4. Price metric confirmation (buyer #1 conversation, not code)

Ask the friend: when you decide where to sell, which Card Ladder number do you
actually use, and which Courtyard number? (avg / last sale / current floor / other)

- Card Ladder metric: **average sale** (confirmed 2026-08-21)
- Courtyard metric: **recent sale** — from `api.courtyard.io/index/transactions?tx_type=sale` (confirmed 2026-08-21)

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

