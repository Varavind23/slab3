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
# ios/Tests uses Swift Testing (@Test/#expect), NOT XCTest — match it. 23 files,
# 25 plain structs, no @Suite attributes — the file name is NOT the struct name in
# three places: PriceSetTests lives in CSVExportTests.swift, DragSelectControllerTests
# in DragSelectTests.swift, and TestingGate's passcode vectors in
# MaxBuyPanelRenderTests.swift, so -only-testing names can't be guessed from ls.
# Five suites render panels to PNG under $TMPDIR/slabs-render/ — DetailScreenRender,
# MaxBuyPanelRender, SwipeRowRender, ExportColumnsRender, LensRender — and assert only
# that the file exists: layout bugs shipped green three times because nothing asserted
# on layout, so LOOK at them. ($TMPDIR is the SIMULATOR's, not the shell's — the test
# log prints each absolute path, which is the only way to find them.)
# ios/project.yml also defines SlabsDev, a side-by-side test build (separate bundle
# id AND separate SwiftData store) so a TestFlight build and a dev build coexist on
# one device. It talks to the SAME live Supabase as the shipped app.
# Shipping version + build live ONLY in ios/project.yml (MARKETING_VERSION /
# CURRENT_PROJECT_VERSION, currently 0.7 / 9, on the release/0.5 branch — 0.7 is
# the max-buy lens plus the 2026-09-23 review fixes; V5 was 0.5 / 5-6 (6 the
# selection-mode scroll fix in 564520b); V4 was 0.4 / 4, on TestFlight since
# 2026-09-06); bump BOTH targets together
# or the dev build stops matching the TestFlight build it exists to compare against.
# Shipping to TestFlight: signing is MANUAL on purpose, and the exact archive +
# exportArchive commands, the App Store Connect API-key role trap that broke the
# ship twice, and the symptom strings it produces live in the header comment of
# ios/ExportOptions.plist. Read that before touching signing; do not "fix" it
# back to automatic.

# supabase
supabase db reset      # apply migrations locally
supabase test db       # pgTAP (supabase/tests/schema_test.sql)
supabase functions serve                       # all Edge Functions locally (needs Docker)
supabase functions deploy cardladder-price     # deploy one
# Five functions: cardladder-connect, cardladder-price, cardladder-sales,
# courtyard-price, psa-cert. cardladder-sales and courtyard-price are separate
# deploys — deploying cardladder-price does NOT ship them.
# Only _shared/ is covered (offline, by the worker/ vitest suite). The function
# BODIES — every <fn>/index.ts: cache-first, stale fallback, what gets written to the
# cache, which grader the image is asked with — have ZERO tests: worker/ cannot import
# them (they pull in Deno-only http.ts). That glue is where the 0.4 image bug lived
# (COURTYARD-BLANKS.md §4.1). Logic you want tested belongs in _shared/.
# Setup + curl smoke tests live in supabase/functions/README.md — but they cannot run
# from this machine today: the SLABS_EMAIL/SLABS_PASSWORD test account returns
# invalid_credentials (wrong credentials, not an unconfirmed account).
#
# A function deploy is a PRODUCTION RELEASE: it reaches every TestFlight user at once
# with no build, and a wrong answer it caches is served for 24h even after a revert.
# Client fixes ship on a different clock (a TestFlight build). Say what you are about
# to deploy/migrate/delete and get a yes first. Verify what is actually live rather
# than trusting commit order (a deploy has predated its own commit):
supabase functions download courtyard-price --project-ref rrkvlrtohmylhslpzuvz  # grep the live bundle
supabase db query --linked "select cert, fetch_status, image_url is null, fetched_at from cy_scan_cache order by fetched_at desc limit 20"
# The installed CLI (2.98.2) has no `functions logs` — use the dashboard.
# Prefer EXPIRING stale cache rows (backdate fetched_at) over deleting them: a
# not_found row can still hold a slab photo URL, and an expiry keeps the old row if
# the re-fetch fails.

# spike (rarely — verdicts are already recorded in spike/README.md)
cd spike && npm install && npx playwright install chromium
npm run courtyard -- "charizard base set psa 9"
npm run cardladder               # the CL callable-flow probe (sign-in -> estimate)
npm run courtyard:probe          # is api.courtyard.io reachable from THIS egress?
# OTP relay, in the order that actually works. The bare command IS step 1 — it
# sends the code, then exits cleanly when there is no TTY (an agent session).
npm run courtyard:auth                     # step 1: EMAILS the code, prints next step
CY_CODE=123456 npm run courtyard:auth      # step 2: skips init, uses that code
# CY_CAPTURE_ONLY=1 is NOT step 1 — it re-captures the Privy app id and exits
# BEFORE init, so it sends no mail and yields no code. Reaching for it first is
# why a login "silently does nothing" (2026-09-05).
cd spike/scan-harness && xcodegen generate  # on-device scanner harness; builds ios/Slab3's
                                            # scanner sources directly, so it drifts if they move
```

## Architecture

### card_key is the spine
`{grader}:{set}:{card_id}:{grade}`, lowercased, every run of non-alphanumerics
collapsed to `-`, **no** leading/trailing trim. It is implemented **three times**
and all three must stay byte-identical: `make_card_key()` in
`supabase/migrations/*.sql`, `CardKey.make` in `ios/Slab3/Shared/CardKey.swift`,
and the `cardKey` field in `worker/src/sources/types.ts`. The SQL and Swift tests
share the same vectors on purpose. It drives the sale-limit rule
(max 3 identical card_key per folder; the 4th requires an explicit
`over_limit_ack`) and cross-source matching. Change one, change all three and both
test suites. **The sale limit is currently enforced nowhere a user can hit it:** it
exists only as a trigger on the SQL `cards` table, the app never writes that table
(see Data / trust model), and `Folder.identicalCount` — the hook for the in-app
notice — has no callers.

**It is NOT a cache key, and must not become one again** (2026-08-31). It is
rebuilt in the app from whatever text the sources filled in, so it is mutable and
lossy: it omits year and card number, and until that date NO source populated
`grade` at all — PSA is walled and Courtyard's matcher refuses to run without a
grade already in hand — so every key ended in a bare `:` and every grade of a card
collapsed onto one string. The server caches are GLOBAL, so a PSA 9 was served the
PSA 10's price, identity, slab photograph and comps, and never reached Card Ladder
at all. Card Ladder's caches now key on `clSourceKey` = `{profileId}:{gradeCode}`
— the source's own identity. See `spike/README.md` §1b.

### The bot-wall problem shapes the whole worker
Every price/cert source is behind some bot protection, and the findings differ per
source. `spike/README.md` is the authoritative record of what works — **read it
before touching any adapter**; don't re-litigate an access path it already ruled out.

- **Courtyard: SOLVED, browserless, and the price is cert-keyed.** Three adapters
  are live and none is dead code — know which one you are in before editing:
  - `worker/src/sources/courtyard-scanner.ts` — **THE price source.**
    `GET api.courtyard.io/scanner/card-details?cert=&grader=`, unauthenticated,
    no browser, no account. One call returns price + identity + grade-split comps.
    Cert-keyed, so it cannot answer with a different card and the whole
    `identify()` guessing problem does not apply here. Found by tearing down the
    Android app (`io.courtyard.app` 1.7.00; Expo/RN but **Hermes bytecode** —
    `strings`, not `grep`); the endpoint appears in none of the 172 web-API routes.
    Logic lives in `supabase/functions/_shared/courtyard-scanner.ts` (cross-runtime,
    like `cardladder.ts`); the worker file only adapts + re-exports it. Mirrored in
    Swift by `CourtyardScannerClient.swift`, served by the `courtyard-price` Edge
    Function over the global `cy_scan_cache` (24h TTL, keyed `(grader, cert)`).
    **Acceptance bar, live not fixture: cert 96679812 = $50.80, confidence 2** —
    what Courtyard's own app shows for that slab. `spike/README.md` §2b.
  - `/scanner/card-grader-image` — the SLAB PHOTOGRAPH, front and back, cert-keyed
    (`fetchGraderImages`). The image source of record since 2026-09-05; Algolia hit
    1 of 4 where this route hit 9 of 9 — but that nine was a biased sample, and many
    certs that price perfectly have NO photo upstream (`COURTYARD-BLANKS.md` §8.4), so
    "priced, camera photo" is usually Courtyard, not us. It verifies the cert, and 200
    is NOT a hit: the no-photo reply is `200 {"primaryImages": null, "status":
    "NO_IMAGE"}` (the adapter comment's "EMPTY array" is also possible — parse both).
    The CDN URLs are unsigned and never expire, so we store the URL and the phone
    fetches the bytes. Traps: the full-size entries carry **no `imageSize` key at all**
    (only thumbnails are labelled); `fetchGraderImages` deliberately **never throws**
    and never logs — a missing picture must never reach `source_error` and blank a
    price, but it also means an image failure is invisible; and it must be asked with
    the pairing that ANSWERED `card-details`, never the caller's grader guess.
    `courtyard-price` only asks for an image on a network miss, so an `ok` row cached
    with a null `image_url` never gains a photo until its 24h TTL runs out.
  - `courtyard-algolia.ts` / `CourtyardClient.swift` — marketplace search. **No
    longer a price source** (2026-08-31), and since 2026-09-05 only the image
    FALLBACK: those indices are recent-activity feeds
    of *vaulted* inventory that cards age out of, and cert is neither facetable nor
    searchable (a bare cert query returns typo-tolerant near-misses of unrelated
    cards — that is how the wrong card got priced). Retained for the cert-keyed
    render image ONLY, and only on an exact hit. `identify()` still governs it.
  - `courtyard.ts` — per-vaulted-asset detail (ask/bid/FMV) via browser transport,
    because `api.courtyard.io/index/*` is Cloudflare-fingerprinted. Not on the
    price path. `courtyard-sales.ts` likewise (on-chain transactions).

  **The grader we send is a GUESS, and a wrong one is a 400** (`spike/README.md`
  §2d). Nothing in a slab barcode names the grader — `CertParser` infers it from
  digit count — and GemRate answers a wrong (cert, grader) pairing with `400
  InvalidArgument`, not 404, deterministically. `fetchCardDetails` therefore walks
  `attemptsFor()`: the caller's guess, then the other grader, then zero-stripped
  variants — but **only past a 400**; a 404 is authoritative and a 5xx is their
  upstream, and retrying those would just multiply load. All-400 is the
  `unresolvable` kind: authoritative, cached like a 404. Do not reclassify a 400 as
  transient again — that is what left cards blank through every refresh, forever,
  while Card Ladder priced them fine. Omitting the grader is NOT a universal
  fallback (it resolves PSA certs, 400s CGC ones), and leading zeros are rejected
  on their own.

  **Every `/scanner/*` request needs TWO headers, and neither is optional**:
  `User-Agent: SCANNER_UA` (absent = 403, below) and
  `cy-supports-acquisition-status: 1` (`SCANNER_ACQ_HEADER`, `spike/README.md` §2f).
  Without the second, `card-details` 404s a large class of certs that price
  perfectly with it — that was the whole "Courtyard em dash while Card Ladder prices
  it" report from 0.4 users, fixed server-side in `5c00ce0`. It is a strict superset
  (nothing that already answered changes). Both are asserted in vitest; keep it that
  way. **A 404 recorded without both headers says nothing about the cert**, and
  there is currently NO verified not_found fixture cert (133653550 used to be one).

  **Scanner error semantics are load-bearing** and map straight onto the honesty
  rules: `404 {"card details not found"}` (with both headers) is AUTHORITATIVE
  (cache it, show an em dash); `502 {"invalid response from gemrate"}` is their upstream failing and is
  TRANSIENT — never cached, never allowed to blank a price the user already saw.
  `price: 0` + `priceConfidence: "0"` means **"not applicable"**, not $0 — map it
  to the no-price state (`cyConfidence` returns undefined outside 1–5, which is
  what keeps a fabricated $0 out of the UI). `priceHistory` groups are per
  **(grader, grade)**, and every group repeats the SCANNED card's title, so keying
  comps off the title reports other graders' sales as PSA's; comps may also be for
  a grade the slab is not. Sale dates are UTC midnight and must render in LOCAL
  time or we disagree with Courtyard's own app by a day.

  Access model, two SEPARATE walls — don't conflate them (`spike/README.md` §2c):
  `/scanner/*` is **User-Agent-walled** as of 2026-09-03. A blocklist of obvious
  tool agents — `curl`, `python-requests`, `Go-http-client`, `node`, and an
  **absent** UA — gets a bare-HTML 403; browsers, `Deno`, `undici`, `okhttp` and
  our own truthful `SCANNER_UA` get 200. It is not an allowlist, so never
  impersonate a browser or their app to get past it. **Every request to this
  endpoint must set a User-Agent explicitly**; leaving it to the runtime default is
  what made Courtyard fail intermittently for no visible reason, because a 403
  lands on the same `source_error` path as a real GemRate outage. Separately,
  `/index/*` and `/users/*` are IP-blocked from consumer networks and Courtyard
  403s an IP that hammers it — which is why the app goes through the Edge Function
  and a shared cache rather than calling from each phone. A 403 from this machine
  on those prefixes is INCONCLUSIVE, never a closed route; run
  `npm run courtyard:probe` before recording one as a finding, and check what UA
  you sent before recording a `/scanner/*` one.

  Retired, do not rebuild: **`courtyard-connect` is not needed for pricing.** The
  scanner endpoint is public; anonymous and bearer responses are byte-identical.
  The Privy OTP relay (`spike/README.md` §2a) still works and is still the right
  design *if* a future feature needs a user session — nothing in the price path
  does. `spike/courtyard-plan.md` is the plan that led here; §2b overturns its
  premises, so read §2b first.
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
  **Two caches, split along what actually goes stale** (2026-08-31): `cl_resolve_cache`
  maps cert → profileId + grade + identity and has NO TTL, because a cert is one
  physical slab and that mapping cannot change — so a rescan costs nothing;
  `price_cache` / `card_sales_cache` hold the per-card-per-grade answers under
  `clSourceKey` on a 24h TTL. Resolving first is also what lets a price lookup
  compute the right key before deciding whether it needs the network.
  **`resolveCert` is the only authoritative grade in the whole pipeline** — the
  barcode carries a cert number and nothing else — so its `grade`/`gradeLabel`
  must reach the app; dropping it is what caused the V2 grade bug.
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
- **CGC: answered, via Courtyard's scanner endpoint.** It returns CGC identity,
  price and comps from the same `/scanner/card-details` call (verified: cert
  4260611176 = $111, confidence 5). CGC's own site is still Turnstile-walled with
  no public API, so `cgc.ts` remains a shell that reports the wall as a distinct
  state — nothing calls it on the price path.

**Never fabricate a price or cert value to make a code path return something.**
Adapters return a typed `SourceError` / `not_found` instead; the UI has a no-price
state for exactly this.

### Three runtimes, one set of adapters
The same TypeScript runs in three places and the split is deliberate:
`worker/` under **Node** for vitest (fixtures, offline), `worker/src/index.ts` on
**Cloudflare** (real browser via the `BROWSER` binding), and
`supabase/functions/` on **Deno** (all five functions). `supabase/config.toml` only
declares three of them (`cardladder-sales` and `courtyard-price` run on defaults,
which also verify the JWT). `supabase/functions/_shared/cardladder.ts` is written cross-runtime on
purpose so Node can test what Deno ships — keep it dependency-free and Web-API-only.
Nothing in `_shared/` is a function: the leading underscore is what excludes it.

`_shared/` holds five files under **two different runtime contracts**, don't mix them:
`cardladder.ts`, `courtyard-scanner.ts` and `crypto.ts` (AES-256-GCM under `CL_ENC_KEY`,
Web Crypto only) are cross-runtime and vitest-tested from Node; `session.ts` (CL credential lifecycle —
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
- **Worker tables** (`price_cache`, `card_sales_cache`, `cl_resolve_cache`,
  `cy_scan_cache`, `card_identity_map`, `worker_jobs`, `scrape_budget`,
  `cardladder_credentials`, `psa_cert_cache`) — RLS enabled with **zero policies** = deny-all to clients;
  reachable only via service role. `price_cache`, `card_sales_cache`,
  `cl_resolve_cache` and the 30-day `psa_cert_cache` are global, not per-user; the
  budget is per-user. `cy_scan_cache` is Courtyard's whole answer for one slab —
  price, identity AND comps in one row, keyed `(grader, cert)`, because the source
  returns all three in one response and they go stale together; a 404 is cached as
  `fetch_status = 'not_found'` (authoritative), a 502 never is. The other caches key
  on `source_key` — the SOURCE's own id for
  the thing it priced, not our `card_key`; `card_identity_map` is now reserved for
  Courtyard's D10 attribute-match work.

The iOS app currently persists locally with SwiftData (`Card`, `Folder` `@Model`s
mirror the SQL columns, with `serverId` reserved for the sync link) and uses
Supabase for auth and Edge Function calls only — it never reads or writes a table,
so `cards`/`folders`/`folder_cards` (and the RLS on them) are unused in production.

**Model changes are a migration on real users' inventory.** There is no
`VersionedSchema`/`SchemaMigrationPlan` — `Slab3App` uses a bare
`.modelContainer(for: [Card.self, Folder.self])` — so new `@Model` properties must
be **optional or defaulted** (additive) for SwiftData's lightweight migration to
keep existing stores; a rename, type change or non-optional field without a
default needs a real migration plan first. That is why the entity is still `Folder`
while every UI string says "group", and why enums are stored as `…Raw: String`.
The anon key in `ios/Slab3/Backend/Backend.swift` is public
by design — RLS, not secrecy, is the protection. The service_role key never goes in
the client.

### iOS shape
`Slab3App` → `RootView` gates on `AuthManager.state` → `MainShell`. Each tab gets its
OWN navigation stack (`.id(app.tab)`): one shared stack left a card's detail pushed on top
when the tab changed, so the tab bar looked dead (0.7). Re-tapping the active tab bumps
`AppState.tabReselected`, which pops Cards and Scan back to their root. Recent scans rows
open the card; a row that failed to identify retries instead (owner decision, 0.7).
**Four tabs:
Scan, Cards, Export, Settings** — a hand-built `CaliperTabBar`, not a `TabView`,
because the selection bar rises *above* it without replacing it. App-level state
lives in `App/AppState.swift`; two pieces of it are load-bearing and global:
`activeSource` (which of CL/CY leads every row and drives the sort) and `filter`
(shared by Cards and Export — filtering on one carries to the other). Selection also
lives there, because the selection bar is above the tab bar and no screen owns it.
`payoutPercent` is deliberately `nil` until the user sets one — a default rate would
be a fabricated dollar figure, same rule as prices.

**The Cards row carries three gestures** (2026-09-16), kept apart on purpose: a tap
opens the card; a right-to-left swipe slides the CARD ITSELF, uncovering **Delete at
the outer edge** with *file into the group last used* inboard of it — dragged about
half a File button PAST the tray, Delete takes the whole back of the card and fills
red, and releasing there deletes (Gmail's promise — slide back to cancel); and a long
press opens **the system's own context menu** — Select / Remove from group / Delete.
The long press went back to iOS deliberately (2026-09-16): a hand-built 0.8s press
with a spring lift and a tuned haptic was built and then thrown away, because the
system menu brings Apple's zoom and haptic with it, and that pairing is what V4 had
and what the hand-built version never matched. Select turns selection mode on, and
ONLY then does the scrub exist — a short 0.18s hold plus a drag takes every row
crossed, auto-scrolling at the edges. Gating it on selection mode is what stops it
competing with the menu for the same press.

**A scrub starts on the CONFIRMED hold, never on finger-down** (0.7). In a
`LongPressGesture.sequenced(before:)`, `.first(true)` fires when the finger LANDS; starting
the scrub there disabled scrolling on every touch in selection mode, and the long press
then failed — which never calls `onEnded` — so the list froze and the stranded anchor
made the next scrub select rows nobody chose. `ScrubStage` reads the gesture value and
is tested; a `@GestureState` (`scrubHeld`) ends the scrub however the gesture finishes.
The row's context menu is empty in selection mode for the same reason (its press
cancelled the scrub). Likewise a swipe resolves only if its drag passed the horizontal
gate (`SwipeGeometry.release`): a vertical scroll flick used to project past the
commit point and delete the card under the finger.

**A scrub must disable the list's own scrolling** (`scrollDisabled(dragSelect.isActive)`).
The scrub is attached simultaneously, so otherwise both recognise the same vertical
drag: the list scrolls, the finger never crosses a row relative to the content, and
dragging down selects nothing at all. Reaching the rows below is the edge
auto-scroll's job, not the scroll view's.

The row also takes `.frame(maxWidth: .infinity)` BEFORE its hit shape is computed.
Without it the tappable rect can stop short of the trailing price, meter and grade
chip, which is what made taps near the grade badge miss. The commit
point is measured against the tray (`SwipeGeometry.commitOffset`), never as a
fraction of the row: the tray is what the user is aiming at, and a fraction means
something different on every screen width.

**The row is NOT a `Button`, and must not become one again.** It was, and that one
fact caused both of the first version's bugs. `CaliperPressStyle` dims a pressed
button to 0.6, and the tray sat behind the row permanently — so ANY press made File
and Delete ghost through the card without a swipe. And a `Button` swallows the drag
it contains, so the card never followed the finger at all. The row is now a plain
view with `.onTapGesture`, and the tray is mounted ONLY while the card is off its
mark (held through the slide home, or the actions blink out from under a card still
moving over them). Rows lost their press dim along with the Button, which is no
loss: a tap pushes the detail screen, and that is its own feedback. One more trap —
a long press that also fires the row's tap would toggle off the selection it just
made, so `DragSelectController.endedAt` timestamps the scrub and the tap ignores
anything landing within 0.35s of it. Caliper has no swipe language at
all, so this extends the system deliberately, the way `Chip.Size.tap` did. The
long-press context menu that held Select / Remove from group / Delete is **gone**;
`SwipeableCardRow` carries those as `accessibilityActions`, which is the only route
VoiceOver has to them now. Swipe is masked off in selection mode
(`including: .subviews`) — the selection bar owns actions there.

Arbitration is the fragile part. **On iOS 18+ the swipe is a UIKit
`UIPanGestureRecognizer` (`HorizontalPan`, a `UIGestureRecognizerRepresentable`)
whose delegate refuses to BEGIN unless the first movement passes
`SwipeGeometry.isHorizontal` (horizontal beats vertical by 1.2×)** — a vertical
drag fails it at once and UIKit hands the touch to the ScrollView. It replaced a
SwiftUI `DragGesture` (0.7 user report): from iOS 18 SwiftUI gestures are real UIKit
recognisers, and that drag OWNED any touch that started on a card even though the
card never moved, so scrolling only worked from the header or mid-momentum. Do not
put a SwiftUI drag back on the row. iOS 17 keeps the old `DragGesture` path
(`minimumDistance: 8`, same horizontal gate). The UIKit pan reports velocity, not a
projected end, so `SwipeGeometry.projectedTravel` supplies the flick projection
(UIScrollView `.normal` deceleration). Every threshold and the rubber-band curve live in `SwipeGeometry`, tested, so
the gesture closure only reads a value and assigns a result. Scrub hit-testing is
arithmetic (`DragSelectRange.index`) fed by ONE rendered row's index and frame
through a PreferenceKey: rows are uniform and their fonts fixed-size, so that gives
the stack's origin and pitch — and sampling whichever row is rendered, rather than
row 0, is what keeps it correct once LazyVStack has discarded what scrolled away.
`DragSelectRange.apply` recomputes the covered span from the anchor every move
against a baseline snapshot, which is what makes dragging back deselect without
tracking direction.

**Deleting is deferred, never immediate.** `PendingDeletionStore` lives in
`MainShell` (rebuilt per screen, its timer would be cancelled by ARC and the delete
would silently never commit) and holds ONE batch — a new delete commits the previous
one, which is why there is never a question of which delete the Undo bar means.
Pending ids are filtered out of `CardsScreen.visible` AND `ExportScreen.scoped`, so a
card in its undo window is absent from inventory and from the CSV a buyer receives.
It commits on the 5s window, on another delete, on leaving the Cards tab, and on
`scenePhase == .background` — that last one is what stops a "deleted" card
reappearing after a relaunch. Both delete paths, swipe and the selection bar's bulk
Delete, go through it; the real delete is `CardDeletion.commit`, which re-reads the
store rather than closing over cards that may be stale seconds later.

`Folder.lastUsedAt` (additive-optional, per the SwiftData rule above) is what the
swipe's file action reads through `Folder.mostRecentlyUsed(in:)`. Set it beside
every `card.folder = group`, or the swipe starts offering a group nobody has touched
in weeks; nil everywhere means nothing has ever been filed and the action opens the
picker instead of inventing a destination.

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
auto-detected: psacard/cgccards/cgccomics URL host if it is a URL, else bare digits
10 → CGC, 7–9 → PSA, anything else is not a scan — a GUESS every downstream
consumer must tolerate) → `Card` → `PriceService.refresh`, then
`PsaIdentityService.enrich` (PSA last: it is walled and times out slowly).

`RecentCertWindow` decides which sightings are worth reacting to — it never
prevents a duplicate *row* (`ScanScreen.add` refuses a cert already in the store,
unconditionally). Load-bearing because raw Vision has no item tracking, so a slab
in frame re-detects ~12×/s. **Three** rules: a repeat of the **last admitted cert
is blocked outright, whatever the gap** (that's the camera re-reading what's still
in your hand — and it's what makes glare-intermittent detection safe, where a pure
timer would fire a spurious duplicate); **nothing at all is admitted while the slab
just captured is still in frame**, which re-arms only once it has gone unseen for
`clearance` (0.4s); and any *other* recently-seen cert is held by a short ~1.5s
trailing window. It replaced a session-lifetime `Set`, which erred the other way —
a rescan was swallowed forever and never reached the "already in inventory" check.

That middle rule is the **one-slab-at-a-time hold** (2026-09-15, user report: one
card listed repeatedly in Recent scans). Users work a reversed stack, lifting one
slab at a time, so the slab coming off and the one beneath it share the frame
constantly. It needs the WHOLE frame every pass, which is why
`BarcodeDetector.certificates` returns every cert rather than the first and why
`CameraSession` calls `update(sightings:)` even on passes that detect nothing — an
empty frame is the evidence that the slab left. **Only the admitted cert is
recorded** in a pass that admits one, and only the held slab during a hold: record
the whole frame and the next slab's own trailing window gets pushed back on every
pass, costing about a second of dead air per slab (a test caught that, not a
device). `ScanController.isHolding` drives the viewport copy and dims the guides,
because a deliberate hold and a failed read look identical otherwise.

**The duplicate check must ask the STORE** — `CardLookup.existing`, a
`FetchDescriptor` (pending changes included, so an inserted-but-unsaved card
counts) — never a screen's `@Query`. That array is a rendered value and the scan
callback is handed to the camera once at `onAppear`, so a card inserted moments
ago can be missing from it; at burst cadence that gap is where a second read of one
slab inserted a second row, under a cyan "captured" readout instead of the amber
duplicate one.

**Two scan modes** (2026-09-16), remembered in `@AppStorage("caliper_auto_scan")`
on `ScanScreen` — no other screen reads it, so it is deliberately not in
`AppState`. Auto-scan is everything above. Tap-to-scan runs no Vision at all until
the viewport is tapped (the whole viewport is the shutter, per Caliper §2): a tap
**arms the next detection pass** (`TapCaptureArm`) rather than capturing inline,
because the pixel buffer a tap would want is already recycled by the time the tap
reaches the main actor — the armed pass then encodes the frame the barcode was
really read in, one or two frames later. A tap **bypasses the window's rules** (the
user picked that slab, so a second tap on a card already held must reach the
duplicate readout rather than be swallowed by rule 1) but calls `noteAdmitted`, so
flipping back to auto doesn't re-take the slab still in your hand. A tap that finds
nothing readable expires after 1.2s into the `.noCode` toast — under auto-scan
silence was honest because nothing had been asked, but a tap is a question.

Identity and images resolve through a **ranked chain**, not a single source
(`IdentitySource` + `Card.setIdentity`/`setImage`): PSA → Card Ladder → Courtyard,
with the camera capture as the image floor so a row is never picture-less. It has
to be stored rather than implied by call order, because all three writers are
independent async tasks. A lower source may FILL a gap a better one left, never
overwrite it. Grade rides that same chain and is normalized to a bare number by
`GradeText` at every source (`"10 GEM MINT"` / `"PSA 9"` / `"g9"` → `"10"` / `"9"`),
because it is a `card_key` segment and two spellings would be two keys.
Two rules: **an official image is used only on an exact cert match**
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

Prices come from two independent fetches per card (`PriceService.refresh`), so one
source failing never blocks the other. Courtyard is `courtyard-price` (cache-first;
`force: true` comes from exactly two places, the detail screen's "Refresh prices now"
and `ScanScreen.retry`); Card Ladder is only attempted when the user has connected
an account. A refresh **never blanks a value the user already saw**. Only an
authoritative answer clears a price (`PriceWriteback` holds that rule and is tested
directly); a transient failure keeps the last value and marks the column stale.

**There is no bulk refresh** (removed 2026-09-16, owner decision). The Cards tab's
refresh-all button and `PriceRefresher` — which paced a whole folder at 1100 ms for
Card Ladder's ≤1 req/sec rule, or 120 ms on a Courtyard-only run, and dropped Card
Ladder for the rest of a run the moment the connection reported gone — are gone,
because one tap fired a stack-sized burst at exactly the endpoint that 403s an IP for
hammering it, against a 200/day per-user Card Ladder budget. Prices now arrive on the
scan itself and are re-fetched one card at a time from the detail screen. This
knowingly departs from Caliper §3, which specifies that control and its in-flight
`REFRESHING 9 CARDS · CL, CY` line; the `PRICES REFRESHED …` line stays. Any bulk
path that comes back needs the pacing `PriceRefresher` had — recoverable from git
history — and a scope narrower than "everything visible".

### Verified Max Buy Price — the gated pilot (V5, 2026-09-16; a lens since 2026-09-22)

The one number in the app that is **ours**, not a source's: the most a sourcer
should pay for a slab and still clear his cut. It answers a different question from
every price above, and that premise is the thing to hold on to — **the sourcer is
PAID in Card Ladder Value**, so CLV is his revenue, not a reference price, and what
he needs is a ceiling on his offer. Entirely client-side from comps already on the
device: no Edge Function, no migration, no new request, so none of the deploy
caution above applies to changing it. There is no prose doc; the reasoning lives in
the headers of `MaxBuyPrice.swift` (the formula), `MaxBuyValue.swift` (which comps,
and the memo), `MaxBuyPanel.swift` / `ValueBlock.swift` (what is shown) and
`TestingGate.swift` (the gate).

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
  in the worker adapter. It is `Int?` and additive per the SwiftData rule above.

**The lens.** `PriceLens` (`.maxBuy`/`.cl`/`.cy`, in `DesignTokens.swift`) sits ABOVE
`PriceSource` and drives the header toggle's third segment, `MAX`, leftmost and present
only while the gate is unlocked. It is deliberately **not** a third `PriceSource` case:
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
column is gated at both ends via `AppState.exportColumns`, so locking the gate stops it
exporting without destroying the user's column order — the CSV is the part of this app a
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
follow him into the next; the baseline itself is edited once, in Settings → Testing.
`TestingGate` is **obfuscation, not security, and is meant to be** — the passcode is
plain text in the binary (`TestingGate.passcode`, the only place it lives), and its
job is to stop a curious TestFlight user acting on an uncalibrated buy
recommendation, not to withstand anyone trying. A real entitlement would mean an
Edge Function deploy, which is a production release reaching every user at once;
that is not warranted to hide one panel. The unlock is
`@AppStorage("caliper_testing_unlocked")`, read by exactly two screens, so like
`caliper_auto_scan` it is deliberately NOT in `AppState`.

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
blank**; a confidence meter draws as many segments as its SOURCE actually asserts
(CL 5, CY 3 — Courtyard's own app says only low/medium/high) at one fixed width, so
the toggle never moves a row's right edge; copy states what happened without apology.
A chip that is a BUTTON takes `Chip.Size.tap` and owes it `Chip.Size.tap.hitHeight`
— the design's own 44 minimum, deliberately taller than the chip's ink, since a grid
of fifteen 44pt chips would read as fifteen primary actions. `Chip.Size.badge` stays
dense: `GradeBadge` shares the component, repeats down every row, and nothing taps it.
`ExportColumnsRenderTests` pins both halves and renders the grid to a PNG.

Two faces (Space Grotesk, JetBrains Mono) are Google Fonts with no .ttf in the
handoff, so `CaliperType` falls back to system faces at the same sizes and weights
until the binaries are added to the target and registered under `UIAppFonts`.

## Where the prose evidence lives

Seven docs carry decisions that are not recoverable from the code; read the relevant
one before changing that area:

| Doc | Holds |
|---|---|
| `spike/README.md` | Per-source bot-wall verdicts, dated. Authoritative on access paths. |
| `COURTYARD-BLANKS.md` | The 0.4 user bug report (no price / photo / confidence) worked end to end: the live-DB queries, the ruled-out hypotheses, and the latent issues found on the way (§4: cache keyed on the grader guess, silent image failures, function-body coverage). **§8 is the resolution and overrides §3 and Appendix A**; the "Fix not yet applied" status line at the top is stale — `5c00ce0` applied it. Read before debugging any "card shows no Courtyard data" report. |
| `design/caliper/README.md` | Design source of truth; `reference/component-rules.md` + `prop-contracts.md` are the per-component rules. |
| `supabase/functions/README.md` | Edge Function setup (`CL_ENC_KEY` generation, secrets) + curl smoke tests. |
| `TODOS.md` | Deferred scope with rationale and the decision id that deferred it. |
| `spike/courtyard-plan.md` | The Courtyard scanner-API rebuild — the plan that led to the endpoint. **Superseded by `spike/README.md` §2b**, which found it; read §2b first. |
| `supabase/EMAIL.md` | Auth email via Google Workspace SMTP relay: admin setup, DNS, and why nothing sends until a confirmation or reset flow is turned on. |

`design.md` is now only a record of what Caliper overturned, with retired v1 as an
appendix — not current guidance.

## Conventions

- Every non-obvious file opens with a comment explaining *why it exists* and citing
  the evidence (spike date, plan task id like `T3`/`D10`, buyer decision). Match that
  density; when you learn something about a source's access model, write it into the
  adapter header and `spike/README.md`.
- `worker/.env` (`PSA_ACCESS_TOKEN`) and `spike/.env` (`CL_EMAIL`/`CL_PASSWORD`, plus
  `SLABS_EMAIL`/`SLABS_PASSWORD` — the app's own test account, which is what lets the
  UI be driven in the simulator without the owner's phone) hold real personal
  credentials — gitignored, never commit or echo them. `spike/.state/` holds live
  sessions, likewise: `courtyard-session.json` is a LIVE Privy credential, not a fixture.
- Commit messages record the test count (e.g. `83/83 tests` — the `worker/` vitest
  total, currently 131 across 8 files; the iOS suite is a separate 219
  across 23 files / 26 test structs; pgTAP is 19, the `plan(19)` in
  supabase/tests/schema_test.sql). Re-count before writing the message rather than copying the
  last commit's numbers — they have gone stale three times
  (`grep -cE '^\s*(it|test)\(' worker/test/*.test.ts`, `grep -c '@Test' ios/Tests/*.swift`);
  tests are expected green before committing.
- `TODOS.md` holds deferred scope with the rationale. Besides the offline scan queue,
  its "Courtyard cleanup" section lists known, still-open gaps — check it before
  "discovering" one: `PriceService.loadSales` still falls back to the phone-direct
  Algolia comps path; the server's `stale: true` is never decoded by
  `CourtyardScannerClient.Reply`, so a last-known Courtyard price looks current;
  `fetchCardDetails` has no retry on a 502; CGC `g10pristine` collapses to `"10"` and
  is shown ordinary-10 comps (fixing `gradeLabel` changes every `card_key` — needs a
  `gradeRaw` carried end to end instead); the slab BACK photo is fetched but not stored.
