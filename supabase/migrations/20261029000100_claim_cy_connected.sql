-- claim_lot_scan: a Courtyard-basis lot needs the buyer's own Courtyard account
-- (2026-10-29; owner decisions C1/C2, spike/README.md §2g).
--
-- Since Courtyard put its scanner behind login, Courtyard values reach a user only
-- through their own connected account (20261029000000_courtyard_credentials.sql).
-- A CY-lot claim is decided from cy_scan_cache, so it gets the same gate a CL lot
-- has had since 0.8: raise `cy_not_connected`, which the app maps exactly like
-- `cl_not_connected`.
--
-- The body below is the LIVE definition (pg_get_functiondef from production,
-- 2026-10-29, byte-identical to this branch's migrations) with that one check
-- added — so every live fix carries over (memory:
-- claim-lot-scan-review-fixes-carry-into-09). CREATE OR REPLACE keeps the
-- existing grants. A replayed claim still returns before the check, so a buyer who
-- disconnects never loses a confirmed claim.

CREATE OR REPLACE FUNCTION public.claim_lot_scan(p_lot_id uuid, p_cert text, p_grader grader, p_scanned_at timestamp with time zone DEFAULT now(), p_device_id text DEFAULT NULL::text, p_range_id uuid DEFAULT NULL::uuid, p_offline boolean DEFAULT false, p_max_buy_cents integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- And a CY lot needs the buyer's own Courtyard account (2026-10-29, owner
  -- decision C2): Courtyard data goes only to connected users, and this claim is
  -- decided from it. Without the check an unconnected buyer's app never fills
  -- cy_scan_cache, so the claim sat in pending_price forever with nothing saying why.
  if v_basis = 'cy' and not exists (select 1 from courtyard_credentials where user_id = v_uid) then
    raise exception 'cy_not_connected';
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
end $function$;
