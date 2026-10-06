-- pgTAP for virtual members, linking, merging and credit (2026-10-04).
-- Run: supabase test db
-- Plan: ~/.claude/plans/pasted-content-id-960f-i-want-memoized-heron.md
--
-- Pinned: only a lead edits the roster or tags slabs; a buyer can read the roster but
-- never an invite code; an invite is single use, expires, and wrong guesses are
-- counted; a linked consignor is NOT a member and reads only their own credited,
-- bought slabs through my_credited_cards; merge moves credit and the account and
-- refuses two different accounts; a person with credit cannot be removed.

begin;
select plan(41);

-- ── Seed (as postgres) ──────────────────────────────────────────────────────
-- 1 Lead  2 Buyer  3 Consignor (has the app, not on the team)  4 Other consignor
insert into auth.users (id, email) values
  ('40000000-0000-0000-0000-000000000001', 'lead@people.dev'),
  ('40000000-0000-0000-0000-000000000002', 'buyer@people.dev'),
  ('40000000-0000-0000-0000-000000000003', 'consignor@people.dev'),
  ('40000000-0000-0000-0000-000000000004', 'other@people.dev');
insert into teams (id, name, join_code, created_by) values
  ('b0000000-0000-0000-0000-000000000001', 'People', 'PEPL23', '40000000-0000-0000-0000-000000000001');
insert into team_members (team_id, user_id, role, display_name) values
  ('b0000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 'lead', 'Lead'),
  ('b0000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002', 'buyer', 'Buyer');
insert into lots (id, team_id, name, status, created_by) values
  ('b1000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 'Show', 'active', '40000000-0000-0000-0000-000000000001');
insert into lot_claims (id, lot_id, cert, grader, cl_source_key, grade_code, price_cents, max_buy_cents, buyer_id, state, scanned_at) values
  ('b2000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', '7001', 'psa', 'p-a:g9', 'g9', 5000, 4000, '40000000-0000-0000-0000-000000000001', 'confirmed',  now()),
  ('b2000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001', '7002', 'psa', 'p-b:g9', 'g9', 6000, null, '40000000-0000-0000-0000-000000000001', 'over_limit', now()),
  ('b2000000-0000-0000-0000-000000000003', 'b1000000-0000-0000-0000-000000000001', '7003', 'psa', 'p-c:g9', 'g9', 7000, null, '40000000-0000-0000-0000-000000000002', 'removed',    now());
-- A second team, to prove tags cannot cross teams.
insert into teams (id, name, join_code, created_by) values
  ('b0000000-0000-0000-0000-000000000002', 'Elsewhere', 'ELSW23', '40000000-0000-0000-0000-000000000004');
insert into team_members (team_id, user_id, role, display_name) values
  ('b0000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000004', 'lead', 'Other');
insert into team_people (id, team_id, display_name, created_by) values
  ('b3000000-0000-0000-0000-000000000009', 'b0000000-0000-0000-0000-000000000002', 'Not yours', '40000000-0000-0000-0000-000000000004');

create temp table ids (k text primary key, v uuid);
grant all on ids to authenticated;
create temp table codes (k text primary key, v text);
grant all on codes to authenticated;

-- ── Roster: the lead writes, a buyer reads ──────────────────────────────────
set local role authenticated;
set local request.jwt.claims to '{"sub":"40000000-0000-0000-0000-000000000002","role":"authenticated"}';
select throws_ok($$select add_person('b0000000-0000-0000-0000-000000000001', 'Mike')$$,
  'P0001', 'not_lead', 'a buyer cannot add a virtual member');
select throws_ok($$insert into team_people (team_id, display_name) values ('b0000000-0000-0000-0000-000000000001', 'Sneak')$$,
  '42501', null, 'nor insert one directly');

set local request.jwt.claims to '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}';
insert into ids select 'mike',    (add_person('b0000000-0000-0000-0000-000000000001', '  Mike ', 'blue binder')).id;
insert into ids select 'michael', (add_person('b0000000-0000-0000-0000-000000000001', 'Michael')).id;
select is((select display_name from team_people where id = (select v from ids where k = 'mike')), 'Mike',
  'the lead adds a virtual member (name trimmed)');
select is((select user_id from team_people where id = (select v from ids where k = 'mike')), null,
  'a new member is virtual');
select lives_ok($$select update_person((select v from ids where k = 'mike'), 'Mike R', 'pays 70%')$$, 'the lead renames');
select is((select note from team_people_notes('b0000000-0000-0000-0000-000000000001')), 'pays 70%',
  'the lead reads the note');

set local request.jwt.claims to '{"sub":"40000000-0000-0000-0000-000000000002","role":"authenticated"}';
select is((select count(*)::int from team_people), 2, 'a buyer reads their team''s roster, not other teams''');
select throws_ok($$select link_code from team_people$$, '42501', null, 'but never an invite code');
select throws_ok($$select note from team_people$$, '42501', null,
  'nor the lead''s note ("Only your team''s leads see this", 2026-10-06)');
select is((select count(*)::int from team_people_notes('b0000000-0000-0000-0000-000000000001')), 0,
  'and the notes function answers a buyer with nothing');
select throws_ok($$select update_person((select v from ids where k = 'mike'), 'X', null)$$,
  'P0001', 'not_lead', 'nor renames');

-- ── Credit ──────────────────────────────────────────────────────────────────
select throws_ok($$select set_claim_person('b1000000-0000-0000-0000-000000000001',
                   array['b2000000-0000-0000-0000-000000000001']::uuid[], (select v from ids where k = 'mike'))$$,
  'P0001', 'not_lead', 'a buyer cannot tag slabs');
update lot_claims set credited_person_id = (select v from ids where k = 'mike');
select is((select count(*)::int from lot_claims where credited_person_id is not null), 0,
  'nor write the column directly (RLS: no update policy)');

set local request.jwt.claims to '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}';
select is(set_claim_person('b1000000-0000-0000-0000-000000000001',
            array['b2000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000003']::uuid[],
            (select v from ids where k = 'michael')),
  1, 'the lead tags slabs; a released one is skipped');
select is(set_claim_person('b1000000-0000-0000-0000-000000000001',
            array['b2000000-0000-0000-0000-000000000002']::uuid[], (select v from ids where k = 'mike')),
  1, 'and an over-limit buy');
select throws_ok($$select set_claim_person('b1000000-0000-0000-0000-000000000001',
                   array['b2000000-0000-0000-0000-000000000001']::uuid[], 'b3000000-0000-0000-0000-000000000009')$$,
  'P0001', 'not_on_team', 'a person from another team cannot be credited');
select is((select buyer_id from lot_claims where id = 'b2000000-0000-0000-0000-000000000001'),
  '40000000-0000-0000-0000-000000000001'::uuid, 'the scanner stays as added-by');
select throws_ok($$select remove_person((select v from ids where k = 'mike'))$$,
  'P0001', 'has_credit', 'a person holding credit cannot be removed');

-- ── Invite + link ───────────────────────────────────────────────────────────
insert into codes select 'mike', invite_person((select v from ids where k = 'mike'))->>'code';
select matches((select v from codes where k = 'mike'), '^[A-HJ-NP-Z2-9]{6}$', 'an invite is a six-character code');
select is(invite_person((select v from ids where k = 'mike'))->>'code', (select v from codes where k = 'mike'),
  'asking again returns the same code (the texted one keeps working)');

set local request.jwt.claims to '{"sub":"40000000-0000-0000-0000-000000000002","role":"authenticated"}';
select throws_ok($$select invite_person((select v from ids where k = 'mike'))$$,
  'P0001', 'not_lead', 'a buyer cannot make an invite');

set local request.jwt.claims to '{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}';
select is(my_credited_cards(), '[]'::jsonb, 'before linking, a consignor sees nothing');
select is(link_person('ZZZZZZ')->>'error', 'invalid_code', 'a wrong code is refused');
reset role;
select is((select count(*)::int from join_attempts where user_id = '40000000-0000-0000-0000-000000000003'), 1,
  'and counted against the shared join/link budget');
set local role authenticated;
select is(link_person(lower((select v from codes where k = 'mike')))->>'display_name', 'Mike R',
  'the right code links (case-insensitive)');
select is(link_person((select v from codes where k = 'mike'))->>'error', 'invalid_code', 'a code works once');
select is((select count(*)::int from team_members where user_id = '40000000-0000-0000-0000-000000000003'), 0,
  'linking does not make the consignor a member');
select is((select count(*)::int from lot_claims), 0, 'so they read no claims directly');
select is((select count(*)::int from team_people), 0, 'nor the roster');
select is(jsonb_array_length(my_credited_cards()), 1, 'my_credited_cards lists their one bought slab');
select is(my_links()->0->>'team_name', 'People', 'my_links names the team they consign to');
select ok(not (my_links()->0 ? 'note'), 'but never the lead''s note on them');
select is(my_credited_cards()->0->>'added_by', 'Lead', 'with who added it');
select ok(not (my_credited_cards()->0 ? 'max_buy_cents'), 'and never the lead''s max buy');

-- ── Merge ───────────────────────────────────────────────────────────────────
set local request.jwt.claims to '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}';
insert into ids select 'buyer', member_person('b0000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002');
select throws_ok($$select merge_people((select v from ids where k = 'mike'), (select v from ids where k = 'buyer'))$$,
  'P0001', 'linked_to_different_accounts', 'two different accounts are two different people');
select lives_ok($$select merge_people((select v from ids where k = 'michael'), (select v from ids where k = 'mike'))$$,
  'the lead merges Mike into Michael');
select is((select user_id from team_people where id = (select v from ids where k = 'michael')),
  '40000000-0000-0000-0000-000000000003'::uuid, 'the account carries over to the kept entry');
select is((select count(*)::int from lot_claims where credited_person_id = (select v from ids where k = 'michael')), 2,
  'and every credited slab follows');

set local request.jwt.claims to '{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}';
select is(jsonb_array_length(my_credited_cards()), 2, 'the consignor now sees both bought slabs');
select lives_ok($$select unlink_person((select v from ids where k = 'michael'))$$,
  'a consignor can unlink themselves');
select is(my_links(), '[]'::jsonb, 'and then has no links');

select * from finish();
rollback;
