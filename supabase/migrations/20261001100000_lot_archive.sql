-- Archiving lots, and deletion the server actually enforces (owner, 2026-10-01;
-- ~/.claude/plans/misty-puzzling-nebula.md).
--
-- WHY. Closed lots stayed listed for every teammate forever, and only a draft could
-- be deleted — a rule the PHONE enforced (LotStore.deleteDraft) and the server did
-- not: `lots_write` lets a lead delete any lot, and lot_claims cascade with it, so a
-- lead's delete on a lot with buys would have erased the team's history. Owner:
-- leads only, team-wide; a lot with buys can only be ARCHIVED.
--
-- archived_at, NOT a new lot_status value: 0.8 phones decode `status` into a closed
-- enum, and an unknown 'archived' would fail their whole lot load. They select named
-- columns, so a new column is invisible to them. The lead writes it through the
-- existing lead-only `lots_write` policy; archiving an open lot closes it in the same
-- update (the app does both), and claim_lot_scan already refuses anything not active.

alter table lots add column archived_at timestamptz;

-- A lot with buys in it is never deleted directly. Released (`removed`) rows are not
-- buys; they go with the lot. A DELETE that arrives by cascade (a team being removed)
-- is allowed: inside a cascade this trigger runs nested under the foreign key's own
-- trigger, so its depth is greater than 1.
create or replace function lots_delete_guard()
returns trigger language plpgsql as $$
begin
  if pg_trigger_depth() = 1 and exists (
       select 1 from lot_claims
        where lot_id = old.id and state in ('confirmed', 'over_limit')) then
    raise exception 'has_buys';
  end if;
  return old;
end $$;

create trigger lots_delete_guard before delete on lots
  for each row execute function lots_delete_guard();
