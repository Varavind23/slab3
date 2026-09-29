-- Grade a lot can check, even when Card Ladder has no plain label (2026-09-25).
--
-- FOUND WITH REAL DATA. A CGC Pristine 10 (cert 4260611176) resolves to grade code
-- `g10pristine` with NO grade_label — `displayGrade` in _shared/cardladder.ts leaves
-- anything that is not a plain number unlabelled, on purpose (TODOS.md: "CGC
-- g10pristine collapses to 10"). claim_lot_scan read only the label, so the slab
-- was turned away as "grade unknown" from every bucket.
--
-- For a lot's GRADE RULES a Pristine 10 is at least a 10, so the number is taken
-- from the code when the label is absent: g10pristine → 10, g9.5 → 9.5. A code
-- with no number (authentic, altered) still has no grade and still cannot satisfy
-- a grade bound. This does NOT touch card_key or the display label — the known
-- gap in TODOS.md stays exactly as it was for everything else.

create or replace function cl_grade_number(p_label text, p_code text)
returns numeric language sql immutable as $$
  select case
    when p_label ~ '^\d+(\.\d+)?$' then p_label::numeric
    else nullif(substring(coalesce(p_code, '') from '^g(\d+(?:\.\d+)?)'), '')::numeric
  end;
$$;

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

revoke execute on function claim_lot_scan(uuid, text, grader, timestamptz, text, uuid, boolean) from public, anon;
grant  execute on function claim_lot_scan(uuid, text, grader, timestamptz, text, uuid, boolean) to authenticated;
