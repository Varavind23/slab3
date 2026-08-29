-- Card Ladder Value + real sale comps (2026-08-29).
--
-- Why: v1 shipped `oneMonthData.averagePrice` as the Card Ladder number. That
-- window is empty for plenty of well-known cards, and since a 0 average maps to
-- null, those cards displayed NO price at all — the first TestFlight users' main
-- complaint. The headline moves to Card Ladder's own "Value" (estimatedValue),
-- and the detail screen gains real recent sales. See spike/README.md §1a.

-- ── 1. The new metric ────────────────────────────────────────────────────────
-- 'average_sale' stays in the enum: existing price_cache rows still carry it, and
-- dropping an enum value would orphan them. It is simply no longer written.
-- ALTER TYPE ... ADD VALUE cannot run inside a transaction block, so this runs
-- outside one; supabase CLI applies each migration file separately.
alter type price_metric add value if not exists 'cl_value';

-- ── 2. Card Ladder's supporting figures, cached alongside the price ──────────
-- These ride the same httpcardestimate call the price comes from, so caching them
-- here costs nothing and keeps a cache hit as informative as a fresh fetch.
alter table price_cache
  add column if not exists last_sale_cents   int,
  add column if not exists last_sale_at      timestamptz,
  -- The SOURCE's own 1-5 confidence in its number. Distinct from
  -- card_identity_map.confidence, which is how sure we are we matched the card.
  add column if not exists source_confidence int;

-- ── 3. Real sale comps ───────────────────────────────────────────────────────
-- Global like price_cache (a card's sales are the same whoever fetched them) and
-- deliberately separate from it: sales are fetched LAZILY when a card's detail
-- screen opens, never during a scan or a bulk refresh, so a 200-slab stack cannot
-- spend its daily Card Ladder budget on comps nobody looked at.
--
-- `sales` is a jsonb array, newest first:
--   [{ priceCents, soldAt, platform?, listingType?, title?, url? }, ...]
-- An EMPTY array is a real answer (the source has no comps) and is distinct from
-- a missing row (never fetched) — the same distinction prices already draw.
create table if not exists card_sales_cache (
  card_key     text not null,
  source       price_source not null,
  sales        jsonb not null default '[]'::jsonb,
  fetch_status fetch_status not null default 'pending',
  fetched_at   timestamptz not null default now(),
  primary key (card_key, source)
);

-- Worker table: RLS on with ZERO policies = deny-all to clients, service role
-- only. Same trust model as price_cache — clients never read this directly.
alter table card_sales_cache enable row level security;
