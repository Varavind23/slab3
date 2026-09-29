-- Lot bands, categories and the lot banner (2026-09-25).
-- Plan: ~/.claude/plans/read-teams-md-lets-first-harmonic-horizon.md (§8, the lot dashboard).
--
-- WHY. The owner wants the lot dashboard laid out like the allocation screen his
-- buyers already use every day, so there is nothing new to learn: a deadline
-- countdown, a warning banner, a category selector, and price BANDS that expand
-- into their BUCKETS with a bar chart. Buy ranges stay the bucket (and stay what
-- claim_lot_scan matches against — nothing about claiming changes here). A band is
-- only a GROUPING of buckets:
--
--   • it has no price span or rules of its own — both are derived from its buckets
--     in the app, so a band can never disagree with what it contains, and there is
--     still exactly one place a rule lives (the range) and one matcher (the RPC);
--   • its allocation is the sum of its buckets' budgets, its "used" the sum of
--     their claims — the same derivation, for the same reason;
--   • a range with no band is shown as a band of one.
--
-- category lives on the band (a lot can hold Pokémon bands and Sports bands at
-- once, switched by the selector). Free text: categories are the lead's, not ours.

alter table lots add column banner text;

create table lot_bands (
  id         uuid primary key default gen_random_uuid(),
  lot_id     uuid not null references lots(id) on delete cascade,
  category   text check (category is null or length(trim(category)) > 0),
  sort_order int not null default 0
);
create index lot_bands_lot_idx on lot_bands (lot_id, sort_order);

-- A range's band must be in the SAME lot; a trigger rather than a composite FK so
-- lot_buy_ranges keeps its simple primary key.
alter table lot_buy_ranges
  add column band_id uuid references lot_bands(id) on delete set null;
create index lot_buy_ranges_band_idx on lot_buy_ranges (band_id);

create or replace function lot_buy_ranges_same_lot_band()
returns trigger language plpgsql as $$
begin
  if new.band_id is not null and not exists (
    select 1 from lot_bands where id = new.band_id and lot_id = new.lot_id
  ) then
    raise exception 'band_not_in_lot';
  end if;
  return new;
end $$;

create trigger lot_buy_ranges_same_lot_band
  before insert or update of band_id, lot_id on lot_buy_ranges
  for each row execute function lot_buy_ranges_same_lot_band();

alter table lot_bands enable row level security;
create policy lot_bands_read  on lot_bands for select using (is_team_member(lot_team(lot_id)));
create policy lot_bands_write on lot_bands for all
  using (is_team_lead(lot_team(lot_id))) with check (is_team_lead(lot_team(lot_id)));

-- The dashboard's "used" figures, per range, for a member's lots. A view rather
-- than shipping every claim row to every phone just to add them up; it runs with
-- the caller's rights (security_invoker), so lot_claims' RLS still decides what
-- anyone can see.
create view lot_range_usage with (security_invoker = true) as
  select lot_id,
         lot_buy_range_id,
         count(*)::int                        as cards,
         coalesce(sum(price_cents), 0)::bigint as used_cents
    from lot_claims
   where state = 'confirmed'
   group by lot_id, lot_buy_range_id;

grant select on lot_range_usage to authenticated;
revoke all on lot_range_usage from anon;
