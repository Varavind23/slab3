# Edge Functions

Server-side price/credential work. Deno; each function is `<name>/index.ts`, shared
code in `_shared/` (the leading underscore keeps it from being treated as a function).

## Card Ladder (bring-your-own-account)

`_shared/cardladder.ts` is the **canonical, verified** Card Ladder client (the same
file `worker/` vitest-tests in Node). It hits Firebase on Google hosts — no Cloudflare,
no browser. See the repo `CLAUDE.md` for the contract + the `condition=g9` gotcha.

- **`cardladder-connect`** — validate a user's own CL email/password (real Firebase
  sign-in), store them AES-GCM-encrypted in `cardladder_credentials` (service role).
- **`cardladder-price`** — cache-first (`price_cache`), per-user daily budget
  (`scrape_budget`), then `httpbuildcollectioncard` → `httpcardestimate`. Prices are
  returned only to users with an active connection.

### One-time setup: the credential encryption key

`_shared/crypto.ts` encrypts stored credentials under `CL_ENC_KEY` (base64 of 32
random bytes). Generate and set it as a Supabase secret:

```sh
# generate a key
node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"
# set it for deployed functions
supabase secrets set CL_ENC_KEY=<the base64 value>
```

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are injected
automatically.

### Run / deploy

```sh
supabase functions serve            # local (needs Docker); invoke with a user JWT
supabase functions deploy cardladder-connect
supabase functions deploy cardladder-price
```

### Local smoke test

With `supabase functions serve` running and a signed-in user's access token in `$JWT`:

```sh
curl -s localhost:54321/functions/v1/cardladder-connect -H "Authorization: Bearer $JWT" \
  -H 'content-type: application/json' -d '{"email":"you@example.com","password":"..."}'
# then, for a known PSA cert:
curl -s localhost:54321/functions/v1/cardladder-price -H "Authorization: Bearer $JWT" \
  -H 'content-type: application/json' \
  -d '{"cert":"20360362","grader":"psa","cardKey":"psa:1986-fleer:73:psa-9"}'
```

The `worker/` vitest suite (`npm test`) already covers the shared client logic offline
against live-captured fixtures (`worker/test/fixtures/cardladder-*.json`).

## Courtyard scanner price (`courtyard-price`)

The number Courtyard's own app shows for a scanned slab: `GET
api.courtyard.io/scanner/card-details?cert=…&grader=…`. Found by tearing down the
Android app; see `spike/README.md` §2b. Anonymous until ~03:25 UTC 2026-10-29,
when it started answering 401 "authentication required" (§2g). It is now
**bring-your-own-account, like Card Ladder**: the caller needs a row in
`courtyard_credentials` (made by `courtyard-connect`, below), each cache miss is
fetched with that user's own Privy bearer, and an unconnected caller gets
`not_connected` **even on a cache hit** (owner decision C2). A refused session is
`auth_expired`; neither is cached.

**Why it is server-side:** a global cache. A 200-slab
bulk refresh from a phone would be 200 requests per device for cards other users
have already fetched, and Courtyard 403s an IP that hammers it (observed on
`/index/*` during the 2026-08-29 spike). One row per cert in `cy_scan_cache`,
keyed `(grader, cert)` and shared by everyone, is the difference between polite
and blocked.

One upstream call returns price, identity **and** grade-split comps together,
which is why they share one cache table rather than the three Card Ladder uses —
see the migration `20260831120000_courtyard_scanner_cache.sql`.

```sh
supabase functions deploy courtyard-price
```

### Local smoke test

```sh
# $JWT must belong to a user with a courtyard_credentials row; anyone else gets
# {"status":"not_connected"}. Run the stack with `--env-file` holding CL_ENC_KEY.
curl -s localhost:54321/functions/v1/courtyard-price -H "Authorization: Bearer $JWT" \
  -H 'content-type: application/json' -d '{"cert":"96679812","grader":"psa"}'
# -> status ok, identity.grade "10", comp groups. THE acceptance bar is that this
#    cert answers `ok`; the number moves ($50.80 / conf 2 on 2026-08-31, Courtyard's
#    own app agreeing on device; $91.30 / conf 3 on 2026-10-29).
curl -s ... -d '{"cert":"154334127","grader":"psa"}'   # priceCents NULL — their app
                                                       # says "not applicable". Never $0.
# NOTE: there is currently NO verified not_found cert. 133653550 was this case
# until 2026-09-06, when it turned out to price at $125.40 once the request
# carries `cy-supports-acquisition-status: 1` (spike/README.md §2f). Any
# replacement MUST be verified to 404 *with* that header before it is trusted.
```

Three response states that must stay distinct, and are asserted in
`worker/test/courtyard-scanner.test.ts`:

| upstream | stored | reply |
|---|---|---|
| price + confidence | `fetch_status ok`, `price_cents` set | `ok` |
| `price: 0` / confidence `"0"` | `fetch_status ok`, `price_cents` NULL | `ok`, `priceCents: null` → em dash |
| `404 card details not found` | `fetch_status not_found` | `not_found` |
| `502 invalid response from gemrate` | **nothing** — transient | last good row as `stale: true`, else `source_error` |
| `401 authentication required` | **nothing** — about the credential | `auth_expired` (the user must reconnect) |
| — (caller has no Courtyard connection) | nothing read | `not_connected`, before the cache |

The `worker/` vitest suite covers the shared client offline against live-captured
fixtures (`worker/test/fixtures/courtyard-scanner-*.json`). The function's own
cache/stale branching is DB-coupled and is not in that suite — same as
`cardladder-price`.

## Courtyard connect (`courtyard-connect`)

Connects the caller's OWN Courtyard account (2026-10-29, `spike/README.md` §2g).
Courtyard has no password — it signs in with an emailed code through Privy — so:

```sh
F=localhost:54321/functions/v1/courtyard-connect; H=(-H "Authorization: Bearer $JWT" -H 'content-type: application/json')
curl -s "${H[@]}" $F                                         # {"ok":true,"connected":false}
curl -s "${H[@]}" $F -d '{"step":"start","email":"you@…"}'    # {"ok":true,"sent":true} — Courtyard emails a code
curl -s "${H[@]}" $F -d '{"step":"verify","email":"you@…","code":"123456"}'
# -> {"ok":true,"connected":true,"emailHint":"y•••@…"}, after proving the token on
#    cert 96679812. Errors (200, ok:false): invalid_email | invalid_code |
#    no_account (never signs anyone up) | courtyard_rejected | rate_limited |
#    courtyard_unreachable.
curl -s -X DELETE "${H[@]}" $F                               # forget the session
```

The session — Privy access token plus its `privy-*` cookies (the refresh token is
the `privy-refresh-token` COOKIE: Courtyard's Privy app runs in cookie mode) — is
sealed with `CL_ENC_KEY` into the deny-all `courtyard_credentials` table. No new
secret. Refresh is serialized per user by `refresh_lease_until`
(`_shared/courtyard-session.ts`).

```sh
supabase functions deploy courtyard-connect
```

## PSA cert identity

`psa-cert` returns the PSA subject, set, year, grade, and optional SecureScan image
for an authenticated user. It reads the 30-day `psa_cert_cache` first, then calls
the secret-authenticated Cloudflare Browser Run Worker in `worker/` on a miss.

Set the same random bearer token on both services, then set the deployed Worker URL:

```sh
cd worker
npx wrangler secret put PSA_SCRAPER_TOKEN
npx wrangler deploy

supabase secrets set PSA_SCRAPER_TOKEN=<same-token>
supabase secrets set PSA_SCRAPER_URL=https://slab3-psa-cert.<account>.workers.dev
supabase functions deploy psa-cert
```

Apply `20260824000000_psa_cert_cache.sql` before deploying the function. The iOS
client never receives either server secret and never talks to PSA directly.
