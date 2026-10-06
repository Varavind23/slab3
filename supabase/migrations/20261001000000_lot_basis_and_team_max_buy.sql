-- A lot priced on Card Ladder OR Courtyard, and a team's max-buy settings
-- (owner decisions M1–M6, 2026-10-01; ~/.claude/plans/max-buy-for-teams-and-lot-basis.md).
--
-- WHY. Until now every dollar in a lot was CL Value at claim: buckets matched on it,
-- budgets spent it, the 3-limit counted CL's identity, and a claim needed a connected
-- Card Ladder account. The owner wants a lead to run a lot on Courtyard instead —
-- "CL has no relevance anymore" on such a lot — AND to be able to switch an existing
-- lot either way after buys are in it.
--
-- HOW. Every claim now records BOTH sources' values at claim time, each read from the
-- server's own caches (nothing is fetched here). `lots.value_basis` only chooses which
-- of the two the server matches, budgets and limits on, so a switch re-reads columns
-- that are already filled rather than reprocessing anything, and nobody's buy moves.
--
-- ADDITIVE AND SAFE FOR 0.8 CLIENTS. Every existing lot stays 'cl', and a CL lot
-- behaves exactly as before. `price_cents` keeps its meaning (CL Value at claim) on
-- every claim, so a 0.8 phone reading it on a CY lot shows a correctly labelled CL
-- figure. claim_lot_scan gains one trailing DEFAULTED argument, so a 0.8 call with
-- the old seven named arguments still resolves.

-- ── Team max-buy settings (M2) ─────────────────────────────────────────────
-- nil = the lead has not set them, and members keep their phone's own defaults.
-- The lead writes them directly: `teams_rename` already limits UPDATE to the lead,
-- and the column grant below is what lets these two through (teams only granted
-- `name` until now, so the join code stays RPC-only).
alter table teams
  add column max_buy_skew   numeric check (max_buy_skew   is null or max_buy_skew   between 0 and 1),
  add column max_buy_margin numeric check (max_buy_margin is null or max_buy_margin between 0 and 1);
grant update (max_buy_skew, max_buy_margin) on teams to authenticated;

-- ── The lot's basis (M3) ───────────────────────────────────────────────────
alter table lots
  add column value_basis text not null default 'cl' check (value_basis in ('cl', 'cy'));

-- A basis change goes through set_lot_basis (M4: never one tap, and it fills in any
-- values the claims lack first). `lots_write` would otherwise let a lead flip it with a
-- plain update, so a trigger refuses any change that did not come from that function.
create or replace function lots_basis_guard()
returns trigger language plpgsql as $$
begin
  if new.value_basis is distinct from old.value_basis
     and coalesce(current_setting('slabs.basis_change', true), '') <> 'on' then
    raise exception 'use_set_lot_basis';
  end if;
  return new;
end $$;

create trigger lots_basis_guard before update on lots
  for each row execute function lots_basis_guard();

-- ── Claims carry both values ───────────────────────────────────────────────
-- A CY claim by a member with no Card Ladder account has no CL identity at all.
alter table lot_claims
  alter column cl_source_key drop not null,
  alter column grade_code    drop not null;

alter table lot_claims
  add column cy_price_cents int,   -- Courtyard value at claim; NULL = none ("not applicable" is never $0)
  add column cy_confidence  int,   -- Courtyard's own 1–5
  add column cy_card_key    text,  -- the 3-limit identity on a CY lot, see cy_card_key()
  -- The figure the buyer's PHONE showed. Display only: never read by any decision here.
  add column max_buy_cents  int check (max_buy_cents is null or max_buy_cents >= 0),
  add column basis_at_claim text check (basis_at_claim is null or basis_at_claim in ('cl', 'cy'));

update lot_claims set basis_at_claim = 'cl' where basis_at_claim is null;

create index lot_claims_cy_identity_idx on lot_claims (lot_id, cy_card_key) where state = 'confirmed';

-- Courtyard has NO card-level id: `source_key` is per SLAB ("PSA_96679812"). The
-- 3-of-one-card rule on a CY lot therefore keys on the card's own description, with
-- card_key's normalisation (lowercase, runs of anything else → '-'). Lossy in the same
-- way card_key is — fine inside one lot, never a cache key. NULL when Courtyard gave no
-- identity to build it from.
create or replace function cy_card_key(p_grader grader, p_year text, p_set text,
                                       p_number text, p_subject text, p_grade text)
returns text language sql immutable as $$
  select case when coalesce(p_subject, p_set) is null then null else
    regexp_replace(lower(concat_ws(':', p_grader::text, coalesce(p_year, ''), coalesce(p_set, ''),
                                   coalesce(p_number, ''), coalesce(p_subject, ''), coalesce(p_grade, ''))),
                   '[^a-z0-9:]+', '-', 'g')
  end;
$$;

-- The value a claim carries in a basis. One definition, read by the usage view and
-- by claim_lot_scan's room check, so the two can never disagree.
create or replace function lot_claim_value(p_cl int, p_cy int, p_basis text)
returns int language sql immutable as $$
  select case when p_basis = 'cy' then p_cy else p_cl end;
$$;

-- Existing claims gain the Courtyard value the cache holds NOW. It is not literally
-- "at claim" (the cache is a 24h answer), but it is the closest real figure there is,
-- and without it no existing lot could switch to CY with numbers.
update lot_claims c
   set cy_price_cents = y.price_cents,
       cy_confidence  = y.source_confidence,
       cy_card_key    = cy_card_key(y.grader, y.card_year, y.card_set, y.card_number, y.subject, y.grade)
  from cy_scan_cache y
 where y.grader = c.grader and y.cert = c.cert and y.fetch_status = 'ok'
   and c.cy_price_cents is null;

-- ── Usage follows the lot's CURRENT basis ──────────────────────────────────
-- `valued_cards` is how many of `cards` have a value in that basis: a claim with none
-- still holds its slot but adds nothing to the dollars, and the app says so.
create or replace view lot_range_usage with (security_invoker = true) as
  select c.lot_id,
         c.lot_buy_range_id,
         count(*)::int as cards,
         coalesce(sum(lot_claim_value(c.price_cents, c.cy_price_cents, l.value_basis)), 0)::bigint as used_cents,
         count(lot_claim_value(c.price_cents, c.cy_price_cents, l.value_basis))::int as valued_cards
    from lot_claims c
    join lots l on l.id = c.lot_id
   where c.state = 'confirmed'
   group by c.lot_id, c.lot_buy_range_id;

-- ── claim_lot_scan v3 ──────────────────────────────────────────────────────
drop function claim_lot_scan(uuid, text, grader, timestamptz, text, uuid, boolean);

create function claim_lot_scan(
  p_lot_id        uuid,
  p_cert          text,
  p_grader        grader,
  p_scanned_at    timestamptz default now(),
  p_device_id     text default null,
  p_range_id      uuid default null,
  p_offline       boolean default false,
  p_max_buy_cents int default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid        uuid := auth.uid();
  v_lot        lots;
  v_basis      text;
  -- Card Ladder's side, whatever the basis.
  v_res        cl_resolve_cache;
  v_has_res    boolean := false;
  v_key        text;
  v_cl_price   int;
  v_cl_conf    int;
  v_cl_state   text := 'missing';   -- missing | none | ok
  v_priced_at  timestamptz;
  v_status     fetch_status;
  -- Courtyard's side, whatever the basis.
  v_cy         cy_scan_cache;
  v_cy_state   text := 'missing';
  v_cy_key     text;
  -- The basis's answer.
  v_price      int;
  v_conf       int;
  v_grade      numeric;
  v_year       int;
  v_limit_key  text;
  v_label      text;
  v_player     text;
  v_set        text;
  v_card_year  text;
  v_number     text;
  v_image      text;
  v_grade_lbl  text;
  v_max_buy    int := case when p_max_buy_cents >= 0 then p_max_buy_cents end;
  -- As before.
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
  v_basis := v_lot.value_basis;
  -- Carried from the live 20260930000000 (§5, review 2026-10-02) — this function is
  -- dropped and recreated here, so those two fixes must be restated or they vanish:
  -- (a) a slab THIS buyer already holds in this lot is answered first — before the
  -- lot's status and the CL connection — so a claim retried after a lost reply and a
  -- lead's close still comes back as the buy it is, not "lot_closed";
  -- (b) digits only: a padded or full-width cert would dodge the duplicate check.
  select * into v_existing from lot_claims
   where lot_id = p_lot_id and grader = p_grader and cert = p_cert
     and state <> 'removed' and buyer_id = v_uid;
  if found then
    return jsonb_build_object('outcome', v_existing.state::text, 'claim', to_jsonb(v_existing),
                              'replayed', true);
  end if;
  if p_cert !~ '^[0-9]{1,12}$' then
    return jsonb_build_object('outcome', 'blocked', 'reason', 'bad_cert');
  end if;
  -- Only a CL lot needs the buyer's own Card Ladder account. A CY lot never asks CL
  -- anything it needs, so members without a paid CL account can buy into one.
  if v_basis = 'cl' and not exists (select 1 from cardladder_credentials where user_id = v_uid) then
    raise exception 'cl_not_connected';
  end if;
  if v_lot.status <> 'active' then
    return jsonb_build_object('outcome', 'blocked', 'reason', 'lot_closed');
  end if;

  -- ── Both sources, from the server's own caches ───────────────────────────
  select * into v_res from cl_resolve_cache where grader = p_grader and cert = p_cert;
  if found then
    v_has_res := true;
    v_key := v_res.profile_id || ':' || v_res.grade;   -- = clSourceKey (_shared/cardladder.ts)
    select price_cents, source_confidence, fetch_status, updated_at
      into v_cl_price, v_cl_conf, v_status, v_priced_at
      from price_cache
     where source_key = v_key and source = 'cardladder' and metric = 'cl_value';
    if found and v_priced_at >= now() - lot_price_max_age() and v_status in ('ok', 'not_found') then
      v_cl_state := case when v_status = 'not_found' or v_cl_price is null then 'none' else 'ok' end;
    end if;
    if v_cl_state <> 'ok' then v_cl_price := null; v_cl_conf := null; end if;
  end if;

  -- Cached under the grader the phone GUESSED (courtyard-price keys on what it was
  -- asked), which is the same guess the phone sends here. A 502 is never cached, so
  -- an outage reads as missing → pending, never as "no value".
  select * into v_cy from cy_scan_cache
   where grader = p_grader and cert = p_cert and fetched_at >= now() - lot_price_max_age();
  if found then
    v_cy_state := case when v_cy.fetch_status = 'ok' and v_cy.price_cents is not null then 'ok' else 'none' end;
    v_cy_key := cy_card_key(v_cy.grader, v_cy.card_year, v_cy.card_set, v_cy.card_number,
                            v_cy.subject, v_cy.grade);
  end if;

  -- ── The basis decides ────────────────────────────────────────────────────
  if v_basis = 'cl' then
    if v_cl_state = 'missing' then
      return jsonb_build_object('outcome', 'pending', 'reason', 'pending_price');
    end if;
    if v_cl_state = 'none' then
      -- Card Ladder answered and has no value. A value range cannot be checked
      -- against nothing, and inventing one is the thing this app never does.
      return jsonb_build_object('outcome', 'blocked', 'reason', 'no_cl_value');
    end if;
    v_price := v_cl_price; v_conf := v_cl_conf; v_limit_key := v_key;
    v_grade := cl_grade_number(v_res.grade_label, v_res.grade);
    v_year  := cl_year(v_res.card_year);
    v_label := v_res.label; v_player := v_res.player; v_set := v_res.card_set;
    v_card_year := v_res.card_year; v_number := v_res.card_number; v_image := v_res.image_url;
    v_grade_lbl := v_res.grade_label;
  else
    if v_cy_state = 'missing' then
      return jsonb_build_object('outcome', 'pending', 'reason', 'pending_price');
    end if;
    if v_cy_state = 'none' then
      return jsonb_build_object('outcome', 'blocked', 'reason', 'no_cy_value');
    end if;
    v_price := v_cy.price_cents; v_conf := v_cy.source_confidence;
    -- No identity to build a card key from: the slab is its own key, so the 3-limit
    -- cannot fire on a guess. Courtyard answers that come back priced but unnamed are
    -- not something we have seen; this keeps the rule honest if one ever does.
    v_limit_key := coalesce(v_cy_key, 'slab:' || p_grader::text || ':' || p_cert);
    v_grade := cl_grade_number(v_cy.grade, null);
    v_year  := cl_year(v_cy.card_year);
    -- The long assembled title, like CL's label; the short name in player.
    v_label := v_cy.title; v_player := v_cy.subject; v_set := v_cy.card_set;
    v_card_year := v_cy.card_year; v_number := v_cy.card_number; v_image := v_cy.image_url;
    v_grade_lbl := v_cy.grade;
  end if;

  -- ── Serialise everything about this card in this lot ─────────────────────
  perform pg_advisory_xact_lock(hashtextextended('lot:' || p_lot_id::text || '|' || v_limit_key, 0));

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

  -- The 3-limit, on the basis's own identity.
  select count(*) into v_copies from lot_claims
   where lot_id = p_lot_id and state = 'confirmed'
     and (case when v_basis = 'cy' then cy_card_key else cl_source_key end) = v_limit_key;
  if v_copies >= 3 then
    if p_offline then
      insert into lot_claims (lot_id, cert, grader, cl_source_key, grade_code, grade_label,
        price_cents, cl_confidence, cy_price_cents, cy_confidence, cy_card_key, max_buy_cents,
        basis_at_claim, label, player, card_set, card_year, card_number, image_url,
        buyer_id, state, warn_reasons, scanned_at, device_id)
      values (p_lot_id, p_cert, p_grader, v_key, v_res.grade, v_grade_lbl,
        v_cl_price, v_cl_conf, case when v_cy_state = 'ok' then v_cy.price_cents end,
        case when v_cy_state = 'ok' then v_cy.source_confidence end, v_cy_key, v_max_buy,
        v_basis, v_label, v_player, v_set, v_card_year, v_number, v_image,
        v_uid, 'over_limit', array['limit_reached'], p_scanned_at, p_device_id)
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
         where c.lot_id = p_lot_id and c.state = 'confirmed'
           and (case when v_basis = 'cy' then c.cy_card_key else c.cl_source_key end) = v_limit_key));
  end if;

  -- ── Which ranges does this card fit? ─────────────────────────────────────
  -- Unknown grade can never satisfy a grade bound (every range has one).
  -- Unknown year or confidence passes that criterion and WARNS instead. Confidence
  -- is the basis source's own 1–5.
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
    -- `cl_confidence` keeps its key for 0.8 clients; it is the BASIS source's confidence.
    return jsonb_build_object('outcome', 'blocked', 'reason', 'no_matching_range',
      'failed', v_fail, 'price_cents', v_price, 'grade', v_grade_lbl,
      'cl_confidence', v_conf, 'confidence', v_conf, 'basis', v_basis, 'year', v_year);
  end if;

  -- Lock every candidate range in id order, THEN measure room.
  for r in select unnest(v_matching) as id loop
    perform pg_advisory_xact_lock(hashtextextended('range:' || r.id::text, 0));
  end loop;

  for r in
    select b.*, coalesce(t.n, 0) as used_cards, coalesce(t.cents, 0) as used_cents
      from lot_buy_ranges b
      left join lateral (
        select count(*) as n,
               sum(lot_claim_value(price_cents, cy_price_cents, v_basis))::bigint as cents
          from lot_claims
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
        price_cents, cl_confidence, cy_price_cents, cy_confidence, cy_card_key, max_buy_cents,
        basis_at_claim, label, player, card_set, card_year, card_number, image_url,
        buyer_id, state, warn_reasons, scanned_at, device_id)
      values (p_lot_id, p_cert, p_grader, v_key, v_res.grade, v_grade_lbl,
        v_cl_price, v_cl_conf, case when v_cy_state = 'ok' then v_cy.price_cents end,
        case when v_cy_state = 'ok' then v_cy.source_confidence end, v_cy_key, v_max_buy,
        v_basis, v_label, v_player, v_set, v_card_year, v_number, v_image,
        v_uid, 'over_limit', array[v_full], p_scanned_at, p_device_id)
      returning * into v_claim;
      return jsonb_build_object('outcome', 'over_limit', 'reason', v_full, 'claim', to_jsonb(v_claim));
    end if;
    return jsonb_build_object('outcome', 'blocked', 'reason', v_full);
  end if;

  if cardinality(v_room_ids) > 1 then
    -- The buyer picks (owner decision). Nothing is held in the meantime.
    return jsonb_build_object('outcome', 'choose_range', 'candidates', v_room,
      'price_cents', v_price, 'basis', v_basis);
  end if;

  select * into v_range from lot_buy_ranges where id = v_room_ids[1];

  if v_year is null then v_warn := array_append(v_warn, 'year_unknown'); end if;
  if v_conf is null then v_warn := array_append(v_warn, 'confidence_unknown'); end if;
  -- Near an edge: within 5% or $5, whichever is larger, of either value bound.
  if (v_range.value_min_cents > 0
      and v_price - v_range.value_min_cents < greatest(500, v_price / 20))
     or (v_range.value_max_cents is not null
         and v_range.value_max_cents - v_price <= greatest(500, v_price / 20)) then
    v_warn := array_append(v_warn, 'near_range_edge');
  end if;

  insert into lot_claims (lot_id, lot_buy_range_id, cert, grader, cl_source_key, grade_code,
    grade_label, price_cents, cl_confidence, cy_price_cents, cy_confidence, cy_card_key,
    max_buy_cents, basis_at_claim, label, player, card_set, card_year, card_number,
    image_url, buyer_id, state, warn_reasons, scanned_at, device_id)
  values (p_lot_id, v_range.id, p_cert, p_grader, v_key, v_res.grade, v_grade_lbl,
    v_cl_price, v_cl_conf, case when v_cy_state = 'ok' then v_cy.price_cents end,
    case when v_cy_state = 'ok' then v_cy.source_confidence end, v_cy_key,
    v_max_buy, v_basis, v_label, v_player, v_set, v_card_year, v_number,
    v_image, v_uid, 'confirmed', v_warn, p_scanned_at, p_device_id)
  returning * into v_claim;

  return jsonb_build_object(
    'outcome', 'confirmed',
    'claim', to_jsonb(v_claim),
    'basis', v_basis,
    'range', jsonb_build_object('range_id', v_range.id, 'name', v_range.name),
    'copies', v_copies + 1,
    'range_cards', (select count(*) from lot_claims where lot_buy_range_id = v_range.id and state = 'confirmed'),
    'range_cents', (select coalesce(sum(lot_claim_value(price_cents, cy_price_cents, v_basis)), 0)
                      from lot_claims where lot_buy_range_id = v_range.id and state = 'confirmed'),
    'warn_reasons', to_jsonb(v_warn));
end $$;

revoke execute on function claim_lot_scan(uuid, text, grader, timestamptz, text, uuid, boolean, int) from public, anon;
grant  execute on function claim_lot_scan(uuid, text, grader, timestamptz, text, uuid, boolean, int) to authenticated;

-- ── set_lot_basis: the deliberate switch (M4, M5) ──────────────────────────
-- Lead only. With p_commit = false it changes NOTHING and returns what a switch would
-- do, which is what the app's confirmation sheet shows; with true it first fills in any
-- target-basis values the claims lack from the caches (nothing is fetched), then flips
-- the basis. Nobody's buy is moved or released: a claim keeps its bucket, and one with
-- no value in the new basis keeps its slot and adds nothing to the dollars.
create or replace function set_lot_basis(p_lot_id uuid, p_basis text, p_commit boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_lot     lots;
  v_impact  jsonb;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if p_basis not in ('cl', 'cy') then raise exception 'bad_basis'; end if;
  select * into v_lot from lots where id = p_lot_id;
  if not found or not is_team_lead(v_lot.team_id) then raise exception 'not_lead'; end if;
  if v_lot.value_basis = p_basis then
    return jsonb_build_object('changed', false, 'basis', p_basis);
  end if;

  -- Every claim in the lot, with the value it WOULD carry in the new basis: what it
  -- already has, else what the cache holds now.
  with c as (
    select lc.id, lc.state, lc.lot_buy_range_id,
           case when p_basis = 'cy' then coalesce(lc.cy_price_cents, y.price_cents)
                else coalesce(lc.price_cents, p.price_cents) end as value
      from lot_claims lc
      left join cy_scan_cache y
             on p_basis = 'cy' and y.grader = lc.grader and y.cert = lc.cert and y.fetch_status = 'ok'
      left join cl_resolve_cache rc
             on p_basis = 'cl' and rc.grader = lc.grader and rc.cert = lc.cert
      left join price_cache p
             on p.source_key = rc.profile_id || ':' || rc.grade and p.source = 'cardladder'
            and p.metric = 'cl_value' and p.fetch_status = 'ok'
     where lc.lot_id = p_lot_id and lc.state in ('confirmed', 'over_limit')
  ), b as (
    select r.id, r.max_cards, r.budget_cents, r.value_min_cents, r.value_max_cents,
           count(c.id) filter (where c.state = 'confirmed') as cards,
           coalesce(sum(c.value) filter (where c.state = 'confirmed'), 0) as cents
      from lot_buy_ranges r
      left join c on c.lot_buy_range_id = r.id
     where r.lot_id = p_lot_id
     group by r.id
  )
  select jsonb_build_object(
    'claims',        (select count(*) from c),
    'no_value',      (select count(*) from c where value is null),
    'outside_range', (select count(*) from c join lot_buy_ranges r on r.id = c.lot_buy_range_id
                       where c.value is not null
                         and (c.value < r.value_min_cents
                              or (r.value_max_cents is not null and c.value >= r.value_max_cents))),
    'over_budget',   (select count(*) from b where cents > budget_cents))
    into v_impact;

  if not p_commit then
    return v_impact || jsonb_build_object('changed', false, 'basis', v_lot.value_basis, 'to', p_basis);
  end if;

  if p_basis = 'cy' then
    update lot_claims lc
       set cy_price_cents = y.price_cents,
           cy_confidence  = y.source_confidence,
           cy_card_key    = cy_card_key(y.grader, y.card_year, y.card_set, y.card_number, y.subject, y.grade)
      from cy_scan_cache y
     where lc.lot_id = p_lot_id and lc.cy_price_cents is null
       and y.grader = lc.grader and y.cert = lc.cert and y.fetch_status = 'ok';
  else
    update lot_claims lc
       set price_cents   = p.price_cents,
           cl_confidence = p.source_confidence,
           cl_source_key = rc.profile_id || ':' || rc.grade,
           grade_code    = coalesce(lc.grade_code, rc.grade)
      from cl_resolve_cache rc
      join price_cache p
        on p.source_key = rc.profile_id || ':' || rc.grade and p.source = 'cardladder'
       and p.metric = 'cl_value' and p.fetch_status = 'ok'
     where lc.lot_id = p_lot_id and lc.price_cents is null
       and rc.grader = lc.grader and rc.cert = lc.cert;
  end if;

  perform set_config('slabs.basis_change', 'on', true);
  update lots set value_basis = p_basis, updated_at = now() where id = p_lot_id;
  perform set_config('slabs.basis_change', 'off', true);

  return v_impact || jsonb_build_object('changed', true, 'basis', p_basis);
end $$;

revoke execute on function set_lot_basis(uuid, text, boolean) from public, anon;
grant  execute on function set_lot_basis(uuid, text, boolean) to authenticated;
