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

**Verdict:**
- [ ] Login scripted OK? _____
- [ ] 2FA type (none / email / sms / totp): _____
- [ ] Cookie session survives rerun? _____
- [ ] Internal JSON API observed? (paste `[api]` URLs): _____
- [ ] Price readable + WHICH metric is it (avg / last sale / index)? _____
- [ ] Bot challenge encountered? _____
- **GO / NO-GO:** _____

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

**Verdict:**
- [ ] PSA QR reads + parses? _____   raw payload: _____
- [ ] PSA older barcode reads + parses? _____   raw payload: _____
- [ ] CGC QR reads + parses? _____   raw payload: _____
- [ ] Glare/low-light behavior acceptable? _____
- **GO / NO-GO:** _____

## 4. Price metric confirmation (buyer #1 conversation, not code)

Ask the friend: when you decide where to sell, which Card Ladder number do you
actually use, and which Courtyard number? (avg / last sale / current floor / other)

- Card Ladder metric: **average sale** (confirmed 2026-08-21)
- Courtyard metric: **recent sale** — from `api.courtyard.io/index/transactions?tx_type=sale` (confirmed 2026-08-21)
