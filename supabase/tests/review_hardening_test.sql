-- pgTAP tests for 20260930000000_review_hardening.sql (review, 2026-10-02).
-- Run: supabase test db
--
-- One section per section of the migration: a closed lot keeps its record, join
-- codes cannot be guessed (and say nothing about which codes exist), removing a
-- member rotates the code and is checked after the team lock, a bucket holding
-- buys cannot be deleted or moved, and claim_lot_scan replays before it checks
-- the lot's status and turns away odd-shaped certs. The lead-check-after-lock
-- race needs two committing sessions and is not testable in one transaction.

begin;
select plan(25);

-- ── Seed (as postgres) ──────────────────────────────────────────────────────
-- 1 Lead  2 Buyer  3 Second buyer  4 Guesser (on no team)
insert into auth.users (id, email) values
  ('20000000-0000-0000-0000-000000000001', 'lead@review.dev'),
  ('20000000-0000-0000-0000-000000000002', 'buyer@review.dev'),
  ('20000000-0000-0000-0000-000000000003', 'buyer2@review.dev'),
  ('20000000-0000-0000-0000-000000000004', 'guesser@review.dev');
insert into cardladder_credentials (user_id, encrypted_blob) values
  ('20000000-0000-0000-0000-000000000001', 'x'),
  ('20000000-0000-0000-0000-000000000002', 'x'),
  ('20000000-0000-0000-0000-000000000003', 'x');
insert into cl_resolve_cache (grader, cert, profile_id, grade, grade_label, label, card_year) values
  ('psa', '11110001', 'r-a', 'g9', '9', 'Charizard', '1999'),
  ('psa', '11110002', 'r-b', 'g9', '9', 'Blastoise', '1999'),
  ('psa', '11110003', 'r-c', 'g9', '9', 'Venusaur', '1999');
insert into price_cache (source_key, source, metric, price_cents, fetch_status, source_confidence, updated_at) values
  ('r-a:g9', 'cardladder', 'cl_value', 5000, 'ok', 4, now()),
  ('r-b:g9', 'cardladder', 'cl_value', 5000, 'ok', 4, now()),
  ('r-c:g9', 'cardladder', 'cl_value', 5000, 'ok', 4, now());

set local role authenticated;
set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$ begin
  perform set_config('t.team', create_team('Review', 'Lead')->>'team_id', true);
  perform set_config('t.code', (select join_code from teams where id = current_setting('t.team')::uuid), true);
end $$;
insert into lots (id, team_id, name, status) values
  ('a1000000-0000-0000-0000-000000000001', current_setting('t.team')::uuid, 'Open', 'active'),
  ('a1000000-0000-0000-0000-000000000002', current_setting('t.team')::uuid, 'Other', 'active');
insert into lot_buy_ranges (id, lot_id, name, value_min_cents, value_max_cents, grade_min, grade_max,
                            cl_conf_min, max_cards, budget_cents, sort_order) values
  ('b1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'Any',   0, null, 1, 10, null, 50, 9999999, 0),
  ('b1000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'Empty', 900000, null, 1, 10, null, 50, 9999999, 1),
  ('b2000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002', 'Any',   0, null, 1, 10, null, 50, 9999999, 0);

-- ── 2. Joining ──────────────────────────────────────────────────────────────
set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated"}';
select is((join_team(current_setting('t.code'), 'Buyer'))->>'team_id', current_setting('t.team'),
  'the right code joins');
select throws_ok($$select join_team('ZZZZZZ', 'Buyer')$$, 'P0001', 'already_in_team',
  'a member trying a WRONG code is told only "already on a team"');
select throws_ok($$select join_team('YYYYYY', 'Buyer')$$, 'P0001', 'already_in_team',
  '— the same answer as for any other code, so it reveals nothing');
select is((join_team(current_setting('t.code'), 'Buyer'))->>'team_id', current_setting('t.team'),
  'their own team''s code is still a harmless no-op');
set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000003","role":"authenticated"}';
select is((join_team(current_setting('t.code'), 'Buyer two'))->>'team_id', current_setting('t.team'),
  'a second buyer joins');

set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000004","role":"authenticated"}';
select is((select count(*)::int from (
  select join_team('ZZZZZ' || chr(65 + g), 'Guesser') from generate_series(0, 9) g) t), 10,
  'ten wrong guesses are answered');
select throws_ok($$select count(*) from join_attempts$$, '42501', null,
  'the guesser cannot read the attempt log');
select is((join_team(current_setting('t.code'), 'Guesser'))->>'error', 'too_many_attempts',
  'after ten misses even the right code is refused for the hour');
select is((select count(*)::int from team_members where user_id = auth.uid()), 0,
  'and the guesser did not join');

-- ── 5. claim_lot_scan ───────────────────────────────────────────────────────
set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated"}';
select is(claim_lot_scan('a1000000-0000-0000-0000-000000000001', '11110001', 'psa')->>'outcome', 'confirmed',
  'a buyer claims a slab');
select is(claim_lot_scan('a1000000-0000-0000-0000-000000000001', ' 11110001', 'psa')->>'reason', 'bad_cert',
  'a padded cert is turned away rather than treated as another slab');
select is(claim_lot_scan('a1000000-0000-0000-0000-000000000001', '１１１１０００１', 'psa')->>'reason', 'bad_cert',
  'so are full-width digits');
set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000003","role":"authenticated"}';
select is(claim_lot_scan('a1000000-0000-0000-0000-000000000001', '11110002', 'psa')->>'outcome', 'confirmed',
  'the second buyer claims a slab');

-- ── 4. Buckets ──────────────────────────────────────────────────────────────
set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
select throws_ok($$delete from lot_buy_ranges where id = 'b1000000-0000-0000-0000-000000000001'$$,
  'P0001', 'range_has_buys', 'a bucket holding buys cannot be deleted');
select throws_ok($$update lot_buy_ranges set lot_id = 'a1000000-0000-0000-0000-000000000002'
                   where id = 'b1000000-0000-0000-0000-000000000002'$$,
  'P0001', 'range_lot_fixed', 'a bucket cannot be moved to another lot');
select lives_ok($$delete from lot_buy_ranges where id = 'b1000000-0000-0000-0000-000000000002'$$,
  'an empty bucket can still be deleted');

-- ── 1 + 5. A closed lot ─────────────────────────────────────────────────────
update lots set status = 'closed' where id = 'a1000000-0000-0000-0000-000000000001';
set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated"}';
select is(claim_lot_scan('a1000000-0000-0000-0000-000000000001', '11110001', 'psa')->>'replayed', 'true',
  'a retried claim the buyer already holds replays even after the lot closed');
select is(claim_lot_scan('a1000000-0000-0000-0000-000000000001', '11110003', 'psa')->>'reason', 'lot_closed',
  'a NEW slab is still refused by a closed lot');
select is(release_lot_claim('a1000000-0000-0000-0000-000000000001', '11110001', 'psa')->>'reason', 'lot_closed',
  'a buyer''s release on a closed lot is answered, not applied');
select is((select state::text from lot_claims where cert = '11110001'), 'confirmed',
  '— the closed lot keeps the buy');
set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
select is(release_lot_claim('a1000000-0000-0000-0000-000000000001', '11110002', 'psa')->>'outcome', 'released',
  'a lead can still release on a closed lot');

-- ── 3. Removing a member ────────────────────────────────────────────────────
select lives_ok(format($$select remove_team_member(%L, '20000000-0000-0000-0000-000000000003')$$,
                       current_setting('t.team')), 'the lead removes a buyer');
select isnt((select join_code from teams where id = current_setting('t.team')::uuid), current_setting('t.code'),
  'removing someone gives the team a new code');
set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000003","role":"authenticated"}';
select is((join_team(current_setting('t.code'), 'Back again'))->>'error', 'invalid_code',
  'the removed buyer cannot rejoin with the old code');
reset role;

-- The backstop under the RPC's check.
select throws_ok($$insert into lot_claims (lot_id, cert, grader, cl_source_key, grade_code, buyer_id, scanned_at)
                   values ('a1000000-0000-0000-0000-000000000002', '1111 0001', 'psa', 'r-a:g9', 'g9',
                           '20000000-0000-0000-0000-000000000002', now())$$,
  '23514', null, 'the table itself refuses a cert that is not digits');

select * from finish();
rollback;
