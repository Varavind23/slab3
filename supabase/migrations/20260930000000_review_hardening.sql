-- Review fixes for the Teams server (whole-codebase review, 2026-10-02). Live since
-- 0.8 (2026-09-28); each change below is a finding from that review, with the
-- failure it stops. Dated 2026-09-30 so it lands BEFORE the 0.9 migrations
-- (20261001*), which are not live yet.
--
-- Section 6 is for the Edge Functions (cardladder-price / cardladder-sales). Apply
-- this migration BEFORE deploying them: they call spend_cardladder_budget.
--
-- 0.9 NOTE: 20261001000000 drops and re-creates claim_lot_scan. Section 5's
-- replay-first block and cert check MUST be carried into that new body, or 0.9
-- silently undoes them. Every other section here is untouched by 0.9.

-- ── 1. A closed lot keeps its record ───────────────────────────────────────
-- release_lot_claim ignored the lot's status, so a buyer deleting the slabs of a
-- lot closed weeks ago (sold, shipped) flipped each claim to `removed` and the
-- closed lot's buys disappeared from Team activity. A buyer's release of a closed
-- lot is now answered `not_claimed` — which every client already counts as done,
-- so nothing retries — and the claim stays. A lead can still release (to clean up
-- over-limit rows).
create or replace function release_lot_claim(p_lot_id uuid, p_cert text, p_grader grader)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid   uuid := auth.uid();
  v_claim lot_claims;
  v_status lot_status;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if not is_team_member(lot_team(p_lot_id)) then raise exception 'not_member'; end if;
  select status into v_status from lots where id = p_lot_id;
  if v_status <> 'active' and not is_team_lead(lot_team(p_lot_id)) then
    return jsonb_build_object('outcome', 'not_claimed', 'reason', 'lot_closed');
  end if;
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

-- ── 2. Join codes cannot be guessed ────────────────────────────────────────
-- Six characters (≈1.07e9 codes), no expiry and no attempt limit: any signed-in
-- account could walk the space through PostgREST and land in a team (every lot,
-- claim, CL value and buyer name). And `invalid_code` was decided before
-- `already_in_team`, so a member could test codes without joining at all.
--
-- A failed guess is COUNTED, so it cannot be raised — a raise rolls back the
-- insert that counts it. Wrong code and too many guesses are therefore RETURNED
-- as {"error": …}; the app reads them (TeamStore.join). The 0.8 app cannot, and
-- shows a generic error for a wrong code until it updates (owner decision D3,
-- 2026-10-02). Errors that count nothing (`not_authenticated`, `already_in_team`)
-- still raise as before.
create table join_attempts (
  user_id      uuid not null references auth.users(id) on delete cascade,
  attempted_at timestamptz not null default now()
);
create index join_attempts_user_idx on join_attempts (user_id, attempted_at);
-- RLS on, no policies: only the security definer function below touches it.
alter table join_attempts enable row level security;
revoke all on join_attempts from anon, authenticated;

create or replace function join_attempt_limit() returns int language sql immutable as $$ select 10 $$;

create or replace function join_team(p_code text, p_display_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_team teams;
  v_mine uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  -- Already on a team: decided before the code is looked at, so the answer says
  -- nothing about whether the code exists. Re-entering your own team's code is
  -- still a no-op (a retried request after a dropped connection).
  select team_id into v_mine from team_members where user_id = v_uid limit 1;
  if v_mine is not null then
    if exists (select 1 from teams where id = v_mine and join_code = v_code) then
      return jsonb_build_object('team_id', v_mine);
    end if;
    raise exception 'already_in_team';
  end if;
  delete from join_attempts where user_id = v_uid and attempted_at < now() - interval '1 day';
  if (select count(*) from join_attempts
       where user_id = v_uid and attempted_at > now() - interval '1 hour') >= join_attempt_limit() then
    return jsonb_build_object('error', 'too_many_attempts');
  end if;
  select * into v_team from teams where join_code = v_code;
  if not found then
    insert into join_attempts (user_id) values (v_uid);
    return jsonb_build_object('error', 'invalid_code');
  end if;
  insert into team_members (team_id, user_id, role, display_name)
    values (v_team.id, v_uid, 'buyer', trim(p_display_name));
  return jsonb_build_object('team_id', v_team.id);
end $$;

revoke execute on function join_attempt_limit() from public, anon;

-- ── 3. Removing someone means they are out ─────────────────────────────────
-- (a) The lead check ran BEFORE the team lock. Two leads of a two-person team
-- removing each other at once: the second, already removed by the first, still
-- passed, saw one member left, and deleted the whole team — every lot and claim
-- cascading with it. The same pre-lock check let a just-demoted lead change roles.
-- Both now check after the lock, against what is committed by then.
-- (b) A removed member could rejoin at once with the unchanged code. A lead
-- removing someone else now gets the team a new code (leaving yourself does not).
create or replace function remove_team_member(p_team_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform pg_advisory_xact_lock(hashtextextended('team:' || p_team_id::text, 0));
  if p_user_id <> v_uid and not is_team_lead(p_team_id) then raise exception 'not_lead'; end if;
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
  if p_user_id <> v_uid then
    update teams set join_code = new_join_code() where id = p_team_id;
  end if;
end $$;

create or replace function set_member_role(p_team_id uuid, p_user_id uuid, p_role team_role)
returns void language plpgsql security definer set search_path = public as $$
begin
  -- Serialise role changes per team so two leads demoting each other at once
  -- cannot both pass the last-lead check below — and check the caller is still
  -- a lead AFTER waiting for the lock, not before.
  perform pg_advisory_xact_lock(hashtextextended('team:' || p_team_id::text, 0));
  if not is_team_lead(p_team_id) then raise exception 'not_lead'; end if;
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

-- ── 4. A bucket holding buys stays put ─────────────────────────────────────
-- Only the app stopped a lead deleting a bucket with claims in it, from its last
-- load — a buy landing after that load was not protected. The server then set
-- those claims' bucket to null: their dollars fell out of every bucket's totals
-- and a re-added bucket started at $0 used, so the team could overspend. A lead
-- could also move a bucket to ANOTHER lot by updating lot_id, after which that
-- lot's claims filled the moved bucket. Both are refused here. Deleting the whole
-- lot (or team) still cascades: the lot row is already gone when its buckets go.
create or replace function lot_buy_ranges_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    if new.lot_id is distinct from old.lot_id then raise exception 'range_lot_fixed'; end if;
    return new;
  end if;
  if exists (select 1 from lots where id = old.lot_id) and exists (
    select 1 from lot_claims
    where lot_buy_range_id = old.id and state in ('confirmed', 'over_limit')
  ) then
    raise exception 'range_has_buys';
  end if;
  return old;
end $$;

create trigger lot_buy_ranges_guard
  before update of lot_id or delete on lot_buy_ranges
  for each row execute function lot_buy_ranges_guard();

-- ── 5. claim_lot_scan: replay first, and only real certs ───────────────────
-- Unchanged from 20260925130000 except the block marked "Review 2026-10-02".
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
  -- Review 2026-10-02: a slab THIS buyer already holds in this lot is answered
  -- first — before the lot's status and before the CL connection. A claim whose
  -- reply was lost, retried after the lead closed the lot, used to come back
  -- "lot_closed", and the phone took a card the server still counts out of the lot.
  -- No lock needed: a row found here is committed and this buyer's; a concurrent
  -- first claim still goes through the locked path below.
  select * into v_existing from lot_claims
   where lot_id = p_lot_id and grader = p_grader and cert = p_cert
     and state <> 'removed' and buyer_id = v_uid;
  if found then
    return jsonb_build_object('outcome', v_existing.state::text, 'claim', to_jsonb(v_existing),
                              'replayed', true);
  end if;
  -- Digits only. A cert with a space, a full-width digit or any other odd shape
  -- would dodge the duplicate check as a "different" slab. (Length is the app's
  -- rule — CertParser — and pgTAP fixtures use short certs.)
  if p_cert !~ '^[0-9]{1,12}$' then
    return jsonb_build_object('outcome', 'blocked', 'reason', 'bad_cert');
  end if;
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

  v_grade := cl_grade_number(v_res.grade_label, v_res.grade);
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
  -- The lot's buyer may bucket the card differently than CL Value does. A $0 floor is
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

-- Backstop for section 5. Live had 11 claims, all 7–10 digits, when this was written.
alter table lot_claims add constraint lot_claims_cert_format check (cert ~ '^[0-9]{1,12}$');

-- ── 6. The Card Ladder budget is counted atomically ─────────────────────────
-- cardladder-price/-sales read request_count, called Card Ladder, then wrote
-- count+1. N requests in flight together (price and sales for one card, two
-- builds on one account) all read k and all wrote k+1, so the 200/day cap was
-- not enforced. And a failed read reset the day's count to 1. One statement now
-- increments and returns the new count; the function refuses the call once it
-- is past the cap. Service role only — RLS on scrape_budget is deny-all.
create or replace function spend_cardladder_budget(p_user_id uuid, p_cap int)
returns int language sql set search_path = public as $$
  insert into scrape_budget (source, user_id, window_start, request_count, cap)
  values ('cardladder', p_user_id, date_trunc('day', now() at time zone 'utc') at time zone 'utc', 1, p_cap)
  on conflict (source, user_id, window_start)
  do update set request_count = scrape_budget.request_count + 1, cap = excluded.cap
  returning request_count;
$$;
revoke execute on function spend_cardladder_budget(uuid, int) from public, anon, authenticated;
grant execute on function spend_cardladder_budget(uuid, int) to service_role;
