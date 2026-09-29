-- Teams, lots and buy ranges (2026-09-25).
-- Plan: ~/.claude/plans/read-teams-md-lets-first-harmonic-horizon.md (phase 0).
--
-- WHY THIS EXISTS. A sourcer (Pete) runs a team of buyers working different card
-- shows on the same weekend, all buying into one allocation from a large buyer
-- (Triumph). Triumph takes at most 3 of one card at one grade per lot, and caps
-- each price range in cards and dollars. Until now every phone was an island: no
-- buyer could see what the others had bought, and nobody could see how full a
-- range was until everyone reported back. These tables are the shared truth.
--
-- WHAT A LOT IS. A lot is a GROUP the whole team files into — the app's existing
-- scan → group → export flow, shared. It is a flat list of buy ranges; there is no
-- category/band/bucket hierarchy and no rule inheritance (owner decision, replacing
-- teams.md §3). A card either fits a range or it does not go in the lot.
--
-- THE 3-PER-LOT KEY IS CARD LADDER'S OWN IDENTITY, NEVER card_key. card_key is
-- rebuilt on the phone from whatever text the sources filled in: until identity
-- resolves it carries the CERT NUMBER (Card.refreshCardKey: `name ?? certNumber`),
-- so every slab looks unique and a limit keyed on it never fires; afterwards it is
-- lossy (no year, no card number), so two different cards can collide and block a
-- legitimate buy. CLAUDE.md retired it as a cache key for the same reason on
-- 2026-08-31. `cl_source_key` = `{profileId}:{gradeCode}` is Card Ladder's identity
-- for one card at one grade — exactly "same card, same grade".
--
-- THE SERVER DECIDES, FROM ITS OWN CACHES. claim_lot_scan takes only (lot, cert,
-- grader) and reads identity from cl_resolve_cache and CL Value + confidence from
-- price_cache. The phone has always just called cardladder-price for that cert,
-- which is what warms both; a cold cache answers `pending`, not a guess. No phone
-- can mis-bucket a card by sending a number, and there is one source of truth.
--
-- CARD LADDER IS THE LINE. cl_resolve_cache / price_cache are deny-all because
-- reading them is reading Card Ladder's data, which a user may only do through
-- their OWN connected account (see schema_test.sql). claim_lot_scan therefore
-- requires the caller to have a cardladder_credentials row — which is also the
-- server-side half of "every team buyer must connect CL" (owner decision). The
-- display fields it copies into lot_claims are shown only to team members, all of
-- whom are held to the same rule when they claim.
--
-- TRUST MODEL. Every table here is RLS-scoped by team membership. Reads: any
-- member. Writes to lots / ranges / reports: leads, under RLS. lot_claims and
-- team membership are written ONLY through the security-definer RPCs below — a
-- direct insert would bypass the lock and the limit.
--
-- MONEY IS INTEGER CENTS, bigint where it is summed. No floats anywhere on the
-- allocation path.

-- ────────────────────────────────────────────────────────────────────────────
-- Enums
-- ────────────────────────────────────────────────────────────────────────────
create type team_role       as enum ('lead', 'buyer');
create type lot_status      as enum ('draft', 'active', 'closed');
-- confirmed  : in the lot, counts toward the 3-limit and the range caps.
-- over_limit : an OFFLINE claim replayed after the lot filled (teams.md §5.1).
--              Recorded so the card is not silently lost; counts toward nothing;
--              a lead decides what to drop.
-- removed    : released (card un-filed / deleted / released by a lead).
create type lot_claim_state as enum ('confirmed', 'over_limit', 'removed');

-- ────────────────────────────────────────────────────────────────────────────
-- Teams
-- ────────────────────────────────────────────────────────────────────────────
create table teams (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  -- The only way onto a team. Six characters from a 32-symbol alphabet with no
  -- I/O (misread as 1/0 when read aloud at a show). Stored bare; the app shows it
  -- as K7Q-2MX. Rotating it revokes future joins, not existing members.
  join_code   text not null unique check (join_code ~ '^[A-HJ-NP-Z2-9]{6}$'),
  created_by  uuid not null references auth.users(id),
  created_at  timestamptz not null default now()
);

create table team_members (
  team_id      uuid not null references teams(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  role         team_role not null default 'buyer',
  -- auth.users carries only an email. The name teammates see on a claim
  -- ("JUSTIN · 10:42") and on a limit block ("3 already bought: …").
  display_name text not null check (length(trim(display_name)) > 0),
  joined_at    timestamptz not null default now(),
  primary key (team_id, user_id),
  -- One team per user (assumed for v1, plan §6). The app's TeamState is a single
  -- optional; lifting this is a schema change AND a UI one.
  unique (user_id)
);

-- ────────────────────────────────────────────────────────────────────────────
-- Buy ranges
--
-- Every bound is inclusive EXCEPT value_max_cents, which is exclusive: ranges
-- are written the way Triumph writes them — "$0–$100", "$100–$240" — and a $100
-- card must land in exactly one of those, not trigger a "pick a range" prompt.
-- A NULL bound means "no limit on that side". Grade is grader-agnostic (owner
-- decision): a PSA 9 and a CGC 9 are both 9. numeric(3,1) holds the half grades.
-- max_cards AND budget_cents are both required (owner: "there must be a dollar
-- one as well") — a range is full when EITHER is reached.
-- ────────────────────────────────────────────────────────────────────────────
create table buy_range_templates (
  id              uuid primary key default gen_random_uuid(),
  team_id         uuid not null references teams(id) on delete cascade,
  name            text not null check (length(trim(name)) > 0),
  value_min_cents bigint not null default 0 check (value_min_cents >= 0),
  value_max_cents bigint check (value_max_cents is null or value_max_cents > value_min_cents),
  grade_min       numeric(3,1) not null default 1  check (grade_min between 1 and 10),
  grade_max       numeric(3,1) not null default 10 check (grade_max between 1 and 10 and grade_max >= grade_min),
  cl_conf_min     int check (cl_conf_min between 1 and 5),
  cl_conf_max     int check (cl_conf_max between 1 and 5 and (cl_conf_min is null or cl_conf_max >= cl_conf_min)),
  year_min        int check (year_min between 1900 and 2100),
  year_max        int check (year_max between 1900 and 2100 and (year_min is null or year_max >= year_min)),
  max_cards       int    not null check (max_cards > 0),
  budget_cents    bigint not null check (budget_cents > 0),
  notes           text,
  created_by      uuid not null default auth.uid() references auth.users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index buy_range_templates_team_idx on buy_range_templates (team_id);

-- ────────────────────────────────────────────────────────────────────────────
-- Lots
-- ────────────────────────────────────────────────────────────────────────────
create table lots (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid not null references teams(id) on delete cascade,
  name        text not null check (length(trim(name)) > 0),
  deadline    timestamptz,
  status      lot_status not null default 'draft',
  created_by  uuid not null default auth.uid() references auth.users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index lots_team_idx on lots (team_id, status);

-- A lot's ranges are COPIES of library templates (template_id says where from),
-- so editing the library never silently moves the goalposts of a lot that is
-- already being bought into.
create table lot_buy_ranges (
  id              uuid primary key default gen_random_uuid(),
  lot_id          uuid not null references lots(id) on delete cascade,
  template_id     uuid references buy_range_templates(id) on delete set null,
  name            text not null check (length(trim(name)) > 0),
  value_min_cents bigint not null default 0 check (value_min_cents >= 0),
  value_max_cents bigint check (value_max_cents is null or value_max_cents > value_min_cents),
  grade_min       numeric(3,1) not null default 1  check (grade_min between 1 and 10),
  grade_max       numeric(3,1) not null default 10 check (grade_max between 1 and 10 and grade_max >= grade_min),
  cl_conf_min     int check (cl_conf_min between 1 and 5),
  cl_conf_max     int check (cl_conf_max between 1 and 5 and (cl_conf_min is null or cl_conf_max >= cl_conf_min)),
  year_min        int check (year_min between 1900 and 2100),
  year_max        int check (year_max between 1900 and 2100 and (year_min is null or year_max >= year_min)),
  max_cards       int    not null check (max_cards > 0),
  budget_cents    bigint not null check (budget_cents > 0),
  notes           text,
  sort_order      int not null default 0
);
create index lot_buy_ranges_lot_idx on lot_buy_ranges (lot_id, sort_order);

-- What TRIUMPH says it has accepted, typed in by a lead. Append-only: the latest
-- row is the current figure and the history is the audit trail. Deliberately a
-- separate number from what the team has bought (lot_claims) — they diverge the
-- moment a submission is rejected or a card is regraded, and the UI shows both,
-- never merged (teams.md §8).
create table lot_range_reports (
  id               uuid primary key default gen_random_uuid(),
  lot_buy_range_id uuid not null references lot_buy_ranges(id) on delete cascade,
  used_cents       bigint not null check (used_cents >= 0),
  card_count       int check (card_count >= 0),
  reported_at      timestamptz not null default now(),
  entered_by       uuid not null default auth.uid() references auth.users(id)
);
create index lot_range_reports_range_idx on lot_range_reports (lot_buy_range_id, reported_at desc);

-- ────────────────────────────────────────────────────────────────────────────
-- Claims — one row per physical slab in a lot. Written ONLY by claim_lot_scan /
-- release_lot_claim.
-- ────────────────────────────────────────────────────────────────────────────
create table lot_claims (
  id               uuid primary key default gen_random_uuid(),
  lot_id           uuid not null references lots(id) on delete cascade,
  lot_buy_range_id uuid references lot_buy_ranges(id) on delete set null,
  cert             text not null,
  grader           grader not null,
  cl_source_key    text not null,
  grade_code       text not null,       -- Card Ladder's code, 'g9'
  grade_label      text,                -- the bare number, '9'
  price_cents      int,                 -- CL Value at claim time
  cl_confidence    int,
  -- Display copies so a TEAMMATE's phone can draw the row without the card in
  -- its own inventory (plan §7.5). Frozen at claim time on purpose.
  label            text,
  player           text,
  card_set         text,
  card_year        text,
  card_number      text,
  image_url        text,
  buyer_id         uuid not null references auth.users(id),
  state            lot_claim_state not null default 'confirmed',
  warn_reasons     text[] not null default '{}',
  scanned_at       timestamptz not null,
  claimed_at       timestamptz not null default now(),
  released_at      timestamptz,
  released_by      uuid references auth.users(id),
  device_id        text
);
-- One live claim per physical slab per lot.
create unique index lot_claims_cert_uniq on lot_claims (lot_id, grader, cert) where state <> 'removed';
create index lot_claims_identity_idx on lot_claims (lot_id, cl_source_key) where state = 'confirmed';
create index lot_claims_range_idx    on lot_claims (lot_buy_range_id) where state = 'confirmed';

-- ────────────────────────────────────────────────────────────────────────────
-- Membership helpers. SECURITY DEFINER so RLS policies on team_members can ask
-- "is the caller a member?" without recursing into team_members' own policy.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function is_team_member(p_team_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from team_members where team_id = p_team_id and user_id = auth.uid());
$$;

create or replace function is_team_lead(p_team_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from team_members
                 where team_id = p_team_id and user_id = auth.uid() and role = 'lead');
$$;

create or replace function lot_team(p_lot_id uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select team_id from lots where id = p_lot_id;
$$;

create or replace function range_team(p_range_id uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select l.team_id from lot_buy_ranges r join lots l on l.id = r.lot_id where r.id = p_range_id;
$$;

-- ────────────────────────────────────────────────────────────────────────────
-- RLS
-- ────────────────────────────────────────────────────────────────────────────
alter table teams               enable row level security;
alter table team_members        enable row level security;
alter table buy_range_templates enable row level security;
alter table lots                enable row level security;
alter table lot_buy_ranges      enable row level security;
alter table lot_range_reports   enable row level security;
alter table lot_claims          enable row level security;

-- teams: members read; a lead may rename. Creation, codes and deletion go
-- through RPCs (a client-chosen join_code would defeat the point of one).
create policy teams_read   on teams for select using (is_team_member(id));
create policy teams_rename on teams for update using (is_team_lead(id)) with check (is_team_lead(id));
revoke update on teams from authenticated;
grant  update (name) on teams to authenticated;

-- team_members: members see their team. Every write is an RPC (roles, the
-- last-lead rule and one-team-per-user are enforced there).
create policy team_members_read on team_members for select using (is_team_member(team_id));

-- Library, lots, ranges: members read, leads write.
create policy brt_read  on buy_range_templates for select using (is_team_member(team_id));
create policy brt_write on buy_range_templates for all
  using (is_team_lead(team_id)) with check (is_team_lead(team_id));

create policy lots_read  on lots for select using (is_team_member(team_id));
create policy lots_write on lots for all
  using (is_team_lead(team_id)) with check (is_team_lead(team_id));

create policy lbr_read  on lot_buy_ranges for select using (is_team_member(lot_team(lot_id)));
create policy lbr_write on lot_buy_ranges for all
  using (is_team_lead(lot_team(lot_id))) with check (is_team_lead(lot_team(lot_id)));

-- Reports are append-only: a lead inserts, nobody edits history.
create policy lrr_read   on lot_range_reports for select using (is_team_member(range_team(lot_buy_range_id)));
create policy lrr_insert on lot_range_reports for insert with check (is_team_lead(range_team(lot_buy_range_id)));

-- Claims: members read. NO write policy — claim_lot_scan / release_lot_claim only.
create policy lot_claims_read on lot_claims for select using (is_team_member(lot_team(lot_id)));

-- Live totals on every phone (plan §6): Realtime honours the read policy above,
-- so a subscriber only ever receives claims for its own team's lots.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table lot_claims;
  end if;
end $$;

-- ────────────────────────────────────────────────────────────────────────────
-- Team RPCs. Errors are raised with a machine-readable message the app maps to
-- copy ('not_lead', 'already_in_team', …); business outcomes of a claim are
-- returned as jsonb instead, because they are answers, not failures.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function new_join_code()
returns text language plpgsql volatile set search_path = public as $$
declare
  -- 32 symbols, so byte % 32 is uniform. No I or O.
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  raw bytea;
  code text;
begin
  loop
    raw := uuid_send(gen_random_uuid());
    code := '';
    for i in 0..5 loop
      code := code || substr(alphabet, (get_byte(raw, i) % 32) + 1, 1);
    end loop;
    exit when not exists (select 1 from teams where join_code = code);
  end loop;
  return code;
end $$;

create or replace function create_team(p_name text, p_display_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_team teams;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if exists (select 1 from team_members where user_id = v_uid) then
    raise exception 'already_in_team';
  end if;
  insert into teams (name, join_code, created_by)
    values (trim(p_name), new_join_code(), v_uid) returning * into v_team;
  insert into team_members (team_id, user_id, role, display_name)
    values (v_team.id, v_uid, 'lead', trim(p_display_name));
  return jsonb_build_object('team_id', v_team.id, 'join_code', v_team.join_code);
end $$;

create or replace function join_team(p_code text, p_display_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_team teams;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select * into v_team from teams where join_code = v_code;
  if not found then raise exception 'invalid_code'; end if;
  -- Re-entering your own team's code is a no-op, not an error: it is what a
  -- retried request after a dropped connection looks like.
  if exists (select 1 from team_members where user_id = v_uid and team_id = v_team.id) then
    return jsonb_build_object('team_id', v_team.id);
  end if;
  if exists (select 1 from team_members where user_id = v_uid) then
    raise exception 'already_in_team';
  end if;
  insert into team_members (team_id, user_id, role, display_name)
    values (v_team.id, v_uid, 'buyer', trim(p_display_name));
  return jsonb_build_object('team_id', v_team.id);
end $$;

create or replace function rotate_team_code(p_team_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  if not is_team_lead(p_team_id) then raise exception 'not_lead'; end if;
  v_code := new_join_code();
  update teams set join_code = v_code where id = p_team_id;
  return v_code;
end $$;

create or replace function set_member_role(p_team_id uuid, p_user_id uuid, p_role team_role)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_team_lead(p_team_id) then raise exception 'not_lead'; end if;
  -- Serialise role changes per team so two leads demoting each other at once
  -- cannot both pass the last-lead check below.
  perform pg_advisory_xact_lock(hashtextextended('team:' || p_team_id::text, 0));
  if not exists (select 1 from team_members where team_id = p_team_id and user_id = p_user_id) then
    raise exception 'not_member';
  end if;
  if p_role = 'buyer' and not exists (
    select 1 from team_members
    where team_id = p_team_id and role = 'lead' and user_id <> p_user_id
  ) then
    raise exception 'last_lead';
  end if;
  update team_members set role = p_role where team_id = p_team_id and user_id = p_user_id;
end $$;

create or replace function set_display_name(p_team_id uuid, p_display_name text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_team_member(p_team_id) then raise exception 'not_member'; end if;
  update team_members set display_name = trim(p_display_name)
    where team_id = p_team_id and user_id = auth.uid();
end $$;

-- A lead removing someone, or anyone leaving. A team cannot be left without a
-- lead while other members remain; the last member leaving deletes the team.
create or replace function remove_team_member(p_team_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_user_id <> v_uid and not is_team_lead(p_team_id) then raise exception 'not_lead'; end if;
  perform pg_advisory_xact_lock(hashtextextended('team:' || p_team_id::text, 0));
  if not exists (select 1 from team_members where team_id = p_team_id and user_id = p_user_id) then
    raise exception 'not_member';
  end if;
  if (select count(*) from team_members where team_id = p_team_id) = 1 then
    delete from teams where id = p_team_id;
    return;
  end if;
  if not exists (
    select 1 from team_members
    where team_id = p_team_id and role = 'lead' and user_id <> p_user_id
  ) then
    raise exception 'last_lead';
  end if;
  delete from team_members where team_id = p_team_id and user_id = p_user_id;
end $$;

-- ────────────────────────────────────────────────────────────────────────────
-- claim_lot_scan — the ONLY write path into lot_claims.
--
-- Returns jsonb { outcome, … }:
--   confirmed    claim, range, copies (n of 3), range totals, warn_reasons
--   pending      pending_price — CL has not answered for this cert yet (cold
--                cache); retry after cardladder-price. NOT a verdict.
--   choose_range more than one range fits and has room; candidates listed.
--                Nothing is held — the re-call with p_range_id re-checks it all.
--   blocked      reason + detail:
--                  lot_closed, no_cl_value, duplicate_cert (another buyer has
--                  this slab), limit_reached (+ the 3 existing buys),
--                  no_matching_range (+ the criterion that failed),
--                  range_full_count / range_full_budget
--   over_limit   p_offline replay past a limit: recorded, counts toward nothing.
--
-- Concurrency: an advisory lock on (lot, cl_source_key) serialises the 3-limit;
-- then a lock per candidate range, taken in id order so two claims can never
-- deadlock, serialises the caps. Both are xact locks, released at commit.
-- ────────────────────────────────────────────────────────────────────────────

-- Card Ladder's year field is free text ('1999', '1999-00'); the first four
-- digits are the year. NULL when there are none — an unknown year WARNS, it
-- never blocks (plan §4d).
create or replace function cl_year(p text)
returns int language sql immutable as $$
  select nullif(substring(coalesce(p, '') from '(\d{4})'), '')::int;
$$;

-- A CL price older than this is not trusted to bucket a card. price_cache's TTL
-- is 24h and the phone refreshes CL right before it claims, so anything older
-- means that refresh failed — answer `pending` rather than bucket on a stale value.
create or replace function lot_price_max_age()
returns interval language sql immutable as $$ select interval '36 hours' $$;

create or replace function claim_lot_scan(
  p_lot_id     uuid,
  p_cert       text,
  p_grader     grader,
  p_scanned_at timestamptz default now(),
  p_device_id  text default null,
  p_range_id   uuid default null,
  p_offline    boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid        uuid := auth.uid();
  v_lot        lots;
  v_res        cl_resolve_cache;
  v_price      int;
  v_conf       int;
  v_priced_at  timestamptz;
  v_status     fetch_status;
  v_key        text;
  v_grade      numeric;
  v_year       int;
  v_existing   lot_claims;
  v_copies     int;
  v_warn       text[] := '{}';
  v_value_hits int;
  v_fail       text;
  v_matching   uuid[];
  v_room       jsonb := '[]'::jsonb;
  v_room_ids   uuid[] := '{}';
  v_full       text;
  v_range      lot_buy_ranges;
  v_claim      lot_claims;
  r            record;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select * into v_lot from lots where id = p_lot_id;
  if not found or not is_team_member(v_lot.team_id) then raise exception 'not_member'; end if;
  if not exists (select 1 from cardladder_credentials where user_id = v_uid) then
    raise exception 'cl_not_connected';
  end if;
  if v_lot.status <> 'active' then
    return jsonb_build_object('outcome', 'blocked', 'reason', 'lot_closed');
  end if;

  -- ── Identity + price, from the server's own caches ───────────────────────
  select * into v_res from cl_resolve_cache where grader = p_grader and cert = p_cert;
  if not found then
    return jsonb_build_object('outcome', 'pending', 'reason', 'pending_price');
  end if;
  v_key := v_res.profile_id || ':' || v_res.grade;   -- = clSourceKey (_shared/cardladder.ts)

  select price_cents, source_confidence, fetch_status, updated_at
    into v_price, v_conf, v_status, v_priced_at
    from price_cache
   where source_key = v_key and source = 'cardladder' and metric = 'cl_value';
  if not found or v_priced_at < now() - lot_price_max_age() or v_status not in ('ok', 'not_found') then
    return jsonb_build_object('outcome', 'pending', 'reason', 'pending_price');
  end if;
  if v_status = 'not_found' or v_price is null then
    -- Card Ladder answered and has no value for this card. A value range cannot
    -- be checked against nothing, and inventing one is the thing this app never does.
    return jsonb_build_object('outcome', 'blocked', 'reason', 'no_cl_value');
  end if;

  v_grade := case when v_res.grade_label ~ '^\d+(\.\d+)?$' then v_res.grade_label::numeric end;
  v_year  := cl_year(v_res.card_year);

  -- ── Serialise everything about this card in this lot ─────────────────────
  perform pg_advisory_xact_lock(hashtextextended('lot:' || p_lot_id::text || '|' || v_key, 0));

  -- Same physical slab already in the lot.
  select * into v_existing from lot_claims
   where lot_id = p_lot_id and grader = p_grader and cert = p_cert and state <> 'removed';
  if found then
    if v_existing.buyer_id = v_uid then
      -- Idempotent: a retry, or the offline queue replaying a claim that did land.
      return jsonb_build_object('outcome', v_existing.state::text, 'claim', to_jsonb(v_existing),
                                'replayed', true);
    end if;
    return jsonb_build_object('outcome', 'blocked', 'reason', 'duplicate_cert',
      'by', (select display_name from team_members where team_id = v_lot.team_id and user_id = v_existing.buyer_id));
  end if;

  -- The 3-limit.
  select count(*) into v_copies from lot_claims
   where lot_id = p_lot_id and cl_source_key = v_key and state = 'confirmed';
  if v_copies >= 3 then
    if p_offline then
      insert into lot_claims (lot_id, cert, grader, cl_source_key, grade_code, grade_label,
        price_cents, cl_confidence, label, player, card_set, card_year, card_number, image_url,
        buyer_id, state, warn_reasons, scanned_at, device_id)
      values (p_lot_id, p_cert, p_grader, v_key, v_res.grade, v_res.grade_label,
        v_price, v_conf, v_res.label, v_res.player, v_res.card_set, v_res.card_year,
        v_res.card_number, v_res.image_url, v_uid, 'over_limit', array['limit_reached'],
        p_scanned_at, p_device_id)
      returning * into v_claim;
      return jsonb_build_object('outcome', 'over_limit', 'reason', 'limit_reached', 'claim', to_jsonb(v_claim));
    end if;
    return jsonb_build_object('outcome', 'blocked', 'reason', 'limit_reached',
      'existing', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'buyer', m.display_name, 'scanned_at', c.scanned_at, 'cert', c.cert)
                 order by c.scanned_at), '[]'::jsonb)
          from lot_claims c
          left join team_members m on m.team_id = v_lot.team_id and m.user_id = c.buyer_id
         where c.lot_id = p_lot_id and c.cl_source_key = v_key and c.state = 'confirmed'));
  end if;

  -- ── Which ranges does this card fit? ─────────────────────────────────────
  -- Unknown grade can never satisfy a grade bound (every range has one).
  -- Unknown year or confidence passes that criterion and WARNS instead.
  select count(*) into v_value_hits from lot_buy_ranges
   where lot_id = p_lot_id
     and v_price >= value_min_cents and (value_max_cents is null or v_price < value_max_cents);

  select array_agg(id order by id) into v_matching from lot_buy_ranges
   where lot_id = p_lot_id
     and (p_range_id is null or id = p_range_id)
     and v_price >= value_min_cents and (value_max_cents is null or v_price < value_max_cents)
     and v_grade is not null and v_grade between grade_min and grade_max
     and (v_conf is null or ((cl_conf_min is null or v_conf >= cl_conf_min)
                         and (cl_conf_max is null or v_conf <= cl_conf_max)))
     and (v_year is null or ((year_min is null or v_year >= year_min)
                         and (year_max is null or v_year <= year_max)));

  if v_matching is null then
    if p_range_id is not null and not exists (select 1 from lot_buy_ranges where id = p_range_id and lot_id = p_lot_id) then
      raise exception 'range_not_in_lot';
    end if;
    -- Name the criterion that failed, so the row can say WHY (plan §7.3).
    v_fail := case
      when v_value_hits = 0 then 'value'
      when v_grade is null then 'grade_unknown'
      when not exists (select 1 from lot_buy_ranges where lot_id = p_lot_id
             and v_price >= value_min_cents and (value_max_cents is null or v_price < value_max_cents)
             and v_grade between grade_min and grade_max) then 'grade'
      when not exists (select 1 from lot_buy_ranges where lot_id = p_lot_id
             and v_price >= value_min_cents and (value_max_cents is null or v_price < value_max_cents)
             and v_grade between grade_min and grade_max
             and (v_conf is null or ((cl_conf_min is null or v_conf >= cl_conf_min)
                                 and (cl_conf_max is null or v_conf <= cl_conf_max)))) then 'confidence'
      else 'year'
    end;
    return jsonb_build_object('outcome', 'blocked', 'reason', 'no_matching_range',
      'failed', v_fail, 'price_cents', v_price, 'grade', v_res.grade_label,
      'cl_confidence', v_conf, 'year', v_year);
  end if;

  -- Lock every candidate range in id order, THEN measure room.
  for r in select unnest(v_matching) as id loop
    perform pg_advisory_xact_lock(hashtextextended('range:' || r.id::text, 0));
  end loop;

  for r in
    select b.*, coalesce(t.n, 0) as used_cards, coalesce(t.cents, 0) as used_cents
      from lot_buy_ranges b
      left join lateral (
        select count(*) as n, sum(price_cents)::bigint as cents from lot_claims
         where lot_buy_range_id = b.id and state = 'confirmed'
      ) t on true
     where b.id = any(v_matching)
     order by b.sort_order, b.id
  loop
    if r.used_cards + 1 > r.max_cards then
      v_full := coalesce(v_full, 'range_full_count');
    elsif r.used_cents + v_price > r.budget_cents then
      v_full := coalesce(v_full, 'range_full_budget');
    else
      v_room_ids := v_room_ids || r.id;
      v_room := v_room || jsonb_build_object(
        'range_id', r.id, 'name', r.name,
        'cards_left', r.max_cards - r.used_cards,
        'cents_left', r.budget_cents - r.used_cents);
    end if;
  end loop;

  if cardinality(v_room_ids) = 0 then
    if p_offline then
      insert into lot_claims (lot_id, cert, grader, cl_source_key, grade_code, grade_label,
        price_cents, cl_confidence, label, player, card_set, card_year, card_number, image_url,
        buyer_id, state, warn_reasons, scanned_at, device_id)
      values (p_lot_id, p_cert, p_grader, v_key, v_res.grade, v_res.grade_label,
        v_price, v_conf, v_res.label, v_res.player, v_res.card_set, v_res.card_year,
        v_res.card_number, v_res.image_url, v_uid, 'over_limit', array[v_full],
        p_scanned_at, p_device_id)
      returning * into v_claim;
      return jsonb_build_object('outcome', 'over_limit', 'reason', v_full, 'claim', to_jsonb(v_claim));
    end if;
    return jsonb_build_object('outcome', 'blocked', 'reason', v_full);
  end if;

  if cardinality(v_room_ids) > 1 then
    -- The buyer picks (owner decision). Nothing is held in the meantime.
    return jsonb_build_object('outcome', 'choose_range', 'candidates', v_room,
      'price_cents', v_price);
  end if;

  select * into v_range from lot_buy_ranges where id = v_room_ids[1];

  if v_year is null then v_warn := array_append(v_warn, 'year_unknown'); end if;
  if v_conf is null then v_warn := array_append(v_warn, 'confidence_unknown'); end if;
  -- Near an edge: within 5% or $5, whichever is larger, of either value bound.
  -- Triumph may bucket the card differently than CL Value does. A $0 floor is
  -- not an edge anything can fall off.
  if (v_range.value_min_cents > 0
      and v_price - v_range.value_min_cents < greatest(500, v_price / 20))
     or (v_range.value_max_cents is not null
         and v_range.value_max_cents - v_price <= greatest(500, v_price / 20)) then
    v_warn := array_append(v_warn, 'near_range_edge');
  end if;

  insert into lot_claims (lot_id, lot_buy_range_id, cert, grader, cl_source_key, grade_code,
    grade_label, price_cents, cl_confidence, label, player, card_set, card_year, card_number,
    image_url, buyer_id, state, warn_reasons, scanned_at, device_id)
  values (p_lot_id, v_range.id, p_cert, p_grader, v_key, v_res.grade, v_res.grade_label,
    v_price, v_conf, v_res.label, v_res.player, v_res.card_set, v_res.card_year,
    v_res.card_number, v_res.image_url, v_uid, 'confirmed', v_warn, p_scanned_at, p_device_id)
  returning * into v_claim;

  return jsonb_build_object(
    'outcome', 'confirmed',
    'claim', to_jsonb(v_claim),
    'range', jsonb_build_object('range_id', v_range.id, 'name', v_range.name),
    'copies', v_copies + 1,
    'range_cards', (select count(*) from lot_claims where lot_buy_range_id = v_range.id and state = 'confirmed'),
    'range_cents', (select coalesce(sum(price_cents), 0) from lot_claims where lot_buy_range_id = v_range.id and state = 'confirmed'),
    'warn_reasons', to_jsonb(v_warn));
end $$;

-- Release a slab from a lot: its buyer (card un-filed or deleted — plan §6), or a
-- lead. Idempotent: releasing what is already released is not an error, because
-- the offline queue may replay it.
create or replace function release_lot_claim(p_lot_id uuid, p_cert text, p_grader grader)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid   uuid := auth.uid();
  v_claim lot_claims;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if not is_team_member(lot_team(p_lot_id)) then raise exception 'not_member'; end if;
  select * into v_claim from lot_claims
   where lot_id = p_lot_id and grader = p_grader and cert = p_cert and state <> 'removed';
  if not found then
    return jsonb_build_object('outcome', 'not_claimed');
  end if;
  if v_claim.buyer_id <> v_uid and not is_team_lead(lot_team(p_lot_id)) then
    raise exception 'not_lead';
  end if;
  update lot_claims set state = 'removed', released_at = now(), released_by = v_uid
   where id = v_claim.id returning * into v_claim;
  return jsonb_build_object('outcome', 'released', 'claim', to_jsonb(v_claim));
end $$;

-- ────────────────────────────────────────────────────────────────────────────
-- Grants: authenticated users only. Supabase grants EXECUTE to anon by default.
-- ────────────────────────────────────────────────────────────────────────────
revoke execute on function
  new_join_code(), create_team(text, text), join_team(text, text), rotate_team_code(uuid),
  set_member_role(uuid, uuid, team_role), set_display_name(uuid, text),
  remove_team_member(uuid, uuid),
  claim_lot_scan(uuid, text, grader, timestamptz, text, uuid, boolean),
  release_lot_claim(uuid, text, grader),
  is_team_member(uuid), is_team_lead(uuid), lot_team(uuid), range_team(uuid)
from public, anon;

grant execute on function
  create_team(text, text), join_team(text, text), rotate_team_code(uuid),
  set_member_role(uuid, uuid, team_role), set_display_name(uuid, text),
  remove_team_member(uuid, uuid),
  claim_lot_scan(uuid, text, grader, timestamptz, text, uuid, boolean),
  release_lot_claim(uuid, text, grader),
  is_team_member(uuid), is_team_lead(uuid), lot_team(uuid), range_team(uuid)
to authenticated;
