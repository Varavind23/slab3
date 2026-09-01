-- Courtyard's SCANNER endpoint gets a cache of its own (2026-08-31).
--
-- WHAT CHANGED UPSTREAM. Courtyard's own app prices a scanned slab through
-- GET api.courtyard.io/scanner/card-details?cert=…&grader=… — unauthenticated,
-- cert-keyed, and backed by a pricing MODEL rather than by vault inventory. It
-- answers for cards Courtyard has never held, which the Algolia marketplace path
-- structurally could not: those indices are recent-activity feeds that cards age
-- out of. Found by tearing down the Android app; confirmed against the app on
-- device (cert 96679812 = $50.80 / medium, cert 154334127 = "not applicable").
-- Full account: spike/README.md §2b.
--
-- WHY A TABLE OF ITS OWN, rather than price_cache + card_identity_map +
-- card_sales_cache. Those three exist because Card Ladder answers three questions
-- with three calls, on three different schedules — its comps are fetched lazily,
-- on a detail screen, against a paid daily budget. Courtyard answers all three in
-- ONE response: price, identity AND grade-split comps arrive together, are true
-- together, and go stale together. Splitting one document across three tables
-- would invent structure the source does not have and turn one read and one write
-- into three of each, for no gain — nothing reads a Courtyard price without also
-- wanting the identity that came with it.
--
-- KEYED (grader, cert), which is Courtyard's OWN id: `graderData.id` comes back as
-- "PSA_96679812". Same principle as clSourceKey — ask the source what it calls
-- this thing rather than rebuilding an identity out of its text fields — with the
-- bonus that this key is derivable from the scan itself, so a cache hit costs no
-- network at all. It is per-SLAB, not per-card+grade, because the response
-- carries no card-level id: two slabs of the same card get two rows. That is more
-- rows than strictly necessary and never a wrong answer, and since this source
-- needs no account and no budget, the trade costs nothing.
--
-- NOT ADDED: a `cy_market_value` value on the price_metric enum. Nothing writes a
-- Courtyard row to price_cache, so the enum does not need to learn the name; the
-- Edge Function returns the metric as a plain string in its reply. Add it if and
-- when a Courtyard price is ever written to price_cache.

create table if not exists cy_scan_cache (
  grader       grader not null,
  cert         text   not null,
  -- Courtyard's own id for this slab, "PSA_96679812". Stored though it is
  -- derivable, so a row can be traced back to the source's identifier.
  source_key   text   not null,

  -- NULL means Courtyard has NO model price for this card. It states that as
  -- `price: 0` with `priceConfidence: "0"`, and its own app renders it as "not
  -- applicable" — so 0 must never survive as a number. A $0 in the UI is a
  -- fabricated price, which is the one thing the price rules forbid outright.
  price_cents       int,
  -- Courtyard's OWN 1-5 confidence in its estimate (the app buckets it to
  -- low/medium/high). NULL whenever there is no price. Distinct from
  -- card_identity_map.confidence, which is how sure we are we matched the card.
  source_confidence int,

  -- Identity, cert-exact and free. Worth more than it looks: `grade` is a
  -- card_key segment, and until 2026-08-31 Card Ladder was the ONLY source that
  -- could supply one (the barcode carries a cert and nothing else, and PSA's cert
  -- page has been 403-walled since 2026-08-28). This gives a grade to users with
  -- no Card Ladder account at all.
  grade        text,          -- bare number: '9', '10', '9.5'
  title        text,          -- assembled; belongs in Card.title, NEVER Card.name
  subject      text,          -- the short name, 'Stephen Curry'
  card_set     text,
  card_year    text,
  card_number  text,
  category     text,
  population   int,           -- graded population at this card+grade (via GemRate)
  image_url    text,

  -- Grade-split sale history for the CARD, newest first within each group:
  --   [{ grader, grade, population, sales: [{ priceCents, soldAt }] }, ...]
  -- Groups are per (grader, grade) and MUST be read that way: cert 96679812
  -- returns two grade-10 groups — PSA (pop 23) and SGC (pop 3) — and every group
  -- repeats the SCANNED card's title, so the SGC group is labelled '(PSA g10)'.
  -- Keying comps off the title reports other graders' sales as PSA's. Groups may
  -- also cover a grade the slab is not (cert 154334127 is a g9 whose only comps
  -- are g10); the app labels the grade rather than implying they are the slab's.
  comps        jsonb not null default '[]'::jsonb,

  -- false = "Courtyard isn't buying this card", their app's own words.
  acquisition_accepted boolean,

  -- 'ok' | 'not_found'. A 404 is AUTHORITATIVE (Courtyard's catalog has no such
  -- cert) so it is cached like any other answer. A 502 — their GemRate upstream
  -- failing — is TRANSIENT and is never written here: caching it would turn a
  -- passing outage into a day of blank prices.
  fetch_status fetch_status not null default 'ok',
  fetched_at   timestamptz not null default now(),
  primary key (grader, cert)
);

-- Worker table: RLS on with ZERO policies = deny-all to clients, service role
-- only. Same trust model as price_cache — clients never read this directly, they
-- go through the courtyard-price Edge Function.
alter table cy_scan_cache enable row level security;
