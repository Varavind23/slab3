# TODOS

## Offline scan queue (deferred 3A, approved D11 — 2026-08-21)

**What:** Full offline scanning with pending-op queue + bidirectional sync.

**Why:** Sourcers scan at card shows/warehouses with dead zones; v1 is
online-required with durable retry (D9), so a true dead zone means scanning stops.

**Pros:** Restores the scan-anywhere guarantee; strongest field UX.
**Cons:** Sync/conflict complexity (multi-device semantics, server-wins rules).

**Context:** v1 ships online-required with a durable retry queue for failed
requests. This TODO is the upgrade path if buyer feedback shows connectivity pain
in the field. Start from `ios/` LocalStore retry queue — extend it into a full
pending-op queue with sync on reconnect.

**Blocked by:** v1 local store shape shipping first.

## Courtyard scanner API — the real price source (opened 2026-08-29)

**Goal:** show what Courtyard's own app shows when it scans a slab — market value
+ confidence — for any card, not just ones sitting in their vault.

**Where we are.** Slabs sources Courtyard from its Algolia MARKETPLACE indices,
which describe vaulted inventory. Their app prices cards they do NOT hold: cert
96679812 (2022 Optic Splash! #10 Curry PSA 10) reads **$50.80 / confidence 2** in
their app and is absent from the index entirely, so we had nothing and were
showing an unrelated Curry's $18. Matching now refuses rather than guesses, which
is honest but leaves Courtyard blank on most cards.

**Why the current path is a dead end, not a tuning problem** (verified 2026-08-29,
spike/README.md §2): cert is neither facetable nor searchable, and a bare cert
query returns typo-tolerant near-misses of unrelated cards; the indices are
recent-activity feeds that cards age out of; no query shape surfaced a
known-indexed card within 40 hits; and **the entire web API was enumerated — 172
endpoints from the generated client in their bundle — with NO cert-lookup and NO
price-by-card-identity route.** Every pricing endpoint is per-vaulted-asset. The
scanner exists only in the mobile app.

---

### Phase 1 — find the endpoint (BLOCKING; everything below depends on it)

Proxy-capturing the iOS app is **rejected** (owner declined connecting the phone).
The replacement needs no device:

1. **Android APK teardown.** `io.courtyard.app` on Google Play, ~140 MB, listing
   advertises "instantly identify graded cards with a quick scan" + "real-time
   market pricing" — the exact feature. Pull the APK, unzip, and grep for API
   hosts/paths. If it is React Native, `assets/index.android.bundle` holds every
   URL in plain JS; if native, strings over `lib/` and `classes*.dex`.
   Deliverable: the pricing endpoint's host, path, method, request shape, and
   **whether it requires auth**.
2. **In parallel, email Courtyard for API access.** They run a vaulting/partner
   business and the ask is cheap. This is the only path that stays legitimate if
   the endpoint turns out to be locked behind attestation.

**Risk to name honestly:** Phase 1 may fail. If the pricing call is gated by
device attestation or a signed app token, no amount of client work reaches it and
Courtyard stays as it is until they grant access.

### Phase 2 — account connect (SHAPE UNKNOWN until Phase 1)

Do NOT build this speculatively. Courtyard auth is **Privy** (1210 refs in the
bundle), which typically means email-OTP or wallet signature rather than a
password — so Card Ladder's "store email+password, sign in server-side" pattern
may not port. `/users/login`, `/users/register` and `/users/refresh` do exist and
take JSON bodies, so a native session may be obtainable; the APK will say.

Only once the auth shape is known:
* `courtyard-connect` Edge Function mirroring `cardladder-connect` — credentials
  or session encrypted with `CL_ENC_KEY`'s sibling, stored in a deny-all table.
* Session lifecycle in `_shared/` alongside `session.ts`.
* iOS `CourtyardConnectView` mirroring `CardLadderConnectView`.
* The iOS client never holds a Courtyard secret, same rule as Card Ladder.

If the endpoint needs **no** auth, skip this phase entirely — that is the good case.

### Phase 3 — adapter + integration

* New source in `worker/src/sources/` behind the existing transport seam, with
  fixtures captured from real calls; mirrored in `CourtyardClient.swift`.
* Feeds the SAME `identify()` bar — a price still has to be this card's.
* Comps continue to come from `/index/asset/{id}/price-history` (unauthenticated,
  the CARD's sales split by grade with population) where an asset resolves.
* Record the access model in the adapter header and `spike/README.md`, per repo
  convention.

### Phase 4 — simulator QA (independent; can run any time)

Slabs test account is in `spike/.env` (`SLABS_EMAIL`/`SLABS_PASSWORD`). Lets UI be
checked in the simulator without the owner's phone. Pairs with
`ios/Tests/DetailScreenRenderTests.swift`, which renders panels to PNG — layout
bugs shipped green three times because nothing asserted on layout.

### Phase 5 — ship V2

Card Ladder Value + last sold + real comps are DONE and verified on device. This
does not wait for Courtyard.
