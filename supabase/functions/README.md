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
