# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Slabs** (project id `slab3`) — an iOS app for people who buy and resell *graded*
trading cards in volume: scan a stack of PSA/CGC slabs, get prices from multiple
markets (Courtyard, Card Ladder), organize into folders, export CSV. Inventory
software, not a collector app.

Four independent pieces, no shared build system:

| Dir | What | Stack |
|---|---|---|
| `ios/` | The app | SwiftUI + SwiftData + supabase-swift, iOS 17, XcodeGen |
| `worker/` | Price/cert adapters **and** the deployed cert-scrape Worker | TypeScript, vitest, Playwright, Cloudflare |
| `supabase/` | Schema + RLS + pgTAP tests, **and** the Edge Functions | Postgres + Deno |
| `spike/` | M0 probes + the on-device scan harness | tsx + Playwright; `scan-harness/` is an XcodeGen app that **builds the app's scanner from source** |
| `design/caliper/` | The design source of truth: handoff doc + HTML/React reference | Docs only |

## Commands

```sh
# worker
cd worker && npm test              # vitest run (all adapter tests, fixture-driven)
npx vitest run test/psa.test.ts    # single file
npx vitest run -t "average sale"   # single test by name
npm run check                      # tsc --noEmit -p tsconfig.cloudflare.json (deployed subset only)
npm run deploy                     # wrangler deploy the slab3-psa-cert Worker

# ios — project.pbxproj is GENERATED; sources are whole-directory globs, so a NEW
# .swift file needs only a regenerate (edit ios/project.yml only for settings/deps):
cd ios && xcodegen generate
xcodebuild -project ios/Slab3.xcodeproj -scheme Slab3 \
  -destination 'platform=iOS Simulator,name=iPhone 17' test   # pick a simulator you actually have
# single test: add -only-testing:Slab3Tests/CardKeyTests/matchesSqlNormalization
# ios/Tests uses Swift Testing (@Test/#expect), NOT XCTest — match it.
# suites: CardKey, CertParser, CourtyardClient, CSVExport, PriceWriteback,
#         IdentityChain, ImageDownscale, RecentCertWindow, RecentSales

# supabase
supabase db reset      # apply migrations locally
supabase test db       # pgTAP (supabase/tests/schema_test.sql)
supabase functions serve                       # all Edge Functions locally (needs Docker)
supabase functions deploy cardladder-price     # deploy one
# NOTE: cardladder-sales is a separate function — deploy it too.
# Edge Function logic is covered offline by the worker/ vitest suite, not by a Deno suite.
# Setup + curl smoke tests live in supabase/functions/README.md.

# spike (rarely — verdicts are already recorded in spike/README.md)
cd spike && npm install && npx playwright install chromium
npm run courtyard -- "charizard base set psa 9"
```

## Architecture

### card_key is the spine
`{grader}:{set}:{card_id}:{grade}`, lowercased, every run of non-alphanumerics
collapsed to `-`, **no** leading/trailing trim. It is implemented **three times**
and all three must stay byte-identical: `make_card_key()` in
`supabase/migrations/*.sql`, `CardKey.make` in `ios/Slab3/Shared/CardKey.swift`,
and the `cardKey` field in `worker/src/sources/types.ts`. The SQL and Swift tests
share the same vectors on purpose. It drives both price matching and the
sale-limit rule (max 3 identical card_key per folder; the 4th requires an explicit
`over_limit_ack`). Change one, change all three and both test suites.

### The bot-wall problem shapes the whole worker
Every price/cert source is behind some bot protection, and the findings differ per
source. `spike/README.md` is the authoritative record of what works — **read it
before touching any adapter**; don't re-litigate an access path it already ruled out.

- **Courtyard: solved, browserless.** Search is Algolia on `algolia.net` with a
  public search-only key — queried directly, no Playwright. This is the one live
  price source. Implemented twice, deliberately mirrored:
  `worker/src/sources/courtyard-algolia.ts` and `ios/Slab3/Pricing/CourtyardClient.swift`.
  Keep them in agreement. `courtyard.ts` is a *second, still-live* Courtyard
  adapter, not dead code: it hits `api.courtyard.io` (Cloudflare-fingerprinted, so
  browser transport) for per-asset detail — ask/bid/FMV — and its `lookup()`
  degrades to `not_found` until card_key→assetID resolution (D10) lands.
  Algolia = search/price; `courtyard.ts` = asset detail. Courtyard's displayed
  number is `estimatedValueUsd` + `estimatedValueConfidence` (1–5, sent as a
  STRING) — the same FMV its own scanner shows; the confidence is quoted only on
  an exact cert match. `courtyard-sales.ts` gets real sale prices from
  `/index/asset/{assetID}/transactions` (plain fetch, no browser; USDC 6-dec),
  resolving the asset via `proofOfIntegrity` on a `marketplace_prod_recently_sold`
  hit — which IS the assetID. Cert is **not facetable** in Algolia, so cert
  matching stays client-side. Only ~20% of vaulted slabs have ever sold, so an
  empty Courtyard comps list is normal, not an error.
- **Card Ladder: live (server-side, bring-your-own-account).** The web SPA and
  `search.cardladder.com` are Turnstile-walled, but the real data plane is Firebase
  Cloud Functions on Google hosts (not behind Cloudflare) that take a plain Bearer
  ID token. Verified flow: `signInWithPassword` → `httpbuildcollectioncard`
  (cert→profileId+grade) → `httpcardestimate` (→ **`estimatedValue` = Card Ladder
  Value**, the number CL's own app labels "Value", plus `lastSalePrice` = "Last
  Sold" and a 1–5 `confidence`). Comps come from **`httpprofilesales {cert,
  grader}`** — real sales, already filtered to the same card AND grade
  server-side. **Gotchas:** `httpcardestimate.condition` must be the grade CODE
  (`g9`), not `"PSA 9"`; and `httpbuildcollectioncard`'s `currentValue`/
  `marketValue` are **collection-context only** (null for cards the user doesn't
  own), so the headline must come from the estimate. The metric was
  `oneMonthData.averagePrice` until 2026-08-29 — that window is empty often
  enough that those cards showed NO price; see `spike/README.md` §1a. Canonical client lives in
  `supabase/functions/_shared/cardladder.ts` (cross-runtime: the Supabase Edge
  Functions run it in Deno, `worker/` vitest-tests it in Node);
  `worker/src/sources/cardladder.ts` only adapts that shared module to the
  `PriceSource` contract and re-exports it, so vitest exercises the exact code
  Deno ships — logic changes go in `_shared/`, never in the adapter. Each user connects
  their OWN paid CL account (`cardladder-connect`); prices are fetched server-side
  (`cardladder-price`, cache-first, per-user daily budget) and shown only to
  connected users. Comps go through a SEPARATE `cardladder-sales`, fetched
  **lazily when a card's detail screen opens** — never on a scan or bulk refresh,
  or a 200-slab stack spends its 200/day budget on comps nobody opened.
  `search.cardladder.com` is never used, but note the SPA bundle is served
  un-walled from `cardladder-71d53.web.app` — that is how the callable list and
  field labels were recovered.
- **PSA: both paths are CLOSED as of 2026-08-28 — see `spike/README.md` §4a.** The
  official API is still unapproved (403), and the cert page now returns 403 with a
  Cloudflare interstitial even to Cloudflare's own Browser Rendering, so the scrape
  yields nothing. The code below is correct and ready for the moment either
  reopens; until then PSA contributes no identity and the chain falls back to Card
  Ladder. Do not "fix" the parser — it is not what is broken.
  Both emit the same `CertData`, so the pipeline is source-agnostic; swap back when
  approved. In production the scrape runs in the deployed Cloudflare Worker
  (`worker/src/index.ts`, `slab3-psa-cert`): one route, `POST /lookup`, guarded by a
  constant-time `PSA_SCRAPER_TOKEN` bearer check, using the `BROWSER` Rendering
  binding. It reuses the same exported parsers as the vitest suite, so fixtures test
  the deployed code. The app never calls it directly — `psa-cert` does.
- **CGC:** no public API, Turnstile-walled, source undecided. `cgc.ts` is a shell
  that reports the wall as a distinct state.

**Never fabricate a price or cert value to make a code path return something.**
Adapters return a typed `SourceError` / `not_found` instead; the UI has a no-price
state for exactly this.

### Three runtimes, one set of adapters
The same TypeScript runs in three places and the split is deliberate:
`worker/` under **Node** for vitest (fixtures, offline), `worker/src/index.ts` on
**Cloudflare** (real browser via the `BROWSER` binding), and
`supabase/functions/` on **Deno** (`cardladder-connect`, `cardladder-price`,
`psa-cert`). `supabase/functions/_shared/cardladder.ts` is written cross-runtime on
purpose so Node can test what Deno ships — keep it dependency-free and Web-API-only.
Nothing in `_shared/` is a function: the leading underscore is what excludes it.

`_shared/` holds four files under **two different runtime contracts**, don't mix them:
`cardladder.ts` and `crypto.ts` (AES-256-GCM under `CL_ENC_KEY`, Web Crypto only) are
cross-runtime and vitest-tested from Node; `session.ts` (CL credential lifecycle —
refresh-token first, full sign-in as fallback) and `http.ts` (JSON replies, caller
identity from the JWT, service-role client for the deny-all tables) are **Deno-only** —
`http.ts` reads `Deno.env` at module load and imports supabase-js from esm.sh, so
importing it from `worker/` breaks the Node test run.

`worker/` carries two tsconfigs on purpose: `tsconfig.json` (Node + vitest globals,
covers all of `src` and `test`) and `tsconfig.cloudflare.json`, whose `include` is a
hand-listed subset — only the files that actually ship in the Worker bundle. `npm run
check` runs the second one, so **a new file reachable from `src/index.ts` must be
added to that include list** or it is silently never type-checked against the Workers
types.

The iOS client never holds a server secret. It calls Edge Functions with the user's
JWT; the functions hold `CL_ENC_KEY` (AES-GCM for stored CL credentials),
`PSA_SCRAPER_TOKEN`, and `PSA_SCRAPER_URL` as Supabase secrets.

### Transport seam
`JsonTransport` / `HtmlTransport` (`worker/src/sources/{transport,html-transport}.ts`)
exist because Cloudflare fingerprints the TLS stack — bare `fetch()` gets 403 where
the same request from inside a Playwright page gets 200. Production injects
`BrowserPool` transports (`worker/src/transports/browser.ts`, one long-lived warm
context); tests inject `FixtureTransport` / `FixtureHtmlTransport` backed by
`worker/test/fixtures/*`. Adapters never construct their own HTTP client — that's
what makes them testable offline. New source ⇒ implement `PriceSource` or the
`CertLookupResult` contract in `types.ts`/`psa.ts`, take a transport in the
constructor, add fixtures.

### Data / trust model
`supabase/migrations` splits tables in two:
- **User tables** (`cards`, `folders`, `folder_cards`) — RLS scoped to `auth.uid()`.
- **Worker tables** (`price_cache`, `card_identity_map`, `worker_jobs`,
  `scrape_budget`, `cardladder_credentials`, `psa_cert_cache`) — RLS enabled with
  **zero policies** = deny-all to clients; reachable only via service role.
  `price_cache` and the 30-day `psa_cert_cache` are global, not per-user; the
  budget is per-user.

The iOS app currently persists locally with SwiftData (`Card`, `Folder` `@Model`s
mirror the SQL columns, with `serverId` reserved for the sync link) and uses
Supabase for auth only. The anon key in `ios/Slab3/Backend/Backend.swift` is public
by design — RLS, not secrecy, is the protection. The service_role key never goes in
the client.

### iOS shape
`Slab3App` → `RootView` gates on `AuthManager.state` → `MainShell`. **Four tabs:
Scan, Cards, Export, Settings** — a hand-built `CaliperTabBar`, not a `TabView`,
because the selection bar rises *above* it without replacing it. App-level state
lives in `App/AppState.swift`; two pieces of it are load-bearing and global:
`activeSource` (which of CL/CY leads every row and drives the sort) and `filter`
(shared by Cards and Export — filtering on one carries to the other). Selection also
lives there, because the selection bar is above the tab bar and no screen owns it.
`payoutPercent` is deliberately `nil` until the user sets one — a default rate would
be a fabricated dollar figure, same rule as prices.

Scan flow: continuous burst — the camera **never freezes and never blocks**.
`CameraSession` owns an `AVCaptureSession` and runs Vision (`BarcodeDetector`) on
the video frames at 12 Hz, restricted to `ScanGeometry.guideRect`, so **the frame
the barcode was found in IS the photo** (`SlabFrameCapture` crops and encodes it
inline on the video queue). It replaced VisionKit's `DataScannerViewController`,
whose only pixel API — `capturePhoto()` — reconfigured the running session: the
preview froze ~1s AND that await was the sole thing blocking the next slab. There
is no cheaper frame API on that class, which is why we own the session. Two
non-negotiables carried over: `CameraPreview.updateUIView` is **empty on purpose**
(per-update device configuration was a second hitch source), and the pixel buffer
is **never retained past the delegate callback**. Then `CertParser` (grader
auto-detected by cert length: PSA=8, CGC=10) → `Card` → `PriceService.refresh`.

`RecentCertWindow` decides which sightings are worth reacting to — it never
prevents a duplicate *row* (`ScanScreen.add` refuses a cert it already stores,
unconditionally). Load-bearing because raw Vision has no item tracking, so a slab
in frame re-detects ~12×/s. Two rules: a repeat of the **last admitted cert is
blocked outright, whatever the gap** (that's the camera re-reading what's still in
your hand — and it's what makes glare-intermittent detection safe, where a pure
timer would fire a spurious duplicate); any *other* recently-seen cert is held by
a short ~1.5s trailing window (two slabs in frame taking turns). It replaced a
session-lifetime `Set`, which erred the other way — a rescan was swallowed forever
and never reached the "already in inventory" check.

Identity and images resolve through a **ranked chain**, not a single source
(`IdentitySource` + `Card.setIdentity`/`setImage`): PSA → Card Ladder → Courtyard,
with the camera capture as the image floor so a row is never picture-less. It has
to be stored rather than implied by call order, because all three writers are
independent async tasks. A lower source may FILL a gap a better one left, never
overwrite it. Two rules: **an official image is used only on an exact cert match**
(a fuzzy Courtyard hit is a different card — the image analogue of fabricating a
price), and **the long assembled title never goes in `name`**, which feeds
`refreshCardKey()`; it lives in `Card.title`. Only Card Ladder answers for CGC.
Per-source facts: PSA's cert page carries the assembled title in its `<h1>` (not
in the `<dt>/<dd>` list) and **no card photo at all** unless the cert has
SecureScan; Card Ladder's `resolveCert` returns `label`/`player` plus a public
card render and rides the existing price call — never fetch it separately, that
burns the daily budget; Courtyard's Algolia hits carry a cert-keyed render plus an
`lqipBase64` preview.

Comps (`RecentSale`) follow the same honesty rules as prices: stored per source,
`nil` = never fetched but `[]` = fetched and the source genuinely has none (the
detail screen says something different for each), a failed fetch keeps the last
list, and nothing is ever synthesized to fill the panel.

Prices: a refresh **never blanks a value the user already saw**. Only an
authoritative answer clears a price (`PriceWriteback` holds that rule and is tested
directly); a transient failure keeps the last value and marks the column stale.
Bulk refresh is cache-first — forcing on every card burns the 200/day Card Ladder
budget, which reads to the user as prices going blank.

## Design

**Caliper** is the current system. `design/caliper/README.md` is the source of
truth and `design/caliper/reference/` holds the per-component rules; `design.md`
now only records what Caliper overturned and keeps the retired v1 as an appendix.
The HTML/React files in `reference/` are design references, **not code to port**.

Tokens live in `ios/Slab3/DesignSystem/DesignTokens.swift` + `CaliperType.swift`,
generated from the reference CSS — change both in the same commit. Non-negotiables:
dark only; **square** (radius 3 is the maximum and only controls get it); structure
is hairlines with **no elevation shadows**; exactly **one cyan primary action per
screen**; both price sources visible on every row, with the toggle changing
emphasis and sort basis, never visibility; confidence is warm so a meter can never
be misread as a source hue; **a missing price is an em dash — never `$0`, never
blank**; copy states what happened without apology.

Two faces (Space Grotesk, JetBrains Mono) are Google Fonts with no .ttf in the
handoff, so `CaliperType` falls back to system faces at the same sizes and weights
until the binaries are added to the target and registered under `UIAppFonts`.

## Where the prose evidence lives

Four docs carry decisions that are not recoverable from the code; read the relevant
one before changing that area:

| Doc | Holds |
|---|---|
| `spike/README.md` | Per-source bot-wall verdicts, dated. Authoritative on access paths. |
| `design/caliper/README.md` | Design source of truth; `reference/component-rules.md` + `prop-contracts.md` are the per-component rules. |
| `supabase/functions/README.md` | Edge Function setup (`CL_ENC_KEY` generation, secrets) + curl smoke tests. |
| `TODOS.md` | Deferred scope with rationale and the decision id that deferred it. |

`design.md` is now only a record of what Caliper overturned, with retired v1 as an
appendix — not current guidance.

## Conventions

- Every non-obvious file opens with a comment explaining *why it exists* and citing
  the evidence (spike date, plan task id like `T3`/`D10`, buyer decision). Match that
  density; when you learn something about a source's access model, write it into the
  adapter header and `spike/README.md`.
- `worker/.env` (`PSA_ACCESS_TOKEN`) and `spike/.env` (`CL_EMAIL`/`CL_PASSWORD`) hold
  real personal credentials — gitignored, never commit or echo them. `spike/.state/`
  holds live session cookies, likewise.
- Commit messages record the test count (e.g. `77/77 tests` — the `worker/` vitest
  total, currently 77 across 7 files; the iOS suite is a separate 66 in 10 suites,
  and pgTAP is 15);
  tests are expected green before committing.
- `TODOS.md` holds deferred scope with the rationale (currently: offline scan queue).
