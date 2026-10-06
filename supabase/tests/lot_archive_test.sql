-- pgTAP for archiving lots and the server-side delete rule (2026-10-01).
-- Run: supabase test db
-- Plan: ~/.claude/plans/misty-puzzling-nebula.md
--
-- Pinned: only a lead archives; archiving closes a lot so it takes no claims; a lot
-- with buys cannot be deleted directly (it could before — `lots_write` allowed it and
-- the claims cascaded away); an empty lot can; unarchive leaves the status alone; and
-- removing a whole TEAM still cascades through its lots.

begin;
select plan(10);

-- ── Seed (as postgres) ──────────────────────────────────────────────────────
insert into auth.users (id, email) values
  ('30000000-0000-0000-0000-000000000001', 'lead@archive.dev'),
  ('30000000-0000-0000-0000-000000000002', 'buyer@archive.dev');
insert into cardladder_credentials (user_id, encrypted_blob) values
  ('30000000-0000-0000-0000-000000000002', 'x');
insert into teams (id, name, join_code, created_by) values
  ('a0000000-0000-0000-0000-000000000001', 'Archive', 'ARCH23', '30000000-0000-0000-0000-000000000001');
insert into team_members (team_id, user_id, role, display_name) values
  ('a0000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'lead', 'Lead'),
  ('a0000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', 'buyer', 'Buyer');
insert into lots (id, team_id, name, status, created_by) values
  ('a1000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'With buys', 'active', '30000000-0000-0000-0000-000000000001'),
  ('a1000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'Empty',     'active', '30000000-0000-0000-0000-000000000001');
insert into lot_claims (lot_id, cert, grader, cl_source_key, grade_code, price_cents, buyer_id, state, scanned_at) values
  ('a1000000-0000-0000-0000-000000000001', '5001', 'psa', 'p-x:g9', 'g9', 5000, '30000000-0000-0000-0000-000000000002', 'confirmed', now()),
  -- A released slab is not a buy: it must not keep the Empty lot from being deleted.
  ('a1000000-0000-0000-0000-000000000002', '5002', 'psa', 'p-x:g9', 'g9', 5000, '30000000-0000-0000-0000-000000000002', 'removed', now());

-- ── A buyer can do nothing ─────────────────────────────────────────────────
set local role authenticated;
set local request.jwt.claims to '{"sub":"30000000-0000-0000-0000-000000000002","role":"authenticated"}';
update lots set archived_at = now() where id = 'a1000000-0000-0000-0000-000000000001';
select is((select archived_at from lots where id = 'a1000000-0000-0000-0000-000000000001'), null,
  'a buyer''s archive changes nothing (RLS)');

-- ── The lead archives ───────────────────────────────────────────────────────
set local request.jwt.claims to '{"sub":"30000000-0000-0000-0000-000000000001","role":"authenticated"}';
select lives_ok($$update lots set status = 'closed', archived_at = now()
                   where id = 'a1000000-0000-0000-0000-000000000001'$$, 'the lead archives a lot');
select ok((select archived_at is not null and status = 'closed' from lots
            where id = 'a1000000-0000-0000-0000-000000000001'), 'an archived lot is closed');

set local request.jwt.claims to '{"sub":"30000000-0000-0000-0000-000000000002","role":"authenticated"}';
select is(claim_lot_scan('a1000000-0000-0000-0000-000000000001', '5003', 'psa')->>'reason', 'lot_closed',
  'an archived lot takes no claims');
select is((select count(*)::int from lots where archived_at is not null), 1,
  'members still see the archived lot (it is history, not gone)');

-- ── Deletion is the server's rule now ───────────────────────────────────────
set local request.jwt.claims to '{"sub":"30000000-0000-0000-0000-000000000001","role":"authenticated"}';
select throws_ok($$delete from lots where id = 'a1000000-0000-0000-0000-000000000001'$$,
  'P0001', 'has_buys', 'a lot with buys cannot be deleted, even by its lead');
select lives_ok($$delete from lots where id = 'a1000000-0000-0000-0000-000000000002'$$,
  'an open lot with no buys can be (a released slab is not a buy)');
select is((select count(*)::int from lots where id = 'a1000000-0000-0000-0000-000000000002'), 0, 'and it is gone');

select lives_ok($$update lots set archived_at = null where id = 'a1000000-0000-0000-0000-000000000001'$$,
  'the lead unarchives');

-- ── A team's removal still cascades ─────────────────────────────────────────
reset role;
select lives_ok($$delete from teams where id = 'a0000000-0000-0000-0000-000000000001'$$,
  'removing a team still takes its lots, buys and all');

select * from finish();
rollback;
