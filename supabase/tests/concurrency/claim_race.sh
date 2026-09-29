#!/usr/bin/env bash
# Phase-0 gate for teams (plan: ~/.claude/plans/read-teams-md-lets-first-harmonic-horizon.md).
#
# WHY A SCRIPT AND NOT pgTAP. pgTAP runs inside ONE transaction, so it can never
# show two claims racing. The whole point of claim_lot_scan's advisory locks is the
# race: four buyers at four shows scanning the same card in the same second. This
# fires N claims over N real connections, released at the same instant by a
# barrier, and checks what landed.
#
#   Race 1: 8 buyers, 8 slabs of ONE card at one grade  → exactly 3 confirmed,
#           5 blocked limit_reached (the 3-per-lot rule).
#   Race 2: 8 buyers, 8 DIFFERENT cards into a range with max_cards = 2
#           → exactly 2 confirmed, 6 blocked range_full_count (the range cap).
#
# LOCAL ONLY. It writes (then deletes) rows, so it refuses anything but the local
# stack. Run from the repo root with `supabase start` up:
#   supabase/tests/concurrency/claim_race.sh
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:-supabase_db_slab3}"
N=8
TAG="race$(date +%s)$$"
PSQL=(docker exec -i "$DB_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -qAt)
BARRIER=770077   # advisory lock id the children wait on

uuid() { printf '%08x-0000-4000-8000-%012x' "$1" "$2"; }
TEAM=$(uuid 1 "$RANDOM$RANDOM")
LOT1=$(uuid 2 "$RANDOM$RANDOM");  RANGE1=$(uuid 3 "$RANDOM$RANDOM")
LOT2=$(uuid 4 "$RANDOM$RANDOM");  RANGE2=$(uuid 5 "$RANDOM$RANDOM")
user() { uuid 9 $((RANDOM * 100 + $1)); }
USERS=(); for i in $(seq 1 $N); do USERS+=("$(user "$i")"); done

cleanup() {
  "${PSQL[@]}" <<SQL >/dev/null 2>&1 || true
delete from teams where id = '$TEAM';
delete from auth.users where email like '%@$TAG.test';
delete from cl_resolve_cache where profile_id like '$TAG-%';
delete from price_cache where source_key like '$TAG-%';
SQL
}
trap cleanup EXIT

# ── Seed (committed — the racers are separate connections) ──────────────────
{
  echo "begin;"
  for i in $(seq 1 $N); do
    u=${USERS[$((i-1))]}
    echo "insert into auth.users (id, email) values ('$u', 'b$i@$TAG.test');"
    echo "insert into cardladder_credentials (user_id, encrypted_blob) values ('$u', 'x');"
    # Race 1: slab i of the SAME card. Race 2: card i, a different identity each.
    echo "insert into cl_resolve_cache (grader, cert, profile_id, grade, grade_label, card_year)
          values ('psa', '${TAG}a$i', '$TAG-same', 'g9', '9', '1999'),
                 ('psa', '${TAG}b$i', '$TAG-c$i',  'g9', '9', '1999');"
    echo "insert into price_cache (source_key, source, metric, price_cents, fetch_status, source_confidence)
          values ('$TAG-c$i:g9', 'cardladder', 'cl_value', 5000, 'ok', 4);"
  done
  echo "insert into price_cache (source_key, source, metric, price_cents, fetch_status, source_confidence)
        values ('$TAG-same:g9', 'cardladder', 'cl_value', 5000, 'ok', 4);"
  echo "insert into teams (id, name, join_code, created_by) values ('$TEAM', '$TAG', new_join_code(), '${USERS[0]}');"
  for i in $(seq 1 $N); do
    role=buyer; [ "$i" = 1 ] && role=lead
    echo "insert into team_members (team_id, user_id, role, display_name) values ('$TEAM', '${USERS[$((i-1))]}', '$role', 'B$i');"
  done
  echo "insert into lots (id, team_id, name, status, created_by) values
          ('$LOT1', '$TEAM', 'race limit', 'active', '${USERS[0]}'),
          ('$LOT2', '$TEAM', 'race range', 'active', '${USERS[0]}');"
  echo "insert into lot_buy_ranges (id, lot_id, name, max_cards, budget_cents) values
          ('$RANGE1', '$LOT1', 'wide', 400, 99999999),
          ('$RANGE2', '$LOT2', 'two only', 2, 99999999);"
  echo "commit;"
} | "${PSQL[@]}"

race() {  # $1 lot id, $2 cert prefix letter → prints one outcome line per racer
  local lot=$1 kind=$2 out; out=$(mktemp -d)
  # The barrier: hold an exclusive advisory lock in one session while all N
  # racers queue on a shared xact lock, then let go — they start together.
  "${PSQL[@]}" -c "select pg_advisory_lock($BARRIER); select pg_sleep(3);" >/dev/null &
  local holder=$!
  until [ "$("${PSQL[@]}" -c "select count(*) from pg_locks where locktype = 'advisory' and objid = $BARRIER and granted")" -ge 1 ]; do :; done
  for i in $(seq 1 $N); do
    "${PSQL[@]}" >"$out/$i" 2>&1 <<SQL &
begin;
select pg_advisory_xact_lock_shared($BARRIER);
set local role authenticated;
set local request.jwt.claims to '{"sub":"${USERS[$((i-1))]}","role":"authenticated"}';
select r->>'outcome' || ':' || coalesce(r->>'reason', '')
  from (select claim_lot_scan('$lot', '${TAG}${kind}$i', 'psa') as r) s;
commit;
SQL
  done
  wait
  cat "$out"/*; rm -rf "$out"
  wait "$holder" 2>/dev/null || true
}

fail=0
check() {  # $1 label, $2 actual, $3 expected
  if [ "$2" = "$3" ]; then echo "ok   - $1 ($2)"; else echo "FAIL - $1: got $2, want $3"; fail=1; fi
}

echo "# Race 1: $N buyers, $N slabs of one card, one lot"
r1=$(race "$LOT1" a)
check "confirmed" "$(grep -c '^confirmed:' <<<"$r1" || true)" 3
check "blocked limit_reached" "$(grep -c '^blocked:limit_reached' <<<"$r1" || true)" 5
check "rows in lot_claims" "$("${PSQL[@]}" -c "select count(*) from lot_claims where lot_id = '$LOT1' and state = 'confirmed'")" 3

echo "# Race 2: $N buyers, $N different cards, a range of max 2"
r2=$(race "$LOT2" b)
check "confirmed" "$(grep -c '^confirmed:' <<<"$r2" || true)" 2
check "blocked range_full_count" "$(grep -c '^blocked:range_full_count' <<<"$r2" || true)" 6
check "rows in lot_claims" "$("${PSQL[@]}" -c "select count(*) from lot_claims where lot_id = '$LOT2' and state = 'confirmed'")" 2

if [ $fail = 0 ]; then echo "# PASS"; else printf '# FAIL\n%s\n%s\n' "$r1" "$r2"; exit 1; fi
