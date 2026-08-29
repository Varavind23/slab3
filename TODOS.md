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

**What:** Find and integrate the endpoint Courtyard's own iOS app uses when you
scan a slab and it returns a market value + confidence.

**Why:** This is the number the buyer actually wants. Slabs currently sources
Courtyard from its Algolia MARKETPLACE indices, which describe vaulted inventory —
a fundamentally different thing. Live comparison on cert 96679812 (2022 Optic
Splash! #10 Curry PSA 10): Courtyard's app said **$50.80, confidence 2**; that
slab is not in the marketplace index at all, so we had nothing and were showing an
unrelated Curry's $18 at confidence 1. Matching is now tightened to refuse rather
than guess, which is honest but leaves Courtyard blank on most cards.

**Why the current path cannot be fixed by trying harder** (all verified 2026-08-29,
see spike/README.md §2):
* Cert is neither facetable nor searchable in their Algolia indices, and a bare
  cert query returns typo-tolerant near-misses belonging to unrelated cards.
* The indices are recent-activity feeds; cards age out (a Charizard findable in
  the morning was gone by evening, its ledger showing a `burn`).
* No query shape surfaced a known-indexed card within 40 hits.
* **The whole web API was enumerated** — 172 endpoints extracted from their
  generated client in the courtyard.io bundle — and it contains NO cert-lookup and
  NO price-by-card-identity route. Every pricing endpoint is per-vaulted-asset
  (`/index/asset/{id}/estimate`, `/pricing/instant-sell-offer/{assetId}`). The
  scanner therefore exists only in the mobile app.

**Plan:**
1. Proxy-capture the Courtyard iOS app: mitmproxy on the Mac, iPhone Wi-Fi proxy +
   its CA profile trusted, then use the app's scanner on a real slab. Capture the
   request for a card that IS vaulted and one that is NOT (the Curry) — the second
   is the one that proves a catalog-wide pricing service.
2. If TLS pinning blocks it, fall back to: a jailbreak-free SSL-kill-switch is out
   of scope, so instead ask Courtyard directly for API access — they have a
   partner/API story for vaulting integrations and the ask is cheap.
3. Model the endpoint in `worker/src/sources/` behind the existing transport seam,
   mirrored in `CourtyardClient.swift`, with fixtures. If it needs an account,
   follow the Card Ladder pattern exactly: bring-your-own-account, credentials
   encrypted server-side, per-user budget, never in the client.

**Needs from the buyer:** ~20 minutes with the phone (trust a CA profile, scan two
slabs), and a Courtyard login for the authenticated case.

**Until then:** Courtyard shows an em dash on cards it cannot identify. That is
deliberate — a price belonging to another card is a fabricated price for this one.
