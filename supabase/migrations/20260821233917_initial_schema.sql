-- Graded Card Sourcing Scanner v1 — initial schema
-- Plan: ~/.claude/plans/keep-going-parsed-unicorn.md (T2)
--
-- Design notes baked in from the M0 spike:
--   * Card Ladder price source = Firebase-auth'd; metric = AVERAGE SALE.
--   * Courtyard price source = public api.courtyard.io; metric = RECENT SALE.
--   * Sale-limit rule = max 3 identical card_key per folder; 4th requires ack (4A).
--   * price_cache is GLOBAL (service-role only) — no per-user RLS (D10).
--
-- Trust model:
--   * User tables: RLS scoped to auth.uid().
--   * Shared/worker tables (price_cache, card_identity_map, worker_jobs,
--     scrape_budget, cardladder_credentials): NO anon/authenticated policies —
--     reachable only via the service role (Edge Functions / worker). RLS is
--     enabled with zero policies = deny-all to clients.

-- ────────────────────────────────────────────────────────────────────────────
-- Enums
-- ────────────────────────────────────────────────────────────────────────────
create type grader as enum ('psa', 'cgc');
create type price_source as enum ('cardladder', 'courtyard');
create type price_metric as enum ('average_sale', 'recent_sale');
create type fetch_status as enum ('ok', 'not_found', 'source_error', 'pending');
create type match_confidence as enum ('exact', 'probable', 'fuzzy');
create type job_status as enum ('queued', 'running', 'done', 'failed');

-- ────────────────────────────────────────────────────────────────────────────
-- card_key normalization — ONE source of truth (mirrored in Swift, D2 note)
-- Shape: '{grader}:{set}:{card_id}:{grade}', lowercased, spaces→'-', stripped.
-- Used by BOTH sale-limit counting and price matching, so it must be stable.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function make_card_key(
  p_grader grader, p_set text, p_card_id text, p_grade text
) returns text
language sql immutable
as $$
  select lower(p_grader::text) || ':' ||
         regexp_replace(lower(coalesce(trim(p_set), '')),     '[^a-z0-9]+', '-', 'g') || ':' ||
         regexp_replace(lower(coalesce(trim(p_card_id), '')), '[^a-z0-9]+', '-', 'g') || ':' ||
         regexp_replace(lower(coalesce(trim(p_grade), '')),   '[^a-z0-9]+', '-', 'g')
$$;

-- ────────────────────────────────────────────────────────────────────────────
-- USER TABLES (RLS = auth.uid())
-- ────────────────────────────────────────────────────────────────────────────
create table cards (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  grader        grader not null,
  cert_number   text   not null,
  card_key      text   not null,
  name          text,
  set           text,
  year          int,
  grade         text,
  scanned_at    timestamptz not null default now(),
  raw_lookup    jsonb,
  manual_price_cents int,          -- degraded-mode manual override (D10)
  notes         text,
  unique (user_id, grader, cert_number)
);
create index cards_user_key_idx on cards (user_id, card_key);

create table folders (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  name         text not null,
  source_label text,
  created_at   timestamptz not null default now()
);

create table folder_cards (
  folder_id      uuid not null references folders(id) on delete cascade,
  card_id        uuid not null references cards(id) on delete cascade,
  over_limit_ack boolean not null default false,   -- 4A: explicit override
  added_at       timestamptz not null default now(),
  primary key (folder_id, card_id)
);

alter table cards        enable row level security;
alter table folders      enable row level security;
alter table folder_cards enable row level security;

create policy cards_owner on cards
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy folders_owner on folders
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
-- folder_cards inherits ownership through the parent folder.
create policy folder_cards_owner on folder_cards
  for all
  using (exists (select 1 from folders f where f.id = folder_id and f.user_id = auth.uid()))
  with check (exists (select 1 from folders f where f.id = folder_id and f.user_id = auth.uid()));

-- ────────────────────────────────────────────────────────────────────────────
-- SHARED / WORKER TABLES (RLS enabled, NO client policies = deny-all to clients)
-- Reached only via service role (Edge Functions + worker).
-- ────────────────────────────────────────────────────────────────────────────

-- Global price cache, keyed by (card_key, source). One row per source per card.
create table price_cache (
  card_key     text not null,
  source       price_source not null,
  metric       price_metric not null,
  price_cents  int,
  as_of        timestamptz,
  fetch_status fetch_status not null default 'pending',
  updated_at   timestamptz not null default now(),
  primary key (card_key, source)
);

-- Reconciles our slab metadata to each source's own catalog id (D10).
create table card_identity_map (
  card_key            text not null,
  source              price_source not null,
  source_canonical_id text,
  confidence          match_confidence not null,
  confirmed_by_user   boolean not null default false,
  updated_at          timestamptz not null default now(),
  primary key (card_key, source)
);

-- Per-user Card Ladder credentials. encrypted_blob is written/read ONLY by the
-- worker via service role; never returned to a client. (Encryption via
-- Supabase Vault / pgsodium is configured at deploy; column holds ciphertext.)
create table cardladder_credentials (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  encrypted_blob text not null,
  session_state  jsonb,          -- Firebase refresh/session reuse (spike: persists)
  last_ok_at     timestamptz,
  failure_count  int not null default 0,
  updated_at     timestamptz not null default now()
);

-- Per-source scrape budget (D10) — keeps request volume human-shaped.
create table scrape_budget (
  source        price_source not null,
  user_id       uuid references auth.users(id) on delete cascade,  -- null = global
  window_start  timestamptz not null default date_trunc('day', now()),
  request_count int not null default 0,
  cap           int not null,
  primary key (source, user_id, window_start)
);

-- Job queue: Edge Functions enqueue; the worker polls with service role (D10).
create table worker_jobs (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users(id) on delete cascade,
  kind        text not null,          -- 'price_refresh' | 'cert_lookup' | ...
  card_key    text,
  source      price_source,
  status      job_status not null default 'queued',
  attempts    int not null default 0,
  last_error  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index worker_jobs_queue_idx on worker_jobs (status, created_at)
  where status in ('queued', 'failed');

alter table price_cache            enable row level security;
alter table card_identity_map      enable row level security;
alter table cardladder_credentials enable row level security;
alter table scrape_budget          enable row level security;
alter table worker_jobs            enable row level security;
-- No policies created for the five tables above → clients are denied; service
-- role bypasses RLS. This is the worker trust boundary in one line.

-- ────────────────────────────────────────────────────────────────────────────
-- Sale-limit RPC (4A) — max 3 identical card_key per folder; 4th needs ack.
-- Returns the decision so the client can render warn+override; the actual
-- insert into folder_cards is gated by the same count in a trigger below.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function check_sale_limit(p_folder_id uuid, p_card_id uuid)
returns table (identical_count int, at_limit boolean, requires_ack boolean)
language sql stable security invoker
as $$
  with target as (
    select card_key from cards where id = p_card_id
  ),
  cnt as (
    select count(*)::int as n
    from folder_cards fc
    join cards c on c.id = fc.card_id
    where fc.folder_id = p_folder_id
      and c.card_key = (select card_key from target)
  )
  select n,
         n >= 3          as at_limit,
         n >= 3          as requires_ack
  from cnt;
$$;

-- Enforce the rule on insert: a 4th identical card_key requires over_limit_ack.
create or replace function enforce_sale_limit()
returns trigger language plpgsql as $$
declare
  v_card_key text;
  v_count    int;
begin
  select card_key into v_card_key from cards where id = new.card_id;
  select count(*) into v_count
  from folder_cards fc join cards c on c.id = fc.card_id
  where fc.folder_id = new.folder_id and c.card_key = v_card_key;

  if v_count >= 3 and not new.over_limit_ack then
    raise exception 'sale_limit_exceeded: % identical cards already in folder; set over_limit_ack to override', v_count
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger folder_cards_sale_limit
  before insert on folder_cards
  for each row execute function enforce_sale_limit();
