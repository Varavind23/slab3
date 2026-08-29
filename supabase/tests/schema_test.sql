-- pgTAP tests for the v1 schema. Run: supabase test db
-- Covers: card_key normalization, sale-limit boundary (3 ok / 4 needs ack),
-- RLS isolation between users, and worker-table deny-all to clients.

begin;
select plan(15);

-- Extensions used by the tests
create extension if not exists pgtap with schema extensions;

-- ── card_key normalization ──────────────────────────────────────────────────
select is(
  make_card_key('psa', '1999 Pokemon Base Set', 'Charizard #4', 'PSA 9'),
  'psa:1999-pokemon-base-set:charizard-4:psa-9',
  'make_card_key normalizes grader/set/id/grade'
);
select is(
  make_card_key('psa', '1999  Pokemon   Base Set', 'Charizard #4', 'PSA 9'),
  make_card_key('psa', '1999 pokemon base set', 'charizard  #4', 'psa 9'),
  'make_card_key is whitespace/case/punctuation stable (equivalence)'
);
select isnt(
  make_card_key('psa', 'Base Set', 'Charizard', 'PSA 9'),
  make_card_key('cgc', 'Base Set', 'Charizard', 'PSA 9'),
  'different grader → different card_key'
);

-- ── Seed two users + cards ──────────────────────────────────────────────────
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@test.dev'),
  ('22222222-2222-2222-2222-222222222222', 'b@test.dev');

-- User A: four identical Charizard PSA 9 (same card_key), distinct certs
insert into cards (user_id, grader, cert_number, card_key, name, set, year, grade) values
  ('11111111-1111-1111-1111-111111111111','psa','1001', make_card_key('psa','Base Set','Charizard','PSA 9'),'Charizard','Base Set',1999,'PSA 9'),
  ('11111111-1111-1111-1111-111111111111','psa','1002', make_card_key('psa','Base Set','Charizard','PSA 9'),'Charizard','Base Set',1999,'PSA 9'),
  ('11111111-1111-1111-1111-111111111111','psa','1003', make_card_key('psa','Base Set','Charizard','PSA 9'),'Charizard','Base Set',1999,'PSA 9'),
  ('11111111-1111-1111-1111-111111111111','psa','1004', make_card_key('psa','Base Set','Charizard','PSA 9'),'Charizard','Base Set',1999,'PSA 9');
insert into folders (id, user_id, name) values
  ('33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111','Sale to Card Ladder');

-- Helper: card ids for user A
create temp table ca as select id, cert_number from cards where cert_number in ('1001','1002','1003','1004');

-- ── Sale-limit: first three insert clean ────────────────────────────────────
select lives_ok(
  $$insert into folder_cards (folder_id, card_id)
    select '33333333-3333-3333-3333-333333333333', id from ca where cert_number='1001'$$,
  '1st identical card inserts');
select lives_ok(
  $$insert into folder_cards (folder_id, card_id)
    select '33333333-3333-3333-3333-333333333333', id from ca where cert_number='1002'$$,
  '2nd identical card inserts');
select lives_ok(
  $$insert into folder_cards (folder_id, card_id)
    select '33333333-3333-3333-3333-333333333333', id from ca where cert_number='1003'$$,
  '3rd identical card inserts');

-- ── Sale-limit: check_sale_limit reports at_limit before the 4th ────────────
select is(
  (select at_limit from check_sale_limit('33333333-3333-3333-3333-333333333333',
     (select id from ca where cert_number='1004'))),
  true,
  'check_sale_limit flags at_limit at 3 identical'
);

-- ── Sale-limit: 4th without ack is blocked ──────────────────────────────────
select throws_ok(
  $$insert into folder_cards (folder_id, card_id)
    select '33333333-3333-3333-3333-333333333333', id from ca where cert_number='1004'$$,
  '23514',
  null,
  '4th identical card without ack raises check_violation'
);

-- ── Sale-limit: 4th WITH ack succeeds (4A override) ─────────────────────────
select lives_ok(
  $$insert into folder_cards (folder_id, card_id, over_limit_ack)
    select '33333333-3333-3333-3333-333333333333', id, true from ca where cert_number='1004'$$,
  '4th identical card WITH over_limit_ack overrides the limit'
);

-- ── RLS isolation: user B cannot see user A's cards ─────────────────────────
set local role authenticated;
set local request.jwt.claims to '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
select is(
  (select count(*)::int from cards),
  0,
  'RLS: user B sees zero of user A''s cards'
);
reset role;

-- ── RLS isolation: user A sees exactly their four ───────────────────────────
set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
select is(
  (select count(*)::int from cards),
  4,
  'RLS: user A sees exactly their 4 cards'
);
reset role;

-- ── Worker tables deny-all to clients ───────────────────────────────────────
set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
select is(
  (select count(*)::int from price_cache),
  0,
  'price_cache is deny-all to authenticated clients (no policy)'
);
select throws_ok(
  $$insert into worker_jobs (kind) values ('price_refresh')$$,
  '42501',
  null,
  'authenticated client cannot write worker_jobs'
);
-- Sale comps are global and service-role only, same trust model as price_cache:
-- the client reads them through the Edge Function, which enforces the Card
-- Ladder connection gate. A readable table would route around that gate.
select is(
  (select count(*)::int from card_sales_cache),
  0,
  'card_sales_cache is deny-all to authenticated clients (no policy)'
);
select throws_ok(
  $$insert into card_sales_cache (card_key, source) values ('psa:x:1:psa-9', 'cardladder')$$,
  '42501',
  null,
  'authenticated client cannot write card_sales_cache'
);
reset role;

select * from finish();
rollback;
