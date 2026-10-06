-- pgTAP for lot bands, the lot banner and lot_range_usage (2026-09-25).
-- Run: supabase test db

begin;
select plan(15);

insert into auth.users (id, email) values
  ('20000000-0000-0000-0000-000000000001', 'lead@bands.test'),
  ('20000000-0000-0000-0000-000000000002', 'buyer@bands.test'),
  ('20000000-0000-0000-0000-000000000003', 'outsider@bands.test');
insert into cardladder_credentials (user_id, encrypted_blob) values
  ('20000000-0000-0000-0000-000000000002', 'x');
insert into cl_resolve_cache (grader, cert, profile_id, grade, grade_label, card_year) values
  ('psa', '90000001', 'bp-1', 'g9', '9', '2001'),
  ('psa', '90000002', 'bp-2', 'g9', '9', '2001');
insert into price_cache (source_key, source, metric, price_cents, fetch_status, source_confidence) values
  ('bp-1:g9', 'cardladder', 'cl_value', 12000, 'ok', 5),
  ('bp-2:g9', 'cardladder', 'cl_value', 13050, 'ok', 5);

insert into teams (id, name, join_code, created_by) values
  ('21000000-0000-0000-0000-000000000001', 'Bands', 'BANDSX', '20000000-0000-0000-0000-000000000001');
insert into team_members (team_id, user_id, role, display_name) values
  ('21000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'lead', 'Lead'),
  ('21000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', 'buyer', 'Buyer');
insert into lots (id, team_id, name, status, banner, created_by) values
  ('22000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001', 'A', 'active',
   'Only accepting PSA slabs', '20000000-0000-0000-0000-000000000001'),
  ('22000000-0000-0000-0000-000000000002', '21000000-0000-0000-0000-000000000001', 'B', 'active',
   null, '20000000-0000-0000-0000-000000000001');
insert into lot_bands (id, lot_id, category, sort_order) values
  ('23000000-0000-0000-0000-000000000001', '22000000-0000-0000-0000-000000000001', 'Pokémon', 0),
  ('23000000-0000-0000-0000-000000000002', '22000000-0000-0000-0000-000000000002', 'Pokémon', 0);

select lives_ok($$
  insert into lot_buy_ranges (id, lot_id, band_id, name, value_min_cents, value_max_cents, max_cards, budget_cents)
  values ('24000000-0000-0000-0000-000000000001', '22000000-0000-0000-0000-000000000001',
          '23000000-0000-0000-0000-000000000001', '$100 – $240', 10000, 24000, 50, 4366000)
$$, 'a range joins a band in its own lot');
select throws_ok($$
  insert into lot_buy_ranges (lot_id, band_id, name, max_cards, budget_cents)
  values ('22000000-0000-0000-0000-000000000001', '23000000-0000-0000-0000-000000000002', 'x', 1, 1)
$$, 'P0001', 'band_not_in_lot', 'a range cannot join another lot''s band');

set local role authenticated;
set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated"}';
select is((select count(*)::int from lot_bands), 2, 'a member reads the bands');
select is((select banner from lots where id = '22000000-0000-0000-0000-000000000001'),
  'Only accepting PSA slabs', 'a member reads the banner');
select throws_ok($$insert into lot_bands (lot_id) values ('22000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'a buyer cannot add a band');

select claim_lot_scan('22000000-0000-0000-0000-000000000001', '90000001', 'psa');
select claim_lot_scan('22000000-0000-0000-0000-000000000001', '90000002', 'psa');
select is((select row(cards, used_cents)::text from lot_range_usage
            where lot_buy_range_id = '24000000-0000-0000-0000-000000000001'),
  '(2,25050)', 'usage sums the confirmed claims in a range, in cents');
select is((select count(*)::int from lot_range_usage where lot_id = '22000000-0000-0000-0000-000000000002'), 0,
  'a lot with no claims has no usage rows (the app reads that as $0 used)');

set local request.jwt.claims to '{"sub":"20000000-0000-0000-0000-000000000003","role":"authenticated"}';
select is((select count(*)::int from lot_range_usage), 0, 'an outsider sees no usage — the view honours RLS');
reset role;

-- A grade the lot can check when Card Ladder gives no plain label (real CGC
-- Pristine 10, cert 4260611176, 2026-09-25).
select is(cl_grade_number('9', 'g9'), 9::numeric, 'a plain label is the grade');
select is(cl_grade_number(null, 'g10pristine'), 10::numeric, 'a Pristine 10 counts as a 10 for lot rules');
select is(cl_grade_number(null, 'gauthentic'), null, 'a grade with no number stays unknown');

-- A bucket's band is a label on the bucket (20260928000000_bucket_band.sql).
select has_column('lot_buy_ranges', 'band', 'a lot bucket carries its band label');
select has_column('buy_range_templates', 'band', 'a saved bucket keeps its band into the next lot');
select throws_ok($$update lot_buy_ranges set band = '   ' where lot_id = '22000000-0000-0000-0000-000000000001'$$,
  '23514', null, 'a blank band is refused — no band is null, not whitespace');
select lives_ok($$update lot_buy_ranges set band = null where lot_id = '22000000-0000-0000-0000-000000000001'$$,
  'no band is allowed');

select * from finish();
rollback;
