# Price & cert sources — per-source detail

Moved out of CLAUDE.md (2026-10-01) verbatim; CLAUDE.md keeps the summary rules. `spike/README.md` remains authoritative on access paths.

- **Courtyard: browserless and cert-keyed — and BRING-YOUR-OWN-ACCOUNT since
  2026-10-29.** At ~03:25 UTC that day `card-details` started answering **401
  `{"message":"authentication required"}`** to every anonymous request; the user's
  own Courtyard login (Privy, emailed code) unlocks it (`spike/README.md` §2g,
  owner decisions C1–C4). Three adapters are live and none is dead code — know
  which one you are in before editing:
  - **Connecting** (`courtyard-connect` Edge Function, `_shared/courtyard-auth.ts`,
    `_shared/courtyard-session.ts`, `CourtyardConnectView.swift`). Two POSTs —
    `start` (Privy emails a code) and `verify` (log in with `mode: "no-signup"`,
    prove the token on cert 96679812, store it). Traps, all measured:
    * Privy 403s `missing_origin` without `Origin: https://courtyard.io` — the one
      header we send that is not our own (C4: allowed only because required).
    * Courtyard's Privy app is in **HTTP-only cookie mode**: the body's
      `refresh_token` is the literal `"deprecated"`; the real one is the
      `privy-refresh-token` **Set-Cookie** (Domain `privy.courtyard.io`). The server
      keeps the `privy-*` cookies sealed with the token in `courtyard_credentials`.
    * Refresh = `POST privy.courtyard.io/api/v1/sessions` with bearer + cookies.
      Inside the token's ~1h life it answers `session_update_action: "ignore"`.
      Refresh tokens are single-use, so **exactly one call refreshes**, under the
      row's `refresh_lease_until` lease; losers wait for its row. There is no
      password fallback: a refused refresh is `auth_expired` and the user needs a
      new code.
    * `courtyard-price` returns `not_connected` **before the cache read** (C2:
      Courtyard data only to connected users, even on a hit), and `auth_expired`
      for a refused session. Old app builds read both as `.unavailable` and keep
      their last prices. A CY-basis lot claim raises `cy_not_connected`.
  - `worker/src/sources/courtyard-scanner.ts` — **THE price source.**
    `GET api.courtyard.io/scanner/card-details?cert=&grader=`, needs the user's
    `Authorization: Bearer` since 2026-10-29 (401 = `auth_expired`, never cached),
    no browser. One call returns price + identity + grade-split comps.
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

  `courtyard-connect` was "retired, do not rebuild" from 2026-08-31 to 2026-10-29,
  while the scanner was anonymous. Courtyard's login wall reversed that: it is the
  Privy OTP relay §2a designed, built for real (§2g). `spike/courtyard-plan.md` is
  the plan that led to §2b; read §2b and §2g first.
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
  or a 200-slab stack spends its daily budget (400 since 2026-10-24; was 200) on comps nobody opened.
  **Two caches, split along what actually goes stale** (2026-08-31): `cl_resolve_cache`
  maps cert → profileId + grade + identity and has NO TTL, because a cert is one
  physical slab and that mapping cannot change — so a rescan costs nothing;
  `price_cache` / `card_sales_cache` hold the per-card-per-grade answers under
  `clSourceKey` on a 24h TTL. Resolving first is also what lets a price lookup
  compute the right key before deciding whether it needs the network.
  **`resolveCert` is the only authoritative grade in the whole pipeline** — the
  barcode carries a cert number and nothing else — so its `grade`/`gradeLabel`
  must reach the app; dropping it is what caused the V2 grade bug.
  **Since 2026-10-23 the two Google auth calls (sign-in, token refresh) must carry
  `Referer: https://app.cardladder.com/`** — Card Ladder restricted its API key to its own
  web app, and without it Google returns 403 `API_KEY_HTTP_REFERRER_BLOCKED` for every user
  (`spike/README.md` §1c). The Cloud Functions calls don't need it.
  `search.cardladder.com` is never used, but note the SPA bundle is served
  un-walled from `cardladder-71d53.web.app` — that is how the callable list and
  field labels were recovered.
- **PSA: both paths are CLOSED as of 2026-08-28 — see `spike/README.md` §4a.** The
  official API is still unapproved (403), and the cert page now returns 403 with a
  Cloudflare interstitial even to Cloudflare's own Browser Rendering, so the scrape
  yields nothing. The code is correct and ready for the moment either
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
