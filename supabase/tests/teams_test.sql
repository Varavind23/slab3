-- pgTAP tests for teams, lots, buy ranges and claim_lot_scan (2026-09-25).
-- Run: supabase test db
-- Plan: ~/.claude/plans/read-teams-md-lets-first-harmonic-horizon.md (phase 0).
--
-- What is pinned here: membership is the gate (RLS + RPC checks), leads write and
-- buyers do not, claims go through the RPC only, and every claim outcome —
-- confirmed, idempotent replay, duplicate cert, the 3-limit keyed on Card
-- Ladder's identity (not card_key), offline over_limit, no matching range with
-- the failed criterion named, pending on a cold cache, no CL value, choose_range
-- on overlap, and both range caps. The CONCURRENT 3-limit is not testable inside
-- one transaction; it lives in supabase/tests/concurrency/claim_race.sh.

begin;
select plan(49);

-- ── Seed (as postgres) ──────────────────────────────────────────────────────
-- 1 Lead  2 Justin (buyer)  3 Sam (buyer)  4 outsider  5 member with no CL
insert into auth.users (id, email) values
  ('10000000-0000-0000-0000-000000000001', 'lead@test.dev'),
  ('10000000-0000-0000-0000-000000000002', 'justin@test.dev'),
  ('10000000-0000-0000-0000-000000000003', 'sam@test.dev'),
  ('10000000-0000-0000-0000-000000000004', 'outsider@test.dev'),
  ('10000000-0000-0000-0000-000000000005', 'nocl@test.dev');
insert into cardladder_credentials (user_id, encrypted_blob) values
  ('10000000-0000-0000-0000-000000000001', 'x'),
  ('10000000-0000-0000-0000-000000000002', 'x'),
  ('10000000-0000-0000-0000-000000000003', 'x'),
  ('10000000-0000-0000-0000-000000000004', 'x');

-- Card Ladder's answers, as cardladder-price would have cached them.
--   X: one card at PSA 9, $50, conf 4 — five different slabs (certs 5001-5005)
--   Y: grade 6          Z: $150, conf 5        W: $50, a second identity
--   V: $50, a third     N: CL has no value     P: resolved, never priced
insert into cl_resolve_cache (grader, cert, profile_id, grade, grade_label, label, card_year) values
  ('psa', '5001', 'p-x', 'g9', '9', 'Charizard', '1999'),
  ('psa', '5002', 'p-x', 'g9', '9', 'Charizard', '1999'),
  ('psa', '5003', 'p-x', 'g9', '9', 'Charizard', '1999'),
  ('psa', '5004', 'p-x', 'g9', '9', 'Charizard', '1999'),
  ('psa', '5005', 'p-x', 'g9', '9', 'Charizard', '1999'),
  ('psa', '6001', 'p-y', 'g6', '6', 'Blastoise', '1999'),
  ('psa', '7001', 'p-z', 'g9', '9', 'Lugia', '2000'),
  ('psa', '7101', 'p-w', 'g9', '9', 'Mew', null),
  ('psa', '7201', 'p-v', 'g9', '9', 'Pikachu', '2016'),
  ('psa', '9001', 'p-n', 'g9', '9', 'Nothing', '2020'),
  ('psa', '8001', 'p-p', 'g9', '9', 'Pending', '2020');
insert into price_cache (source_key, source, metric, price_cents, fetch_status, source_confidence, updated_at) values
  ('p-x:g9', 'cardladder', 'cl_value', 5000,  'ok',        4, now()),
  ('p-y:g6', 'cardladder', 'cl_value', 5000,  'ok',        4, now()),
  ('p-z:g9', 'cardladder', 'cl_value', 15000, 'ok',        5, now()),
  ('p-w:g9', 'cardladder', 'cl_value', 5000,  'ok',        4, now()),
  ('p-v:g9', 'cardladder', 'cl_value', 5000,  'ok',        4, now()),
  ('p-n:g9', 'cardladder', 'cl_value', null,  'not_found', null, now());

-- ── Team creation + joining ─────────────────────────────────────────────────
set local role authenticated;
set local request.jwt.claims to '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
select ok(
  set_config('t.team', create_team('Buyers', 'Lead')->>'team_id', true) is not null,
  'create_team returns a team id');
select is((select role::text from team_members where user_id = auth.uid()), 'lead',
  'the creator is the lead');
select throws_ok($$select create_team('Second', 'Lead')$$, 'P0001', 'already_in_team',
  'a user is on one team at most');
select matches((select join_code from teams where id = current_setting('t.team')::uuid),
  '^[A-HJ-NP-Z2-9]{6}$', 'join code is six symbols with no I or O');
select ok(set_config('t.code', (select join_code from teams where id = current_setting('t.team')::uuid), true) is not null,
  'lead can read the join code');

set local request.jwt.claims to '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
select is((select count(*)::int from teams), 0, 'a non-member sees no teams');
select is(join_team('ZZZZZZ', 'Justin')->>'error', 'invalid_code',
  'a wrong code is refused — returned, not raised, so the guess is counted (20260930000000)');
-- Typed the way a person reads it aloud: lower case, with the display hyphen.
select lives_ok(
  format($$select join_team(%L, 'Justin')$$,
         lower(substr(current_setting('t.code'), 1, 3) || '-' || substr(current_setting('t.code'), 4))),
  'join_team accepts lower case and a hyphen');
select lives_ok(format($$select join_team(%L, 'Justin')$$, current_setting('t.code')),
  're-joining your own team is a no-op');
select is((select role::text from team_members where user_id = auth.uid()), 'buyer', 'a joiner is a buyer');

set local request.jwt.claims to '{"sub":"10000000-0000-0000-0000-000000000003","role":"authenticated"}';
select lives_ok(format($$select join_team(%L, 'Sam')$$, current_setting('t.code')), 'a second buyer joins');
set local request.jwt.claims to '{"sub":"10000000-0000-0000-0000-000000000005","role":"authenticated"}';
select lives_ok(format($$select join_team(%L, 'NoCL')$$, current_setting('t.code')), 'a member without CL joins');

-- ── Leads write, buyers read ────────────────────────────────────────────────
set local request.jwt.claims to '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
select throws_ok(
  $$insert into lots (team_id, name, status) values (current_setting('t.team')::uuid, 'Rogue', 'active')$$,
  '42501', null, 'a buyer cannot create a lot');

set local request.jwt.claims to '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
select lives_ok($$
  insert into lots (id, team_id, name, status) values
    ('f1000000-0000-0000-0000-000000000001', current_setting('t.team')::uuid, 'Show 9/26', 'active'),
    ('f1000000-0000-0000-0000-000000000002', current_setting('t.team')::uuid, 'Tight budget', 'active'),
    ('f1000000-0000-0000-0000-000000000003', current_setting('t.team')::uuid, 'One card', 'active'),
    ('f1000000-0000-0000-0000-000000000004', current_setting('t.team')::uuid, 'Closed', 'closed');
  insert into lot_buy_ranges (id, lot_id, name, value_min_cents, value_max_cents, grade_min, grade_max,
                              cl_conf_min, max_cards, budget_cents, sort_order) values
    ('e1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', '$0–$100',   0,     10000, 7, 10, null, 400, 4510000, 0),
    ('e1000000-0000-0000-0000-000000000002', 'f1000000-0000-0000-0000-000000000001', '$100–$240', 10000, 24000, 7, 10, 4,    150, 2000000, 1),
    ('e2000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000002', 'Tight',     0,     null,  1, 10, null, 50,  6000,    0),
    ('e3000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000003', 'Single',    0,     null,  1, 10, null, 1,   9999999, 0),
    ('e4000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000004', 'Any',       0,     null,  1, 10, null, 10,  9999999, 0);
$$, 'a lead creates lots and ranges');

set local request.jwt.claims to '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
select is((select count(*)::int from lots), 4, 'a buyer sees the team''s lots');
select throws_ok(
  $$insert into lot_claims (lot_id, cert, grader, cl_source_key, grade_code, buyer_id, scanned_at)
    values ('f1000000-0000-0000-0000-000000000001', '5001', 'psa', 'p-x:g9', 'g9', auth.uid(), now())$$,
  '42501', null, 'claims cannot be written directly — the RPC is the only path');

-- ── Outsiders and members without CL ────────────────────────────────────────
set local request.jwt.claims to '{"sub":"10000000-0000-0000-0000-000000000004","role":"authenticated"}';
select is((select count(*)::int from lots), 0, 'an outsider sees no lots');
select throws_ok($$select claim_lot_scan('f1000000-0000-0000-0000-000000000001', '5001', 'psa')$$,
  'P0001', 'not_member', 'an outsider cannot claim');
set local request.jwt.claims to '{"sub":"10000000-0000-0000-0000-000000000005","role":"authenticated"}';
select throws_ok($$select claim_lot_scan('f1000000-0000-0000-0000-000000000001', '5001', 'psa')$$,
  'P0001', 'cl_not_connected', 'a member must have Card Ladder connected to claim');

-- ── Claims: confirmed, replay, duplicate, the 3-limit ──────────────────────
set local request.jwt.claims to '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
select is(claim_lot_scan('f1000000-0000-0000-0000-000000000001', '5001', 'psa', now() - interval '3 minutes')->>'outcome', 'confirmed',
  'a fitting card is confirmed');
select is(claim_lot_scan('f1000000-0000-0000-0000-000000000001', '5001', 'psa')->>'replayed', 'true',
  'the same buyer re-claiming the same slab is an idempotent replay');

set local request.jwt.claims to '{"sub":"10000000-0000-0000-0000-000000000003","role":"authenticated"}';
select is(claim_lot_scan('f1000000-0000-0000-0000-000000000001', '5001', 'psa')->>'reason', 'duplicate_cert',
  'another buyer cannot claim a slab already in the lot');
select is(claim_lot_scan('f1000000-0000-0000-0000-000000000001', '5002', 'psa', now() - interval '2 minutes')->>'copies', '2',
  'a second slab of the same card is copy 2 of 3');
set local request.jwt.claims to '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
select is(claim_lot_scan('f1000000-0000-0000-0000-000000000001', '5003', 'psa', now() - interval '1 minute')->>'copies', '3',
  'a third slab is copy 3 of 3');

set local request.jwt.claims to '{"sub":"10000000-0000-0000-0000-000000000003","role":"authenticated"}';
select is(claim_lot_scan('f1000000-0000-0000-0000-000000000001', '5004', 'psa')->>'reason', 'limit_reached',
  'a fourth slab of the same card at the same grade is blocked');
select is(jsonb_array_length(claim_lot_scan('f1000000-0000-0000-0000-000000000001', '5004', 'psa')->'existing'), 3,
  'the block lists the three existing buys');
select is((claim_lot_scan('f1000000-0000-0000-0000-000000000001', '5004', 'psa')->'existing'->0->>'buyer'), 'Justin',
  'with the buyer''s display name, oldest first');
select is(
  claim_lot_scan('f1000000-0000-0000-0000-000000000001', '5005', 'psa', now() - interval '1 hour', 'dev-1', null, true)->>'outcome',
  'over_limit', 'an offline replay past the limit is recorded as over_limit, not lost');
select is((select count(*)::int from lot_claims
            where lot_id = 'f1000000-0000-0000-0000-000000000001' and cl_source_key = 'p-x:g9' and state = 'confirmed'),
  3, 'over_limit does not count toward the limit');

-- ── Range matching ──────────────────────────────────────────────────────────
select is(claim_lot_scan('f1000000-0000-0000-0000-000000000001', '6001', 'psa')->>'failed', 'grade',
  'a grade-6 card fits no range, and the block names grade');
select is(claim_lot_scan('f1000000-0000-0000-0000-000000000001', '7001', 'psa')->'range'->>'name', '$100–$240',
  'a $150 card lands in the $100–$240 range');
select is(claim_lot_scan('f1000000-0000-0000-0000-000000000001', '8001', 'psa')->>'outcome', 'pending',
  'a cert CL has not priced yet is pending, not a verdict');
select is(claim_lot_scan('f1000000-0000-0000-0000-000000000001', '9001', 'psa')->>'reason', 'no_cl_value',
  'a card CL has no value for is blocked, never bucketed on nothing');

-- An overlapping range: a $50 card now fits two. The buyer picks.
reset role;
insert into lot_buy_ranges (id, lot_id, name, value_min_cents, value_max_cents, max_cards, budget_cents, sort_order)
values ('e1000000-0000-0000-0000-000000000003', 'f1000000-0000-0000-0000-000000000001', '$50–$100 promos', 5000, 10000, 10, 100000, 2);
set local role authenticated;
set local request.jwt.claims to '{"sub":"10000000-0000-0000-0000-000000000003","role":"authenticated"}';
select is(claim_lot_scan('f1000000-0000-0000-0000-000000000001', '7101', 'psa')->>'outcome', 'choose_range',
  'a card fitting two ranges asks the buyer to choose');
select is((select count(*)::int from lot_claims where cert = '7101'), 0,
  'nothing is claimed while the buyer chooses');
select is(
  claim_lot_scan('f1000000-0000-0000-0000-000000000001', '7101', 'psa', now(), null,
                 'e1000000-0000-0000-0000-000000000003')->'range'->>'name',
  '$50–$100 promos', 'the re-call with a range claims into that range');
select ok((select 'year_unknown' = any(warn_reasons) from lot_claims where cert = '7101'),
  'an unknown year warns rather than blocks');

-- ── Range caps: dollars and cards ───────────────────────────────────────────
select is(claim_lot_scan('f1000000-0000-0000-0000-000000000002', '5001', 'psa')->>'outcome', 'confirmed',
  'the first $50 card fits a $60 budget');
select is(claim_lot_scan('f1000000-0000-0000-0000-000000000002', '7201', 'psa')->>'reason', 'range_full_budget',
  'a second $50 card would pass the $60 budget and is blocked');
select is(claim_lot_scan('f1000000-0000-0000-0000-000000000003', '5001', 'psa')->>'outcome', 'confirmed',
  'the first card fits a one-card range');
select is(claim_lot_scan('f1000000-0000-0000-0000-000000000003', '7201', 'psa')->>'reason', 'range_full_count',
  'a second card is blocked by max cards');
select is(claim_lot_scan('f1000000-0000-0000-0000-000000000004', '7201', 'psa')->>'reason', 'lot_closed',
  'a closed lot takes nothing');

-- ── Release frees the slot ──────────────────────────────────────────────────
select throws_ok($$select release_lot_claim('f1000000-0000-0000-0000-000000000001', '5003', 'psa')$$,
  'P0001', 'not_lead', 'a buyer cannot release someone else''s claim');
set local request.jwt.claims to '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
select is(release_lot_claim('f1000000-0000-0000-0000-000000000001', '5001', 'psa')->>'outcome', 'released',
  'a buyer releases their own claim');
set local request.jwt.claims to '{"sub":"10000000-0000-0000-0000-000000000003","role":"authenticated"}';
-- The overlapping $50–$100 range added above means a $50 card now fits two, so
-- the buyer names one — the same re-call the app makes after the range picker.
select is(claim_lot_scan('f1000000-0000-0000-0000-000000000001', '5004', 'psa', now(), null,
                         'e1000000-0000-0000-0000-000000000001')->>'outcome', 'confirmed',
  'the released slot is free for the next copy');

-- ── Roles ───────────────────────────────────────────────────────────────────
select throws_ok(
  format($$select set_member_role(%L, '10000000-0000-0000-0000-000000000003', 'lead')$$, current_setting('t.team')),
  'P0001', 'not_lead', 'a buyer cannot promote');
set local request.jwt.claims to '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
select throws_ok(
  format($$select set_member_role(%L, '10000000-0000-0000-0000-000000000001', 'buyer')$$, current_setting('t.team')),
  'P0001', 'last_lead', 'the last lead cannot step down');
select lives_ok(
  format($$select set_member_role(%L, '10000000-0000-0000-0000-000000000002', 'lead')$$, current_setting('t.team')),
  'a lead makes another member lead');
reset role;

-- ── Live totals ─────────────────────────────────────────────────────────────
select ok(exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and tablename = 'lot_claims'),
  'lot_claims is published to Realtime');

select * from finish();
rollback;
