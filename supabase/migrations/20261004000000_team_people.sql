-- Virtual members: people a lead tracks who may never install the app, and who
-- gets the credit for a slab (owner decisions V1–V6, 2026-10-04;
-- ~/.claude/plans/pasted-content-id-960f-i-want-memoized-heron.md).
--
-- WHY. A lead's business runs on consignors — people who hand over stacks of slabs.
-- Only the lead scans, so every claim said the LEAD bought it and nothing recorded
-- whose cards they were. The lead needs to tag slabs to the person who sourced them,
-- see that person as the buyer (Team activity, CSV), and connect them to a real
-- account later — or merge two entries that turn out to be the same human.
--
-- WHY NOT team_members. Its user_id is NOT NULL (no account, no row) and unique (one
-- team per account), and being a member reads every lot and claim on the team. So a
-- person is their own row; linking one to an account grants exactly one thing — a
-- read-only list of the slabs credited to them (my_credited_cards) — and never
-- membership. No existing table policy is widened.
--
-- ADDITIVE AND SAFE FOR 0.8 CLIENTS. One nullable column on lot_claims (0.8 selects
-- named columns, so it is invisible to them) and one new table.

create table team_people (
  id           uuid primary key default gen_random_uuid(),
  team_id      uuid not null references teams(id) on delete cascade,
  display_name text not null check (length(trim(display_name)) > 0),
  note         text,
  -- NULL = virtual. Set = linked to an account: a consignor who entered the lead's
  -- invite code, or a team member a virtual entry was merged into. An account
  -- deleted later leaves the person (and their history) behind as virtual again.
  user_id      uuid references auth.users(id) on delete set null,
  -- Single-use invite, join-code alphabet, valid 7 days from link_code_at. Readable
  -- only through invite_person (column grant below), so a buyer cannot read a code
  -- and link themselves as someone else.
  link_code    text unique check (link_code ~ '^[A-HJ-NP-Z2-9]{6}$'),
  link_code_at timestamptz,
  created_by   uuid not null default auth.uid() references auth.users(id),
  created_at   timestamptz not null default now(),
  -- One entry per account per team: a second would split one human's credit.
  unique (team_id, user_id)
);
create index team_people_team_idx on team_people (team_id);
create index team_people_user_idx on team_people (user_id) where user_id is not null;

alter table team_people enable row level security;
-- Every write goes through the RPCs below; members read the roster — WITHOUT the
-- note. The lead writes it about a consignor ("pays 70%") and the app promises "Only
-- your team's leads see this", so buyers never get the column; a lead reads it
-- through team_people_notes (workflow test 2026-10-06: every member could read it).
create policy team_people_read on team_people for select using (is_team_member(team_id));
revoke all on team_people from anon, authenticated;
grant select (id, team_id, display_name, user_id, link_code_at, created_at)
  on team_people to authenticated;

-- NULL = the scanning account (buyer_id) is the buyer. Set = this person is (V1);
-- buyer_id stays as "added by". SET NULL only so a whole team's removal can cascade
-- in any order — remove_person refuses a person who still holds credit.
alter table lot_claims
  add column credited_person_id uuid references team_people(id) on delete set null;
create index lot_claims_credited_idx on lot_claims (credited_person_id)
  where credited_person_id is not null;

create or replace function person_team(p_person_id uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select team_id from team_people where id = p_person_id;
$$;

-- Same alphabet and length as a join code, unique across BOTH so a code typed into
-- the wrong box can never do the other thing.
create or replace function new_link_code()
returns text language plpgsql volatile set search_path = public as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  raw bytea;
  code text;
begin
  loop
    raw := uuid_send(gen_random_uuid());
    code := '';
    for i in 0..5 loop
      code := code || substr(alphabet, (get_byte(raw, i) % 32) + 1, 1);
    end loop;
    exit when not exists (select 1 from team_people where link_code = code)
          and not exists (select 1 from teams where join_code = code);
  end loop;
  return code;
end $$;

create or replace function link_code_ttl() returns interval language sql immutable as $$
  select interval '7 days'
$$;

-- The roster's notes, for a lead only (see the column grant above). Empty for anyone
-- else rather than an error: the app asks once per load and simply shows none.
create or replace function team_people_notes(p_team_id uuid)
returns table (id uuid, note text) language sql stable security definer set search_path = public as $$
  select p.id, p.note from team_people p
   where p.team_id = p_team_id and p.note is not null and is_team_lead(p_team_id);
$$;

-- ── Roster (lead only) ─────────────────────────────────────────────────────
create or replace function add_person(p_team_id uuid, p_display_name text, p_note text default null)
returns team_people language plpgsql security definer set search_path = public as $$
declare v_row team_people;
begin
  if not is_team_lead(p_team_id) then raise exception 'not_lead'; end if;
  insert into team_people (team_id, display_name, note)
    values (p_team_id, trim(p_display_name), nullif(trim(coalesce(p_note, '')), ''))
    returning * into v_row;
  v_row.link_code := null;
  return v_row;
end $$;

create or replace function update_person(p_person_id uuid, p_display_name text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_team_lead(person_team(p_person_id)) then raise exception 'not_lead'; end if;
  update team_people
     set display_name = trim(p_display_name), note = nullif(trim(coalesce(p_note, '')), '')
   where id = p_person_id;
end $$;

-- Removing someone who still holds credit would silently hand their slabs back to
-- whoever scanned them. The lead merges them into someone else, or untags, first.
create or replace function remove_person(p_person_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_team_lead(person_team(p_person_id)) then raise exception 'not_lead'; end if;
  if exists (select 1 from lot_claims
              where credited_person_id = p_person_id and state <> 'removed') then
    raise exception 'has_credit';
  end if;
  delete from team_people where id = p_person_id;
end $$;

-- The person row for a team MEMBER, made on first use. A virtual entry is merged
-- into a member by merging it into this row.
create or replace function member_person(p_team_id uuid, p_user_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not is_team_lead(p_team_id) then raise exception 'not_lead'; end if;
  select id into v_id from team_people where team_id = p_team_id and user_id = p_user_id;
  if v_id is not null then return v_id; end if;
  insert into team_people (team_id, display_name, user_id)
    select p_team_id, display_name, user_id from team_members
     where team_id = p_team_id and user_id = p_user_id
    returning id into v_id;
  if v_id is null then raise exception 'not_member'; end if;
  return v_id;
end $$;

-- ── Linking ────────────────────────────────────────────────────────────────
-- The lead's invite: the current code while it is still valid (asking twice must not
-- invalidate the code already texted to someone), else a fresh one.
create or replace function invite_person(p_person_id uuid, p_rotate boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_row team_people;
begin
  if not is_team_lead(person_team(p_person_id)) then raise exception 'not_lead'; end if;
  select * into v_row from team_people where id = p_person_id for update;
  if v_row.user_id is not null then raise exception 'already_linked'; end if;
  if p_rotate or v_row.link_code is null or v_row.link_code_at < now() - link_code_ttl() then
    update team_people set link_code = new_link_code(), link_code_at = now()
     where id = p_person_id returning * into v_row;
  end if;
  return jsonb_build_object('code', v_row.link_code,
                            'expires_at', v_row.link_code_at + link_code_ttl());
end $$;

-- The consignor's side. Guesses share join_team's budget (join_attempts,
-- 20260930000000) — same alphabet, same attack — and, as there, a counted failure is
-- RETURNED, not raised, because a raise would roll back the row that counts it.
create or replace function link_person(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_row  team_people;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  delete from join_attempts where user_id = v_uid and attempted_at < now() - interval '1 day';
  if (select count(*) from join_attempts
       where user_id = v_uid and attempted_at > now() - interval '1 hour') >= join_attempt_limit() then
    return jsonb_build_object('error', 'too_many_attempts');
  end if;
  select * into v_row from team_people
   where link_code = v_code and link_code_at > now() - link_code_ttl()
   for update;
  if not found then
    insert into join_attempts (user_id) values (v_uid);
    return jsonb_build_object('error', 'invalid_code');
  end if;
  if exists (select 1 from team_people where team_id = v_row.team_id and user_id = v_uid) then
    return jsonb_build_object('error', 'already_linked');
  end if;
  update team_people set user_id = v_uid, link_code = null, link_code_at = null
   where id = v_row.id;
  return jsonb_build_object('person_id', v_row.id, 'team_id', v_row.team_id,
                            'team_name', (select name from teams where id = v_row.team_id),
                            'display_name', v_row.display_name);
end $$;

-- The lead disconnects someone, or the linked person disconnects themselves.
-- History stays: the slabs remain credited to the (now virtual) person.
create or replace function unlink_person(p_person_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_row team_people;
begin
  select * into v_row from team_people where id = p_person_id;
  if not found then raise exception 'not_found'; end if;
  if not (is_team_lead(v_row.team_id) or coalesce(v_row.user_id = auth.uid(), false)) then
    raise exception 'not_lead';
  end if;
  if exists (select 1 from team_members where team_id = v_row.team_id and user_id = v_row.user_id) then
    -- A member's own row: unlinking it would orphan their credit from them.
    raise exception 'is_member';
  end if;
  update team_people set user_id = null, link_code = null, link_code_at = null
   where id = p_person_id;
end $$;

-- ── Merge ──────────────────────────────────────────────────────────────────
-- Two entries that are the same human. Every slab credited to `absorb` moves to
-- `keep`, an account carries over if only `absorb` had one, and `absorb` is gone.
-- Two different accounts are two different humans: refused.
create or replace function merge_people(p_keep_id uuid, p_absorb_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_keep   team_people;
  v_absorb team_people;
begin
  if p_keep_id = p_absorb_id then raise exception 'same_person'; end if;
  select * into v_keep   from team_people where id = p_keep_id;
  select * into v_absorb from team_people where id = p_absorb_id;
  if v_keep.id is null or v_absorb.id is null then raise exception 'not_found'; end if;
  if v_keep.team_id <> v_absorb.team_id then raise exception 'different_teams'; end if;
  if not is_team_lead(v_keep.team_id) then raise exception 'not_lead'; end if;
  perform pg_advisory_xact_lock(hashtextextended('team:' || v_keep.team_id::text, 0));
  if v_keep.user_id is not null and v_absorb.user_id is not null
     and v_keep.user_id <> v_absorb.user_id then
    raise exception 'linked_to_different_accounts';
  end if;
  update lot_claims set credited_person_id = p_keep_id where credited_person_id = p_absorb_id;
  delete from team_people where id = p_absorb_id;
  if v_keep.user_id is null and v_absorb.user_id is not null then
    update team_people set user_id = v_absorb.user_id, link_code = null, link_code_at = null
     where id = p_keep_id;
  end if;
end $$;

-- ── Credit (V1, V2) ────────────────────────────────────────────────────────
-- The lead tags slabs in a lot's receipt. NULL clears the tag (the scanner is the
-- buyer again). Only this column changes: lot_claims is otherwise written by
-- claim_lot_scan / release_lot_claim alone. A closed or archived lot can still be
-- tagged — this is record-keeping, not buying. Returns how many slabs changed.
create or replace function set_claim_person(p_lot_id uuid, p_claim_ids uuid[], p_person_id uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_team uuid := lot_team(p_lot_id);
  v_n    int;
begin
  if v_team is null or not is_team_lead(v_team) then raise exception 'not_lead'; end if;
  if p_person_id is not null and person_team(p_person_id) is distinct from v_team then
    raise exception 'not_on_team';
  end if;
  update lot_claims set credited_person_id = p_person_id
   where lot_id = p_lot_id and id = any(p_claim_ids) and state <> 'removed';
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ── The linked consignor's receipt (V5) ────────────────────────────────────
-- Everything a linked person may see, in one read-only call: the slabs credited to
-- them that were bought (confirmed or over-limit), with lot and team NAMES only. No
-- table policy is widened — `teams` holds the join code and a lot holds the team's
-- whole buy plan. max_buy_cents is the lead's buy figure and stays out.
create or replace function my_credited_cards()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'claim_id', c.id, 'cert', c.cert, 'grader', c.grader, 'grade_label', c.grade_label,
           'label', c.label, 'player', c.player, 'card_set', c.card_set, 'card_year', c.card_year,
           'card_number', c.card_number, 'image_url', c.image_url,
           'price_cents', c.price_cents, 'cl_confidence', c.cl_confidence,
           'cy_price_cents', c.cy_price_cents, 'cy_confidence', c.cy_confidence,
           'state', c.state, 'scanned_at', c.scanned_at, 'claimed_at', c.claimed_at,
           'lot_id', l.id, 'lot_name', l.name, 'value_basis', l.value_basis,
           'team_name', t.name, 'person_name', p.display_name,
           'added_by', coalesce(m.display_name, 'Former member'))
         order by c.claimed_at desc), '[]'::jsonb)
    from team_people p
    join lot_claims c on c.credited_person_id = p.id and c.state in ('confirmed', 'over_limit')
    join lots l on l.id = c.lot_id
    join teams t on t.id = l.team_id
    left join team_members m on m.team_id = l.team_id and m.user_id = c.buyer_id
   where p.user_id = auth.uid();
$$;

-- Which teams this account is linked to AS A CONSIGNOR — the app's cue to offer
-- "My cards". Names only: the roster row also holds the lead's private note. A
-- member's own row (made by member_person) is not a consignor link.
create or replace function my_links()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'person_id', p.id, 'team_name', t.name, 'display_name', p.display_name)
         order by t.name), '[]'::jsonb)
    from team_people p
    join teams t on t.id = p.team_id
   where p.user_id = auth.uid()
     and not exists (select 1 from team_members m where m.team_id = p.team_id and m.user_id = p.user_id);
$$;

-- ── Grants ─────────────────────────────────────────────────────────────────
revoke execute on function
  person_team(uuid), new_link_code(), link_code_ttl(), team_people_notes(uuid),
  add_person(uuid, text, text), update_person(uuid, text, text), remove_person(uuid),
  member_person(uuid, uuid), invite_person(uuid, boolean), link_person(text),
  unlink_person(uuid), merge_people(uuid, uuid), set_claim_person(uuid, uuid[], uuid),
  my_credited_cards(), my_links()
from public, anon;

grant execute on function
  team_people_notes(uuid), add_person(uuid, text, text), update_person(uuid, text, text), remove_person(uuid),
  member_person(uuid, uuid), invite_person(uuid, boolean), link_person(text),
  unlink_person(uuid), merge_people(uuid, uuid), set_claim_person(uuid, uuid[], uuid),
  my_credited_cards(), my_links()
to authenticated;
