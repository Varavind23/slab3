# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Slabs** (project id `slab3`) — an iOS app for people who buy and resell *graded*
trading cards in volume: scan a stack of PSA/CGC slabs, get prices from multiple
markets (Courtyard, Card Ladder), organize into groups and team lots, export CSV.
Inventory software, not a collector app. **It is live**: TestFlight users, and since
0.8 real teams' lots and claims in the live Supabase.

Independent pieces, no shared build system:

| Dir | What | Stack |
|---|---|---|
| `ios/` | The app | SwiftUI + SwiftData + supabase-swift, iOS 17, XcodeGen |
| `worker/` | Price/cert adapters **and** the deployed cert-scrape Worker | TypeScript, vitest, Playwright, Cloudflare |
| `supabase/` | Schema + RLS + pgTAP tests, **and** the Edge Functions | Postgres + Deno |
| `spike/` | M0 probes + the on-device scan harness | tsx + Playwright; `scan-harness/` **builds the app's scanner from source**, so it drifts if those files move |
| `design/caliper/` | The design source of truth: handoff doc + HTML/React reference | Docs only |
| `docs/` | Per-area detail moved out of this file — see the table at the end | Docs only |

## Commands

```sh
# worker
cd worker && npm test              # vitest run (all adapter tests, fixture-driven)
npx vitest run test/psa.test.ts    # single file
npx vitest run -t "average sale"   # single test by name
npm run check                      # tsc against tsconfig.cloudflare.json (deployed subset only)
npm run deploy                     # wrangler deploy the slab3-psa-cert Worker

# ios — project.pbxproj is GENERATED; sources are directory globs, so a NEW .swift
# file needs only a regenerate (edit ios/project.yml only for settings/deps)
cd ios && xcodegen generate
xcodebuild -project ios/Slab3.xcodeproj -scheme Slab3 \
  -destination 'platform=iOS Simulator,name=iPhone 17' test   # pick a simulator you have
# single test: add -only-testing:Slab3Tests/CardKeyTests/matchesSqlNormalization

# supabase
supabase db reset      # apply migrations locally
supabase test db       # pgTAP (supabase/tests/*.sql)
supabase functions serve                       # all Edge Functions locally (needs Docker)
supabase functions deploy cardladder-price     # deploy ONE — each function is its own deploy
supabase functions download courtyard-price --project-ref rrkvlrtohmylhslpzuvz  # what is actually live
supabase db query --linked "select cert, fetch_status, image_url is null, fetched_at from cy_scan_cache order by fetched_at desc limit 20"

# spike (rarely — verdicts are already recorded in spike/README.md)
cd spike && npm install && npx playwright install chromium
npm run courtyard:probe          # is api.courtyard.io reachable from THIS egress?
npm run cardladder               # the CL callable-flow probe (sign-in -> estimate)
npm run courtyard:auth                     # OTP step 1: EMAILS the code, exits with no TTY
CY_CODE=123456 npm run courtyard:auth      # step 2. (CY_CAPTURE_ONLY=1 is NOT step 1 — it sends nothing)
```

**iOS tests** use Swift Testing (`@Test`/`#expect`), NOT XCTest — match it. Several
files hold extra structs, so `-only-testing` names can't be guessed from `ls`:
`grep -hE '^(@MainActor )?(final )?struct \w+' ios/Tests/*.swift` lists them (e.g.
`PriceSetTests` is in `CSVExportTests.swift`;
`StaleLoadingTests` + `FileableGroupTests` in `LotGroupRepairTests.swift`). Five `*RenderTests` suites
write PNGs under the **simulator's** `$TMPDIR/slabs-render/` (the test log prints each
path) and assert only that the file exists — layout bugs shipped green three times, so
**look at them**.

**Shipping.** Version + build live ONLY in `ios/project.yml` (`MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION`, currently 0.8 / 10, on `release/0.5`). Bump BOTH targets —
`Slab3` and `SlabsDev`, a side-by-side build with its own bundle id and SwiftData store
that talks to the SAME live Supabase. Signing is MANUAL on purpose; the archive/export
commands and the API-key role trap that broke the ship twice are in the header of
`ios/ExportOptions.plist` — read it before touching signing, never "fix" it to automatic.

**Edge Functions / migrations are production releases.** A function deploy reaches
every user at once with no build, and a wrong answer it caches is served for 24h even
after a revert. Say what you are about to deploy/migrate/delete and get a yes first;
verify what is live rather than trusting commit order (a deploy has predated its own
commit). Applied migrations are never edited — add a new one. Prefer EXPIRING stale cache
rows (backdate `fetched_at`) over deleting them. The CLI (2.98.2) has no `functions
logs` — use the dashboard. Only `_shared/` is tested (by worker/ vitest); the function
BODIES (`<fn>/index.ts`) have zero tests because they import Deno-only `http.ts` — logic
you want tested belongs in `_shared/`. The curl smoke tests in
`supabase/functions/README.md` can't run here: the `SLABS_EMAIL` test account returns
`invalid_credentials`.

## Architecture

### card_key is the spine — and NOT a cache key
`{grader}:{set}:{card_id}:{grade}`, lowercased, every run of non-alphanumerics → `-`,
**no** trim. Implemented **three times**, byte-identical: `make_card_key()` in
`supabase/migrations/*.sql`, `CardKey.make` in `ios/Slab3/Shared/CardKey.swift`, `cardKey`
in `worker/src/sources/types.ts`; SQL and Swift tests share vectors. Change one, change
all three and both suites. It drives cross-source matching and the 3-per-folder sale
limit — which is enforced nowhere a user can hit it (only a trigger on the unused SQL
`cards` table; `Folder.identicalCount` has no callers).

It is mutable and lossy (rebuilt from whatever text sources filled in; no year or card
number), so keying the GLOBAL server caches on it once served a PSA 9 the PSA 10's
price, photo and comps (2026-08-31, `spike/README.md` §1b). Caches key on the
**source's own identity**: Card Ladder on `clSourceKey` = `{profileId}:{gradeCode}`,
Courtyard on `(grader, cert)`.

### Sources — the bot-wall problem shapes the worker
Every source is behind bot protection. `spike/README.md` is authoritative on what
works — **read it before touching any adapter**; don't re-litigate a ruled-out path.
Full per-source detail (endpoints, headers, error semantics, traps): **`docs/sources.md`**.

- **Courtyard — the price source**, browserless and cert-keyed:
  `api.courtyard.io/scanner/card-details` (logic in `_shared/courtyard-scanner.ts`,
  served by `courtyard-price` over `cy_scan_cache`, 24h). Slab photo from
  `/scanner/card-grader-image`; `courtyard-algolia.ts` is only an image fallback on an
  exact hit; `courtyard.ts`/`courtyard-sales.ts` are off the price path. Rules that
  broke prod before:
  - Every `/scanner/*` request sets **both** `User-Agent: SCANNER_UA` and
    `cy-supports-acquisition-status: 1`. Never impersonate a browser or their app.
  - The grader is a **guess** (`CertParser`: 10 digits → CGC, 7–9 → PSA). A wrong one
    is a **400**; `fetchCardDetails` walks `attemptsFor()` only past a 400. All-400 =
    `unresolvable`, authoritative. Never reclassify 400 as transient.
  - 404 (with both headers) is authoritative → cache, em dash. 502 is transient → never
    cached, never blanks a shown price. `price: 0` + confidence `"0"` = no price, not $0.
  - Comp groups are per (grader, grade) and all repeat the scanned card's title — never
    key comps off the title. Sale dates are UTC midnight; render in local time.
  - A 403 on `/index/*` or `/users/*` from this machine is inconclusive (IP walls) —
    run `npm run courtyard:probe` before recording it.
  - Acceptance bar, live: cert 96679812 = $50.80, confidence 2.
- **Card Ladder — live, server-side, bring-your-own-account.** Firebase callables with
  a Bearer ID token: `httpbuildcollectioncard` (cert → profileId + grade) →
  `httpcardestimate` (`estimatedValue` = CL Value; `condition` must be the grade CODE
  `g9`); comps via `httpprofilesales`, fetched **lazily on detail open only** (400/day
  per-user budget). `cl_resolve_cache` (no TTL — a cert never changes) +
  `price_cache`/`card_sales_cache` (24h, by `clSourceKey`). **`resolveCert` is the only
  authoritative grade in the pipeline** — it must reach the app. Logic lives in
  `_shared/cardladder.ts`; the worker adapter only re-exports it.
- **PSA — CLOSED** (API unapproved, cert page Cloudflare-walled even to Browser
  Rendering, 2026-08-28, §4a). The parser and the `slab3-psa-cert` Worker are correct
  and waiting; don't "fix" them.
- **CGC** — answered by the same Courtyard scanner call. `cgc.ts` is a shell.

**Never fabricate a price or cert value to make a code path return something.**
Adapters return a typed `SourceError` / `not_found`; the UI has a no-price state for it.

### Three runtimes, one set of adapters
The same TypeScript runs under **Node** (`worker/` vitest, offline fixtures), on
**Cloudflare** (`worker/src/index.ts`, real browser via `BROWSER`), and on **Deno**
(`supabase/functions/`, all five functions; `config.toml` declares only three — the
others run on defaults, which verify the JWT). `_shared/` has two contracts — don't
mix them: `cardladder.ts`, `courtyard-scanner.ts`, `crypto.ts` are cross-runtime,
dependency-free, Web-API-only and vitest-tested; `session.ts` and `http.ts` are
**Deno-only** (`http.ts` reads `Deno.env` at load — importing it from `worker/` breaks
the Node run).

`worker/tsconfig.cloudflare.json` hand-lists the files that ship in the Worker: **a new
file reachable from `src/index.ts` must be added there** or `npm run check` never sees it.

Adapters never construct an HTTP client: they take a `JsonTransport`/`HtmlTransport`
(Cloudflare fingerprints TLS, so prod injects `BrowserPool`; tests inject
`FixtureTransport` over `worker/test/fixtures/*`). New source ⇒ implement `PriceSource`
or the `CertLookupResult` contract, take a transport, add fixtures.

### Data / trust model
- **User tables** (`cards`, `folders`, `folder_cards`) — RLS on `auth.uid()`, unused in
  production: the app persists locally in SwiftData and calls only auth + functions
  (+ the Teams tables/RPCs).
- **Worker tables** (`price_cache`, `card_sales_cache`, `cl_resolve_cache`,
  `cy_scan_cache`, `psa_cert_cache`, `scrape_budget`, `cardladder_credentials`, …) — RLS
  with **zero policies** = deny-all; service role only. Caches are global; budget is
  per-user.
- The client never holds a server secret (`CL_ENC_KEY`, `PSA_SCRAPER_TOKEN`,
  `PSA_SCRAPER_URL` are Supabase secrets); the anon key in `Backend.swift` is public by
  design.

**SwiftData model changes are a migration on real users' inventory.** No
`VersionedSchema` — a bare `.modelContainer(for: [Card.self, Folder.self])` — so new
`@Model` properties must be **optional or defaulted**; a rename, type change or
non-optional field needs a real migration plan first. That is why the entity is still
`Folder` while the UI says "group", and why enums are stored as `…Raw: String`.

### iOS shape
`Slab3App` → `RootView` (gates on `AuthManager.state`) → `MainShell`. A hand-built
`CaliperTabBar` (not `TabView` — the selection bar rises above it): Scan, Cards, Export,
Settings, plus Teams in the centre **only for someone on a team**. Each tab owns its
navigation stack (`.id(app.tab)`). `App/AppState.swift` holds the global state:
`activeSource` (which of CL/CY leads every row and drives sort), `filter` (shared by
Cards and Export), selection, `scanTargetId`. `payoutPercent` is `nil` until set — a
default rate would be a fabricated figure. Screen-local preferences
(`caliper_auto_scan`) are `@AppStorage`, deliberately not in
`AppState`.

Invariants that have each shipped a bug when broken — details in the linked docs:
- **Prices** (`docs/scan-and-pricing.md`): two independent fetches per card
  (`PriceService.refresh`); a refresh **never blanks a value the user saw** — only an
  authoritative answer clears one (`PriceWriteback`, tested). Comps: `nil` = never
  fetched, `[]` = source has none; nothing is synthesized. **No bulk refresh** (owner
  decision, 2026-09-16) — any bulk path needs pacing and a narrow scope. The one that
  exists is a pasted cert list (Scan's pencil, ≤30 new certs), priced via `PricePacer`.
- **Scan** (`docs/scan-and-pricing.md`): we own the `AVCaptureSession`; Vision at 12 Hz
  and the detection frame IS the photo. `CameraPreview.updateUIView` stays empty; never
  retain the pixel buffer past the callback. `RecentCertWindow`'s three rules gate
  re-detections; the duplicate check asks the STORE (`CardLookup.existing`), never a
  `@Query`.
- **Identity** is a stored ranked chain (PSA → CL → Courtyard → camera capture): a lower
  source fills gaps, never overwrites. Grades normalize via `GradeText` (they are a
  `card_key` segment); official images only on an exact cert match; the long title goes
  in `Card.title`, never `name`.
- **Cards row** (`docs/cards-row.md`): tap / UIKit horizontal pan (iOS 18+). Drag-to-select
  was REMOVED (2026-10-04): in selection mode a drag always scrolls. The row is **not a
  `Button`**; no SwiftUI drag on it; thresholds live in `SwipeGeometry`. Deletes are deferred through `PendingDeletionStore` (in `MainShell`).
  Set `Folder.lastUsedAt` beside every filing.
- **Max buy** (`docs/max-buy.md`): our own number, client-side, for every user since 0.9
  (the passcode gate is gone; baseline in Settings → Max buy).
  `MaxBuyValue` is the one place that picks comps/cap/population; `MaxBuyCache` is
  required (comps decode JSON per read); bump `compsRevision` via the comps setters only.
  `PriceLens` sits above `PriceSource` — **never add a third `PriceSource` case**.
  Export's total and CSV never follow the lens.

### Teams — LIVE since 2026-09-28 (app 0.8)
Detail: **`docs/teams-lots.md`**. Owner decisions D1–D30 are in
`~/.claude/plans/pasted-content-id-4412-for-this-indexed-rabin.md`; root `teams.md` is
the original brief, superseded where they differ.

- Lots (buckets of buy ranges, card cap + dollar budget, ≤3 of one card/grade) live in
  the **live** tables from `supabase/migrations/20260925*` + `20260928*` — new
  migrations only, pushed only with a yes.
- **The server decides every claim** (`claim_lot_scan`, security definer) from its own
  caches by `clSourceKey`; the phone sends lot, cert, grader.
- **`CardFiling` is the only writer of `card.folder`**; claims/releases go one at a time
  through `LotClaimQueue`, releases persisted to `PendingReleaseStore` before sending.
- `LotFolders.sync` mirrors lots as local `Folder`s and must run only once lots are
  LOADED (`TeamSync.shouldSyncGroups`).
- Non-team users keep the exact 4-tab app (`TeamsTabTests`); `TeamsFeature.killSwitch`
  makes it inert.

## Design

**Caliper** — `design/caliper/README.md` is the source of truth,
`design/caliper/reference/` the per-component rules (the HTML/React there is reference,
**not code to port**). Tokens: `ios/Slab3/DesignSystem/DesignTokens.swift` +
`CaliperType.swift`, generated from the reference CSS — change both together.
Non-negotiables: dark only; **square** (radius ≤ 3, controls only); hairlines, **no
shadows**; exactly **one cyan primary action per screen**; both price sources visible
on every row (the toggle changes emphasis and sort, never visibility); **a missing
price is an em dash — never `$0`, never blank**; confidence meters are warm and draw the
source's own segment count (CL 5, CY 3) at one fixed width; tappable chips use
`Chip.Size.tap` with its 44pt hit height. Copy states what happened without apology.
Never hardcode a client's name anywhere in the app.

## Where the prose evidence lives

Read the relevant one before changing that area:

| Doc | Holds |
|---|---|
| `docs/sources.md` | Full per-source detail: Courtyard adapters, headers, error semantics, access walls; Card Ladder flow and caches; PSA, CGC. |
| `docs/scan-and-pricing.md` | Camera/scan pipeline, `RecentCertWindow` rules, scan modes, identity chain, price refresh rules, why bulk refresh was removed. |
| `docs/cards-row.md` | Cards-row gestures and their arbitration history, deferred deletion, `lastUsedAt`. |
| `docs/max-buy.md` | Max Buy formula, inputs, lens, cache, panel and settings. |
| `docs/teams-lots.md` | Teams architecture and the Simulator XCUITest recipe. |
| `spike/README.md` | Per-source bot-wall verdicts, dated. Authoritative on access paths. |
| `COURTYARD-BLANKS.md` | The 0.4 "no Courtyard data" report worked end to end. **§8 overrides §3 and Appendix A**; its "not yet applied" line is stale (`5c00ce0`). |
| `design/caliper/README.md` | Design source of truth (+ `reference/component-rules.md`, `prop-contracts.md`). |
| `supabase/functions/README.md` | Edge Function setup (`CL_ENC_KEY`, secrets) + curl smoke tests. |
| `TODOS.md` | Deferred scope with rationale. Its "Courtyard cleanup" section lists known open gaps — check it before "discovering" one. |
| `spike/courtyard-plan.md` | Superseded by `spike/README.md` §2b — read §2b first. |
| `supabase/EMAIL.md` | Auth email via Google Workspace SMTP relay. |

`design.md` only records what Caliper overturned — not current guidance.

## Conventions

- Every non-obvious file opens with a comment explaining *why it exists*, citing the
  evidence (spike date, decision id like `D10`, owner decision). Match that density;
  access-model findings go in the adapter header and `spike/README.md`.
- `worker/.env`, `spike/.env` and `spike/.state/` hold real credentials and live
  sessions — gitignored; never commit or echo them.
- Commit messages record test counts — currently 131 worker (8 files), 313 iOS (34
  files), 83 pgTAP (`plan()`s in `supabase/tests/*.sql`; the claim race is a separate
  `supabase/tests/concurrency/claim_race.sh`). Re-count rather than copying the last
  commit (`grep -cE '^\s*(it|test)\(' worker/test/*.test.ts`,
  `grep -c '@Test' ios/Tests/*.swift`); tests green before committing.
- UI is verified in the Simulator with a throwaway XCUITest target in a scratchpad copy
  of `ios/` (never committed) — recipe in `docs/teams-lots.md`.
