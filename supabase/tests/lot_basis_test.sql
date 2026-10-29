-- pgTAP for a lot's CL/CY basis and a team's max-buy settings (2026-10-01).
-- Run: supabase test db
-- Plan: ~/.claude/plans/max-buy-for-teams-and-lot-basis.md (phase 1).
--
-- What is pinned here: a lead sets the team's skew/margin and nobody else can; a
-- basis only changes through set_lot_basis; a CY lot needs no Card Ladder account,
-- buckets and budgets on Courtyard's value, limits on Courtyard's identity, pends on
-- a cold cache and blocks on "no value"; EVERY claim records both sources plus the
-- phone's max buy; a 0.8 client's seven-argument call still resolves; and a switch
-- previews its impact, then re-counts without moving anybody's buy.

begin;
select plan(37);

-- ── Seed (as postgres) ──────────────────────────────────────────────────────
-- 1 Lead (CL)   2 Buyer (CL + CY)   3 Member with no Card Ladder account (CY)
-- 4 Member with no Courtyard account (2026-10-29: a CY lot needs one, C2)
insert into auth.users (id, email) values
  ('20000000-0000-0000-0000-000000000001', 'lead@basis.dev'),
  ('20000000-0000-0000-0000-000000000002', 'buyer@basis.dev'),
  ('20000000-0000-0000-0000-000000000003', 'nocl@basis.dev'),
  ('20000000-0000-0000-0000-000000000004', 'nocy@basis.dev');
insert into cardladder_credentials (user_id, encrypted_blob) values
  ('20000000-0000-0000-0000-000000000001', 'x'),
  ('20000000-0000-0000-0000-000000000002', 'x');
insert into courtyard_credentials (user_id, session) values
  ('20000000-0000-0000-0000-000000000002', '{}'),
  ('20000000-0000-0000-0000-000000000003', '{}');

-- A: both sources know it — CL $50, CY $150. (The disagreement is the point: which
--    bucket it lands in depends on the lot's basis.)
insert into cl_resolve_cache (grader, cert, profile_id, grade, grade_label, label, card_year) values
  ('psa', '9101', 'p-a', 'g9', '9', 'Curry Optic', '2022');
insert into price_cache (source_key, source, metric, price_cents, fetch_status, source_confidence, updated_at) values
  ('p-a:g9', 'cardladder', 'cl_value', 5000, 'ok', 4, now());

-- Courtyard's answers, as courtyard-price would have cached them.
--   9101       card A, $150 conf 3
--   9201-9204  card B (four slabs of one card), $80 conf 4 — Courtyard only
--   9301       404 (authoritative not_found)    9302  answered, no model price
--   9401       nothing cached yet
insert into cy_scan_cache (grader, cert, source_key, price_cents, source_confidence, grade, title,
                           subject, card_set, card_year, card_number, fetch_status) values
  ('psa', '9101', 'PSA_9101', 15000, 3, '9',  '2022 Optic #10 Curry (PSA g9)', 'Stephen Curry', 'Optic', '2022', '10', 'ok'),
  ('psa', '9201', 'PSA_9201', 8000,  4, '10', '2023 Prizm #136 Wembanyama',     'Victor Wembanyama', 'Prizm', '2023', '136', 'ok'),
  ('psa', '9202', 'PSA_9202', 8000,  4, '10', '2023 Prizm #136 Wembanyama',     'Victor Wembanyama', 'Prizm', '2023', '136', 'ok'),
  ('psa', '9203', 'PSA_9203', 8000,  4, '10', '2023 Prizm #136 Wembanyama',     'Victor Wembanyama', 'Prizm', '2023', '136', 'ok'),
  ('psa', '9204', 'PSA_9204', 8000,  4, '10', '2023 Prizm #136 Wembanyama',     'Victor Wembanyama', 'Prizm', '2023', '136', 'ok'),
  ('psa', '9301', 'PSA_9301', null,  null, null, null, null, null, null, null, 'not_found'),
  ('psa', '9302', 'PSA_9302', null,  null, '9', 'Unpriced', 'Someone', 'Set', '2020', '1', 'ok');

-- ── Team ────────────────────────────────────────────────────────────────────
set local role authenticated;
set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
select ok(set_config('t.team', create_team('Basis', 'Lead')->>'team_id', true) is not null, 'lead creates a team');
select ok(set_config('t.code', (select join_code from teams where id = current_setting('t.team')::uuid), true) is not null,
  'lead reads the join code');
set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated"}';
select lives_ok(format($$select join_team(%L, 'Buyer')$$, current_setting('t.code')), 'a buyer joins');
set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000003","role":"authenticated"}';
select lives_ok(format($$select join_team(%L, 'NoCL')$$, current_setting('t.code')), 'a member with no CL joins');
set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000004","role":"authenticated"}';
select lives_ok(format($$select join_team(%L, 'NoCY')$$, current_setting('t.code')), 'a member with no Courtyard joins');

-- ── Team max-buy settings (M2) ──────────────────────────────────────────────
select is((select max_buy_skew from teams), null, 'a new team has no max-buy settings: members keep their own');

set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
select lives_ok($$update teams set max_buy_skew = 0.40, max_buy_margin = 0.12 where id = current_setting('t.team')::uuid$$,
  'the lead sets skew and margin');
select throws_ok($$update teams set max_buy_margin = 1.5 where id = current_setting('t.team')::uuid$$,
  '23514', null, 'a margin over 100% is refused');

set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated"}';
update teams set max_buy_skew = 0 where id = current_setting('t.team')::uuid;
select is((select max_buy_skew from teams), 0.40::numeric, 'a buyer''s update changes nothing (RLS)');
select is((select max_buy_margin from teams), 0.12::numeric, 'members read the team''s margin');

-- ── Lots ────────────────────────────────────────────────────────────────────
set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
select lives_ok($$
  insert into lots (id, team_id, name, status, value_basis) values
    ('f9000000-0000-0000-0000-000000000001', current_setting('t.team')::uuid, 'CY show', 'active', 'cy');
  insert into lots (id, team_id, name, status) values
    ('f9000000-0000-0000-0000-000000000002', current_setting('t.team')::uuid, 'CL show', 'active');
  insert into lot_buy_ranges (id, lot_id, name, value_min_cents, value_max_cents, grade_min, grade_max,
                              max_cards, budget_cents, sort_order) values
    ('e9000000-0000-0000-0000-000000000001', 'f9000000-0000-0000-0000-000000000001', '$0–$100',   0,     10000, 1, 10, 400, 1000000, 0),
    ('e9000000-0000-0000-0000-000000000002', 'f9000000-0000-0000-0000-000000000001', '$100–$240', 10000, 24000, 1, 10, 150, 1000000, 1),
    ('e9000000-0000-0000-0000-000000000003', 'f9000000-0000-0000-0000-000000000002', 'Any',       0,     null,  1, 10, 400, 1000000, 0);
$$, 'a lead creates a CY lot and a CL lot');
select is((select value_basis from lots where id = 'f9000000-0000-0000-0000-000000000002'), 'cl',
  'a lot is CL unless the lead says otherwise');
select throws_ok($$update lots set value_basis = 'cy' where id = 'f9000000-0000-0000-0000-000000000002'$$,
  'P0001', 'use_set_lot_basis', 'a plain update cannot flip the basis (M4)');

-- ── A CY lot ────────────────────────────────────────────────────────────────
-- Courtyard data reaches only connected users (C2), and this claim is decided
-- from it — same gate a CL lot has. Raised before anything is written.
set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000004","role":"authenticated"}';
select throws_ok($$select claim_lot_scan('f9000000-0000-0000-0000-000000000001', '9201', 'psa')$$,
  'P0001', 'cy_not_connected', 'a member with no Courtyard account cannot claim into a CY lot');
set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000003","role":"authenticated"}';
select is(claim_lot_scan('f9000000-0000-0000-0000-000000000001', '9201', 'psa', p_max_buy_cents => 6100)->>'outcome',
  'confirmed', 'a member with NO Card Ladder account claims into a CY lot');
select is((select cy_price_cents from lot_claims where cert = '9201'), 8000, 'the claim carries the CY value');
select is((select basis_at_claim from lot_claims where cert = '9201'), 'cy', 'and the basis it was decided on');
select is((select max_buy_cents from lot_claims where cert = '9201'), 6100, 'and the phone''s max buy');
select is((select price_cents from lot_claims where cert = '9201'), null, 'no CL value is invented for a CL-less card');
select is((select label from lot_claims where cert = '9201'), '2023 Prizm #136 Wembanyama',
  'display copies come from Courtyard');

select is(claim_lot_scan('f9000000-0000-0000-0000-000000000001', '9202', 'psa')->>'outcome', 'confirmed', 'second copy');
select is(claim_lot_scan('f9000000-0000-0000-0000-000000000001', '9203', 'psa')->>'outcome', 'confirmed', 'third copy');
select is(claim_lot_scan('f9000000-0000-0000-0000-000000000001', '9204', 'psa')->>'reason', 'limit_reached',
  'the 3-limit counts Courtyard''s card identity on a CY lot');

select is(claim_lot_scan('f9000000-0000-0000-0000-000000000001', '9401', 'psa')->>'reason', 'pending_price',
  'nothing cached yet: pending, never a guess');
select is(claim_lot_scan('f9000000-0000-0000-0000-000000000001', '9301', 'psa')->>'reason', 'no_cy_value',
  'Courtyard''s 404 blocks with no_cy_value');
select is(claim_lot_scan('f9000000-0000-0000-0000-000000000001', '9302', 'psa')->>'reason', 'no_cy_value',
  'an answer with no model price is no value, not $0');

set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated"}';
-- The seven-argument call a 0.8 phone makes, by name.
select is(claim_lot_scan(p_lot_id => 'f9000000-0000-0000-0000-000000000001', p_cert => '9101', p_grader => 'psa',
                         p_scanned_at => now(), p_device_id => 'old-phone', p_range_id => null,
                         p_offline => false)->>'outcome', 'confirmed', 'a 0.8 client''s call still resolves');
select is((select lot_buy_range_id from lot_claims where cert = '9101' and lot_id = 'f9000000-0000-0000-0000-000000000001'),
  'e9000000-0000-0000-0000-000000000002'::uuid, 'CY $150 buckets as $100–$240 — CL''s $50 plays no part');
select is((select price_cents from lot_claims where cert = '9101' and lot_id = 'f9000000-0000-0000-0000-000000000001'), 5000,
  'the CL value is recorded too, from the cache');
select is((select used_cents::int from lot_range_usage where lot_buy_range_id = 'e9000000-0000-0000-0000-000000000001'), 24000,
  'usage spends Courtyard value on a CY lot');

-- ── A CL lot records Courtyard as well ──────────────────────────────────────
select is(claim_lot_scan('f9000000-0000-0000-0000-000000000002', '9101', 'psa')->>'outcome', 'confirmed', 'a CL claim');
select is((select cy_price_cents from lot_claims where cert = '9101' and lot_id = 'f9000000-0000-0000-0000-000000000002'), 15000,
  'a CL claim records the CY value so the lot can switch');

-- ── Switching (M4, M5) ──────────────────────────────────────────────────────
select throws_ok($$select set_lot_basis('f9000000-0000-0000-0000-000000000001', 'cl', true)$$,
  'P0001', 'not_lead', 'only the lead switches a basis');

set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
select is(set_lot_basis('f9000000-0000-0000-0000-000000000001', 'cl') - 'basis' - 'to',
  '{"claims": 4, "no_value": 3, "outside_range": 1, "over_budget": 0, "changed": false}'::jsonb,
  'a dry run names the impact: 3 slabs CL cannot value, 1 now outside its bucket');
select is((select value_basis from lots where id = 'f9000000-0000-0000-0000-000000000001'), 'cy',
  'and changes nothing');

select is((set_lot_basis('f9000000-0000-0000-0000-000000000001', 'cl', true))->>'changed', 'true', 'the commit switches');
select is((select cards || '/' || valued_cards || '/' || used_cents from lot_range_usage
            where lot_buy_range_id = 'e9000000-0000-0000-0000-000000000001'), '3/0/0',
  'the slabs CL cannot value keep their slots and add no dollars');

select * from finish();
rollback;
