-- Card Ladder caches move off card_key and onto Card Ladder's OWN identity
-- (2026-08-31). Fixes V2's "a PSA 9 shows the PSA 10's price" report.
--
-- WHAT WAS WRONG. The three worker caches below are GLOBAL (one row serves every
-- connected user) and were all keyed on `card_key` alone:
-- `{grader}:{set}:{name}:{grade}`, rebuilt in the app from whatever text the
-- sources had filled in. Two independent defects met there.
--
--   1. `grade` was never populated, for any card, ever. The slab's barcode carries
--      a cert number and nothing else; PSA's cert page — the source that would
--      supply a grade — has been 403-walled since 2026-08-28; and Courtyard's
--      matcher refuses to run without a grade already in hand, so it could never
--      produce one either. Card Ladder DOES return it (httpbuildcollectioncard →
--      `grade: "g9"`) and we dropped the field at every hop. So every card_key
--      ended in a bare ':' and every grade of a card collapsed onto one row: the
--      first grade anyone scanned won, and a PSA 9 was served the PSA 10's price,
--      identity, cert PHOTOGRAPH and comps — and never reached Card Ladder at all,
--      because the cache answered first.
--
--   2. Even with the grade fixed, the key omits year and card number. Card Ladder
--      calls the 1999 Base Set "Pokemon Game" and reuses that set name across
--      printings, so a 1st Edition and an Unlimited Charizard — an
--      order-of-magnitude price difference — still shared a key.
--
-- THE FIX. Stop reconstructing a source's identity out of its own text fields and
-- ask the source for its id. Card Ladder's `httpcardestimate` takes `profileId`
-- and `condition` (the grade code) as SEPARATE arguments, which proves profileId
-- is card-level and grade-independent: `{profileId}:{gradeCode}` — psa-544027:g6
-- — is exactly, by construction, one priced thing at Card Ladder. That is the new
-- key (see clSourceKey in functions/_shared/cardladder.ts).
--
-- card_key is NOT going away: it still drives the per-folder sale limit and
-- cross-source matching, and it still needs the grade it never had. It is simply
-- no longer a cache key, because it was never able to be one.

-- ── 1. Re-key the three global caches ────────────────────────────────────────
-- Renamed rather than dropped so the tables keep their identity, RLS and grants.
-- The column is no longer a card_key for any source, so the honest name is what
-- it holds: the key THAT SOURCE identifies this priced thing by.
alter table price_cache        rename column card_key to source_key;
alter table card_identity_map  rename column card_key to source_key;
alter table card_sales_cache   rename column card_key to source_key;

-- PURGE. Every existing row is keyed by the collapsing card_key, so every one of
-- them is a candidate to answer for the wrong grade — and card_identity_map has
-- no TTL at all, meaning its wrong names and wrong slab photographs would
-- otherwise never expire. These are caches; there is nothing here to preserve and
-- the next lookup refills them correctly. Without this the fix would ship and
-- users would keep seeing V2's bug for another 24h (identity: forever).
delete from price_cache;
delete from card_identity_map;
delete from card_sales_cache;

-- card_identity_map keeps its renamed column but loses its Card Ladder rows for
-- good: cl_resolve_cache below supersedes it for this source, keyed by the cert
-- rather than by a reconstruction of it. The table stays for Courtyard's
-- attribute-match work (D10), which is the job it was actually created for.

-- ── 2. Resolve cache: cert → Card Ladder's identity ──────────────────────────
-- httpbuildcollectioncard maps a CERT to profileId + grade + the card's details.
-- A cert is one physical slab: that mapping is immutable, so it is cached with no
-- TTL and a rescan of the same slab costs no Card Ladder request at all. This is
-- also what lets a price lookup compute the new source_key BEFORE deciding
-- whether it needs the network — so the common path stays cache-first and the
-- per-user daily budget is spent on estimates, not on re-resolving known certs.
create table if not exists cl_resolve_cache (
  grader       grader not null,
  cert         text   not null,
  profile_id   text   not null,
  grade        text   not null,   -- Card Ladder's grade CODE, e.g. 'g9'
  grade_label  text,              -- the bare number for display, e.g. '9'
  label        text,
  player       text,
  card_set     text,
  card_year    text,
  card_number  text,
  image_url    text,
  fetched_at   timestamptz not null default now(),
  primary key (grader, cert)
);

-- Worker table: RLS on with ZERO policies = deny-all to clients, service role
-- only. Same trust model as price_cache — clients never read this directly.
alter table cl_resolve_cache enable row level security;
