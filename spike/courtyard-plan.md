# Courtyard: getting the number their own app shows

**Status:** planned, not started. Opened 2026-08-29 after V2 testing on device.
**Owner decision:** ship V2 (Card Ladder) first; Courtyard is the next piece.

---

## The problem in one comparison

Scan cert **96679812** (2022 Panini Donruss Optic Splash! #10 Stephen Curry Holo,
PSA 10):

| | value | confidence |
|---|---|---|
| Courtyard's own app | **$50.80** | 2 |
| Slabs, before 2026-08-29 | $18 — *a different Curry's price* | 1 |
| Slabs, now | — (em dash) | — |

We were sourcing Courtyard from its Algolia **marketplace** indices, which describe
the inventory Courtyard has vaulted. Their app prices cards they do **not** hold.
Those are two different products, and no amount of tuning turns one into the other.

Matching is now tightened to refuse rather than guess (`identify()` in
`worker/src/sources/courtyard-algolia.ts`, mirrored in `CourtyardClient.swift`):
a hit must match the cert exactly, or agree on year + card number + grade. That is
honest, and it leaves Courtyard blank on most scanned cards. This document is the
plan to get a real number back.

---

## Why the current path is a dead end, not a tuning problem

All verified 2026-08-29; full detail in `spike/README.md` §2.

1. **Cert is neither facetable nor searchable.** `facetFilters`, `filters`, and
   `restrictSearchableAttributes: ["certification.number"]` all return `nbHits: 0`.
   Worse, a bare cert query returns typo-tolerant **near-miss cert numbers of
   unrelated cards** (`41066652` → `4065652010`, `47076652`, …). That behaviour is
   the mechanism by which the wrong card got priced.
2. **The indices are recent-activity feeds, not a catalog.** Cards age out. A
   Charizard EX (cert 41066652) was findable in the morning and gone by evening;
   its ledger shows a `burn` — redeemed out of the vault.
3. **No query shape rescues it.** For a card known to be indexed, none of
   `"Charizard EX"` (2623 hits), `"Charizard EX <set>"` (24), `"2014 <set> XY17
   Charizard EX"` (10), or `"2014 Charizard EX XY17"` (10) surfaced the target
   within 40 hits.
4. **The entire web API was enumerated and does not contain the feature.** 172
   endpoints extracted from the generated client in the courtyard.io bundle
   (`method:"…",url:"…"` pairs). There is **no cert-lookup route and no
   price-by-card-identity route**. Every pricing endpoint is per-vaulted-asset:
   `/index/asset/{id}/estimate`, `/pricing/instant-sell-offer/{assetId}`,
   `/pricing/instant-sell-offers`, `/users/{userId}/redemptions/v2/estimate`.

**Conclusion:** the scanner's pricing service is reachable only from the mobile
app. Connecting a Courtyard account does not help by itself, because the web
client never calls it — an account is potentially necessary, but nowhere near
sufficient. We need the endpoint first.

---

## Phase 1 — find the endpoint (BLOCKING)

Everything downstream depends on this. Proxy-capturing the iOS app is **ruled
out**: the owner declined connecting the phone. The replacement needs no device.

### 1a. Android APK teardown *(primary)*

`io.courtyard.app` on Google Play, ~140 MB. Its listing advertises the exact
feature — *"instantly identify graded cards and collectibles with a quick scan"*
and *"real-time market pricing so you can see your potential profit."*

```sh
# unzip is enough to start; the interesting part depends on how it is built
unzip -o courtyard.apk -d apk/
ls apk/assets/index.android.bundle        # React Native → every URL in plain JS
strings apk/lib/arm64-v8a/*.so | grep -iE 'courtyard\.io|/pricing|/scan|estimate'
strings apk/classes*.dex | grep -iE 'courtyard\.io/[a-z]'
```

**Deliverables, and the bar for calling this phase done:**
- host + path + method of the pricing call
- request shape (does it take a cert? a grader? a card id?)
- response shape (where do `$50.80` and `confidence: 2` live?)
- **whether it requires auth**, and of what kind

**How to obtain the APK is an open question for the owner.** Google Play needs a
device or account, so the practical route is a mirror site. That is
interoperability research against a service the owner holds an account with, but
it is the owner's call and should not be done unasked.

### 1b. Ask Courtyard for API access *(in parallel, not a fallback)*

They run a vaulting and partner business; the ask is cheap and costs nothing to
send while 1a proceeds. It is also the only path that stays clean if the endpoint
turns out to be gated by attestation.

### Risk, stated plainly

**Phase 1 can fail.** If the pricing call is protected by device attestation
(Play Integrity / App Attest) or a signed app token, no client-side work reaches
it, and Courtyard stays as it is until Courtyard grants access. Decide after 1a
whether to keep pushing or wait on 1b — do not let it become an arms race, which
is the same judgement already made for CGC (`spike/README.md` §5).

---

## Phase 2 — account connect (shape UNKNOWN until Phase 1)

**Deliberately not built yet.** Building it now would likely be thrown away.

The owner's instinct was "connect an account, just like Card Ladder." That pattern
— store email + password, sign in server-side — depends on there being a password
to store. **Courtyard authenticates with Privy** (1210 references in the bundle),
which typically means email-OTP or wallet signature, neither of which a server can
replay on the user's behalf. Their own `/users/login`, `/users/register` and
`/users/refresh` endpoints exist and take JSON bodies, so a native session may be
obtainable — the APK will say which.

Three outcomes, three different designs:

| If Phase 1 finds… | Then |
|---|---|
| no auth required | **skip this phase entirely** — the good case |
| a replayable credential | mirror `cardladder-connect` exactly |
| OTP / wallet only | an OTP relay: user enters the code in Slabs, server exchanges it. New pattern, needs its own design |

Whichever applies, the invariants do not move: the iOS client never holds a
Courtyard secret; credentials are encrypted at rest in a deny-all table reachable
only by service role; lookups happen server-side under a per-user daily budget.

---

## Phase 3 — adapter and integration

- New source in `worker/src/sources/`, taking a transport in its constructor like
  every other adapter, with fixtures captured from real calls
  (`worker/test/fixtures/`). Mirrored in `ios/Slab3/Pricing/CourtyardClient.swift`
  — the two are deliberately kept in agreement.
- If it ships in the Worker bundle, add it to `tsconfig.cloudflare.json`'s
  hand-listed `include` or it is never type-checked.
- **It feeds the same `identify()` bar.** A price still has to be *this card's*;
  a new source is not a licence to loosen that.
- Comps continue to come from `GET /index/asset/{assetID}/price-history`
  (unauthenticated; the CARD's sales split by grade, with population) wherever an
  asset resolves. That endpoint is already integrated and is worth keeping
  regardless of what Phase 1 finds.
- Record the access model in the adapter header and in `spike/README.md`, per the
  repo convention.

---

## Phase 4 — verification

- Fixture tests for the new adapter, including the honest-empty case.
- **The live bar: cert 96679812 must read $50.80 with confidence 2** — matching
  what Courtyard's own app shows for the same slab. Anything else means we are
  reading the wrong field again.
- A second card that Courtyard *does* vault, to check the two paths agree.
- `ios/Tests/DetailScreenRenderTests.swift` for the panel with Courtyard selected.

---

## What is already done and should not be redone

- `identify()` — the two-tier matching bar, in TS and Swift.
- Courtyard's own `estimatedValueConfidence` (1–5, sent as a **string**) surfaced,
  and only on an exact cert match.
- Comps from `price-history`, replacing the on-chain `/transactions` ledger
  (~20% of slabs had ever sold; one sale each).
- `proofOfIntegrity` on an Algolia hit **is** the `assetID` — this is the
  card_key→assetID resolution that `courtyard.ts:resolveAssetId` was stubbed out
  waiting for (D10).
