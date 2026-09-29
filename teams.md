# LOTS_SPEC.md

Slabs — Lots & Teams module.

This document is authoritative for the Lots feature. Where it conflicts with
SPEC.md, SPEC.md wins on anything touching scanning, cert resolution, card_key,
pricing, or export. This document only adds.

Read CLAUDE.md first. Then this. Then BUILD.md phases at the end of this file.

---

## 1. What this is

Pete sources graded cards in bulk and sells into large buyers. Triumph is one of
those buyers. Triumph assigns Pete a weekly allocation: a set of price buckets,
each with a dollar cap, plus eligibility rules (grader, minimum grade, minimum
price confidence) and a submit deadline.

Pete has a team of four buyers who work card shows on the same weekend, often on
the same lot at the same time, in different physical locations.

Two problems:

1. Pete cannot take more than 3 of the same card at the same grade into a single
   lot. His buyers currently have no way to know what the others have bought.
2. Pete has no live view of how full each bucket is until everyone reports back.

This module solves both inside the existing Slabs app.

---

## 2. Hard invariants

These are non-negotiable. Violating any of them is a build failure.

1. **No new app and no new app target.** This is a module inside the existing
   repo, consuming the existing shared core.
2. **Additive schema only.** No edits to existing SwiftData `@Model` types. No
   new columns on existing Supabase tables. No changes to existing Worker route
   contracts. No changes to existing CSV export columns.
3. **Every lot scan also writes to normal inventory**, through the existing
   unchanged scan pipeline. Lot membership is an additional write, never a
   replacement store.
4. **Inventory stays local-first. Lot state is server-authoritative.** The only
   locally-authoritative lot table is the offline queue (`PendingLotScan`).
   Everything else in the lot domain is a read-only mirror of Supabase.
5. **One card_key implementation.** The lot dedupe key is
   `(card_key, grade)`. It must resolve through the existing shared card_key
   code path and be covered by `cardkey_vectors.json` at test runtime in all
   three languages. No reimplementation.
6. **Entitlement-gated, off by default.** With the `teams` entitlement off, the
   app must behave byte-for-byte like today's Slabs. No new tabs, no new
   network calls, no new local tables populated.
7. **Degrade, never block.** If lot sync fails for any reason, scanning and
   inventory continue to work exactly as they do today.

---

## 3. Domain model

### 3.1 Hierarchy

```
Team
└── Lot                    (one Triumph allocation sheet, one submit deadline)
    └── LotCategory        (Pokémon, Sports, etc.)
        └── LotBand        (a headline price range, e.g. $0–$100)
            └── LotBucket  (a sub-bucket inside the band, e.g. $50–$100)
```

The Triumph screen shows bands collapsed by default. Tapping a band expands it
into its sub-buckets. `$0 – $100` contains 3 buckets. `$100 – $240` contains 7.
The **bucket** is the real allocation unit. The band is a rollup.

### 3.2 Rule inheritance

Eligibility rules live at four levels and cascade downward. `NULL` means
inherit from the parent.

| Rule | Type | Default at lot level |
|---|---|---|
| `graders` | `text[]` | `{'PSA'}` |
| `min_grade` | `numeric` | `7` |
| `cl_conf_min` | `int` | `4` (scale 1–5) |
| `cy_conf_min` | `int` | `2` (scale 1–3) |

All four are editable per lot, per category, per band, and per bucket. The
screenshots show this in practice: the `$0–$100` band carries `7+ CERTS` only,
while `$100–$240` carries `CONF 4+ · 7+ CERTS`. Rules are genuinely per-band.

**Trap.** Triumph's "conf" is a per-price-source integer. It is NOT the existing
0–100 composite confidence score from SPEC.md, and it is NOT the green/yellow/red
band. Store and compare per-source integers. Do not conflate these two systems.
Do not reuse the composite score to evaluate `cl_conf_min` or `cy_conf_min`.

---

## 4. Supabase schema

All new tables. RLS on every one, scoped by team membership.

```sql
create type lot_status   as enum ('draft', 'active', 'closed');
create type lot_role     as enum ('lead', 'buyer');
create type lot_verdict  as enum ('allow', 'warn', 'block');
create type lot_scan_state as enum ('confirmed', 'over_limit', 'removed');
create type price_basis  as enum ('cl', 'cy');

create table teams (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  owner_id uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table team_members (
  team_id uuid not null references teams(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  role lot_role not null default 'buyer',
  created_at timestamptz not null default now(),
  primary key (team_id, user_id)
);

create table lots (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references teams(id) on delete cascade,
  name text not null,
  source text not null default 'triumph',
  status lot_status not null default 'draft',
  submit_deadline timestamptz,
  price_basis price_basis not null default 'cl',
  graders text[] not null default '{PSA}',
  min_grade numeric not null default 7,
  cl_conf_min int not null default 4,
  cy_conf_min int not null default 2,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table lot_categories (
  id uuid primary key default gen_random_uuid(),
  lot_id uuid not null references lots(id) on delete cascade,
  category text not null,
  graders text[], min_grade numeric, cl_conf_min int, cy_conf_min int,
  sort_order int not null default 0
);

create table lot_bands (
  id uuid primary key default gen_random_uuid(),
  lot_category_id uuid not null references lot_categories(id) on delete cascade,
  price_min_cents int not null,
  price_max_cents int not null,
  buckets_expanded boolean not null default false,
  graders text[], min_grade numeric, cl_conf_min int, cy_conf_min int,
  sort_order int not null default 0
);

create table lot_buckets (
  id uuid primary key default gen_random_uuid(),
  lot_band_id uuid not null references lot_bands(id) on delete cascade,
  price_min_cents int not null,
  price_max_cents int not null,
  allocated_cents bigint not null,
  reported_card_count int,
  graders text[], min_grade numeric, cl_conf_min int, cy_conf_min int,
  sort_order int not null default 0
);

-- Triumph's own reported numbers, frozen at screenshot time.
create table lot_snapshots (
  id uuid primary key default gen_random_uuid(),
  lot_id uuid not null references lots(id) on delete cascade,
  captured_at timestamptz not null,
  image_count int not null,
  raw jsonb not null,
  created_by uuid not null references auth.users(id)
);

create table lot_snapshot_values (
  snapshot_id uuid not null references lot_snapshots(id) on delete cascade,
  scope text not null check (scope in ('band','bucket')),
  scope_id uuid not null,
  used_cents bigint not null,
  allocated_cents bigint not null,
  card_count int,
  primary key (snapshot_id, scope, scope_id)
);

create table lot_scans (
  id uuid primary key default gen_random_uuid(),
  lot_id uuid not null references lots(id) on delete cascade,
  lot_bucket_id uuid references lot_buckets(id),
  cert text not null,
  grader text not null,
  card_key text not null,
  grade numeric not null,
  display_name text not null,
  price_cents int,
  price_source price_basis,
  cl_conf int,
  cy_conf int,
  state lot_scan_state not null default 'confirmed',
  verdict lot_verdict not null,
  warn_reasons text[] not null default '{}',
  buyer_id uuid not null references auth.users(id),
  scanned_at timestamptz not null,
  synced_at timestamptz not null default now(),
  device_id text
);

create unique index lot_scans_cert_uniq
  on lot_scans (lot_id, cert) where state <> 'removed';

create index lot_scans_dedupe
  on lot_scans (lot_id, card_key, grade) where state = 'confirmed';
```

### 4.1 RLS

- `teams`, `team_members`: readable by members. Writable by `lead` only.
- `lots`, `lot_categories`, `lot_bands`, `lot_buckets`, `lot_snapshots`,
  `lot_snapshot_values`: readable by team members. Writable by `lead` only.
- `lot_scans`: readable by team members. Insert only via the RPC in §5.
  Direct insert must be denied. A buyer may set `state = 'removed'` on their
  own rows. A lead may do so on any row in their team's lots.

Buyers see dollar amounts. No masking anywhere.

---

## 5. The claim RPC

`claim_lot_scan` is the only write path into `lot_scans`.

```
claim_lot_scan(
  p_lot_id uuid, p_cert text, p_card_key text, p_grade numeric,
  p_grader text, p_display_name text, p_price_cents int,
  p_cl_conf int, p_cy_conf int, p_scanned_at timestamptz, p_device_id text
) returns jsonb
```

Sequence, in one transaction:

1. Assert caller is a member of the lot's team. Assert `lots.status = 'active'`.
2. `pg_advisory_xact_lock(hashtext(p_lot_id::text || '|' || p_card_key || '|' || p_grade::text))`

   One line. Closes the concurrent-scan race completely at negligible cost.
   Keep it even though simultaneous duplicate scans are rare.
3. If a non-removed row already exists for `(p_lot_id, p_cert)`, return
   `duplicate_cert` with the existing row. This is the same physical slab.
4. Count `state = 'confirmed'` rows matching `(p_lot_id, p_card_key, p_grade)`.
   If `>= 3`, return `verdict = 'block'`, `reason = 'limit_reached'`, and the
   three existing rows including buyer name and `scanned_at`. **Insert nothing.**
5. Resolve the bucket. Take the price from the source named by
   `lots.price_basis`, walk `lot_buckets` for the matching category, and select
   the bucket whose `[price_min_cents, price_max_cents)` contains it.
6. Evaluate eligibility against the effective (cascaded) rules. See §6.
7. If `verdict = 'block'` from eligibility, insert nothing and return the reason.
8. Otherwise insert the row and return `verdict`, `warn_reasons`, the resolved
   bucket, and the bucket's updated used-total.

### 5.1 Over-limit reconciliation

The advisory lock prevents the live race. It does not prevent an offline queue
from replaying four scans of the same card after the fact. When the RPC is
called with a `p_scanned_at` older than now and the count is already at 3, insert
the row with `state = 'over_limit'` rather than rejecting it, so the card is not
silently lost. Surface `over_limit` rows in a dismissible banner on the lot
screen so a lead can decide what to drop.

---

## 6. Verdict model

Three outcomes, surfaced on the scan result.

| Verdict | Meaning | Buyer can proceed |
|---|---|---|
| `allow` | Green. Eligible, bucket resolved, under the limit. | Yes |
| `warn` | Amber. Something depends on Triumph's judgment, not ours. | Yes |
| `block` | Red. A rule we control is violated. | No, lot only |

**The governing principle: hard stop on anything Pete controls, amber warning on
anything that depends on Triumph's judgment.**

Block reasons:
- `limit_reached` — 3 of `(card_key, grade)` already confirmed in this lot
- `duplicate_cert` — this exact slab is already in this lot
- `grader_not_allowed` — grader not in the effective `graders` list
- `grade_below_min` — grade below effective `min_grade`
- `lot_closed`

Warn reasons:
- `near_bucket_boundary` — our price is within 5% or $5 (whichever is larger)
  of a bucket edge. Triumph may bucket it differently than we do.
- `confidence_below_min` — per-source confidence under the effective threshold.
  This is our estimate of price reliability, not Triumph's.
- `no_price` — price unmatched or unavailable, bucket unresolved. The scan is
  recorded with `lot_bucket_id = null` and needs manual bucket assignment.
- `bucket_over_allocation` — this purchase pushes the bucket past its dollar cap.

Grader and grade are objective facts read off the cert, so they block. Price and
confidence are our approximations of Triumph's book, so they warn.

A `block` verdict must still offer "Add to inventory only." The card goes into
normal Slabs inventory with no lot membership. Never drop a scan on the floor.

---

## 7. Lot setup: screenshot import

There is no file feed from Triumph. Pete opens Triumph, screenshots the
Rates & Allocation screen, and drops the images into Slabs.

This reuses the existing CGC OCR prefill plus ConfirmSheet pattern. Same shape,
different source image.

1. On-device `VNRecognizeTextRequest`. No Worker call, no new secrets, works
   offline.
2. Deterministic parser for the known Triumph layout. Extract:
   - Date line (`September 8, 2026`) → `submit_deadline` date
   - Countdown (`4d 23:17:34`) → cross-check against the date, warn on mismatch
   - Eligibility banner (`ONLY ACCEPTING PSA SLABS: NO CGC, NO BGS`) → `graders`
   - `CATEGORY Pokémon` → category
   - `SLABS · GRADE 7+` → `min_grade`
   - Band rows: price range, `$used / $allocated`, rule chips
     (`7+ CERTS`, `CONF 4+ · 7+ CERTS`), `N% used`, `N buckets`
   - Expanded bucket detail: `$50 – $100 · 7+ certs`,
     `$17,332.43 / $45,100 · 231 cards`
3. ConfirmSheet. Every parsed field is editable before commit. Nothing is written
   to Supabase until Pete confirms.

### 7.1 Multiple screenshots per lot

A single screenshot only captures the bands that happened to be expanded. The
three reference images prove this: image 1 shows `$100–$240` expanded, images 2
and 3 show `$0–$100` expanded.

Accept N images per import. Merge on `(category, price_min, price_max)`. If a
band appears only collapsed across all supplied images, store the band totals,
set `buckets_expanded = false`, and track that band's allocation at band level.
Show a prompt telling Pete which bands are missing bucket detail and that he can
add another screenshot.

### 7.2 Re-baselining

Triumph changes allocations mid-week occasionally. A new import against an
existing lot must merge, not replace. Match on `(category, price range)`, update
`allocated_cents` and rule fields, write a new `lot_snapshots` row, and leave
every `lot_scans` row untouched. Buckets that vanish from the new screenshot get
flagged, not deleted.

---

## 8. Two different numbers, always shown separately

The `$20,123.87 / $86,725` on the Triumph screen is **what Triumph has
accepted**. What Slabs knows is **what Pete's team has bought**. These diverge
the moment a submission is rejected or a card is regraded out of range.

On every bucket and band row, show team-bought as the live primary number and
Triumph-reported as a secondary line with its snapshot timestamp. Never merge
them into one bar. If the gap exceeds a threshold, show it explicitly and prompt
for a fresh screenshot.

---

## 9. UI

### 9.1 Layout parity

Pete asked for the lot dashboard to match the Triumph screen as closely as
possible so his buyers have no learning curve. Mirror the information hierarchy
and layout exactly:

- Sticky header: date, hourglass icon, `TIME LEFT TO SUBMIT` with a live countdown
- Eligibility banner, full width, accent-bordered
- Category selector with a chevron
- Segmented `Allocation` / `Rates` toggle (Rates disabled in v1, see §12)
- Band rows: price range on the left, `$used / $allocated` on the right, rule
  chips underneath, a progress bar, then `N% used` and `N buckets` with a
  disclosure chevron
- Expanded band: `Allocated` / `Used` legend, a grouped bar chart, min and max
  price labels, `Tap a bar for that bucket`
- Tapping a bar reveals that bucket's range, rule chips, `$used / $allocated`,
  and card count

**Use Caliper tokens for color, type, and spacing.** Do not copy Triumph's
orange. Layout parity, not visual cloning.

### 9.2 Lot selector on the Scan tab

Buyers work several lots on the same trip, so every scan must route to the right
lot. Put a persistent lot selector at the top of the Scan tab. It shows the
active lot and switches in one tap. The selector is the only change to the Scan
tab. The camera, zoom, torch, manual entry, and daily count are untouched.

With no lot selected, scanning behaves exactly as it does today.

### 9.3 Verdict sheet

On scan result, above the existing card detail:
- `allow`: a compact green row with the resolved bucket and `2 of 3 used`
- `warn`: amber row, the reason in plain language, proceed is the primary action
- `block` on `limit_reached`: a blocking sheet naming the card and grade, listing
  the three existing scans with buyer name and time, primary action
  `Add to inventory only`, secondary `Cancel`

### 9.4 Lot list

Lots grouped by status. Each row: name, deadline countdown, overall percent
filled, and the number of team members currently active on it.

---

## 10. Offline

Card show signal is unreliable but this is not a blocking concern. Keep it simple.

- `PendingLotScan` is a local SwiftData queue. It is the only locally
  authoritative lot table.
- An offline scan checks against the last synced lot state and renders the
  verdict as **amber `unverified`** regardless of outcome. Never show green
  without a server confirm.
- On reconnect, replay the queue oldest-first through `claim_lot_scan`.
- Results reconcile into `confirmed`, `over_limit`, or `blocked`. Show a summary
  on reconnect listing anything that did not land clean.
- The card is already in normal inventory either way, so nothing is ever lost.

---

## 11. Roles

Two roles only.

- **lead**: creates and edits lots, imports screenshots, closes lots, manages
  members, promotes another member to lead.
- **buyer**: sees all lots, all dollar amounts, all progress, and scans into lots.

Delegation must be short. Long-press a member in the team list, `Make lead`,
confirm. One sheet, two taps. No invitation flow, no approval step.

There is no purchase approval workflow. Pete's team knows what they are doing.

---

## 12. Do not build

- A second app or a second app target
- Any reservation, hold, or TTL system on card slots
- A purchase approval or sign-off workflow
- Push notifications of any kind
- A lot-specific CSV export. Lot cards land in normal inventory, so the existing
  export already covers it.
- The `Rates` tab. We have no screenshot of it. Render the toggle for layout
  parity, disabled, with no destination.
- A web dashboard
- Any change to `CardGroup`, the inventory models, the export column set, or the
  existing scan pipeline
- Any second implementation of card_key

---

## 13. Known traps

1. **card_key vs card_key + grade.** The lot limit keys on both. A card_key match
   at a different grade is a different slot. Add `(card_key, grade)` cases to
   `cardkey_vectors.json` and assert parity in SQL, Swift, and TypeScript.
2. **Triumph confidence is not our confidence.** See §3.2. Two separate systems.
   CL is a 1–5 scale, CY is 1–3. The existing 0–100 composite is unrelated.
3. **Bands are not buckets.** Allocation lives on buckets. Writing progress
   against bands will produce numbers that look right and are wrong.
4. **Price basis is per lot, not global.** Read `lots.price_basis` on every
   bucket resolution. Never hardcode CL.
5. **The advisory lock must be inside the same transaction as the insert.**
   `pg_advisory_xact_lock`, not `pg_advisory_lock`.
6. **Entitlement off means zero footprint.** No lot tables populated, no lot
   network calls, no lot UI. Verify with a network trace, not by eye.
7. **Currency in cents, integer, everywhere.** The screenshots show values like
   `$20,123.87`. No floats anywhere in the allocation path.
8. **Dark UI OCR.** Triumph's screen is near-black with low-contrast gray
   secondary text. Test the parser against all three reference images before
   assuming it generalizes.

---

## 14. Open questions

Do not guess. Build the configurable version and flag these.

1. **Price basis default.** Pete has not confirmed whether CL or CY decides the
   bucket. Default to CL, expose it per lot, do not hardcode.
2. **`231 cards`** on the bucket detail. Assumed to be a running count, not a
   cap. If it is a cap, `reported_card_count` becomes a second constraint
   dimension. Built as a display-only field until confirmed.
3. **The Rates tab.** No screenshot. Out of scope.
4. **Multi-category lots.** The category selector implies more than Pokémon, but
   we have only seen Pokémon. Schema supports N categories. UI should too.

---

## 15. Build phases

Sequential. Stop at each gate and confirm before proceeding.

**Phase 0 — Schema and RPC. No UI.**
Migrations for every table in §4, RLS policies, and `claim_lot_scan`.
*Gate:* a SQL test spawning 8 concurrent `claim_lot_scan` calls for the same
`(lot_id, card_key, grade)` results in exactly 3 confirmed rows and 5 blocks.

**Phase 1 — card_key parity.**
Add `(card_key, grade)` dedupe vectors to `cardkey_vectors.json`. Wire the
existing runtime-read harness so SQL, Swift, and TypeScript all assert against
the same file.
*Gate:* all three suites read the file at runtime, not from a copy, and pass.

**Phase 2 — Local models and sync.**
New SwiftData `@Model` types mirroring §4, plus `PendingLotScan`. Read-only
sync from Supabase. No writes.
*Gate:* lots, bands, and buckets render from local cache in airplane mode. A
migration test against a copy of a real device database passes with no data loss.

**Phase 3 — Lot list and lot dashboard.**
Full §9.1 layout parity. Caliper tokens. Static data is fine at this stage.
*Gate:* side-by-side screenshot comparison against the three reference images.

**Phase 4 — Screenshot import.**
On-device OCR, deterministic parser, ConfirmSheet, multi-image merge.
*Gate:* all three reference images parse correctly, merge into one lot with
2 bands, 3 + 7 buckets, `graders = {PSA}`, `min_grade = 7`, and
`cl_conf_min = 4` on the `$100–$240` band only.

**Phase 5 — Scan integration.**
Lot selector, `claim_lot_scan` wiring, verdict sheet, block and warn UI.
*Gate:* with no lot selected, a diff of the scan pipeline shows zero behavioral
change from the previous release. Every lot scan also appears in normal
inventory.

**Phase 6 — Offline queue.**
`PendingLotScan`, replay, reconciliation, `over_limit` banner.
*Gate:* 20 scans in airplane mode across two devices, including 5 copies of the
same card, reconcile to 3 confirmed and 2 `over_limit`, with all 20 in inventory.

**Phase 7 — Roles and rollout.**
Lead and buyer roles, delegation sheet, `teams` entitlement flag, separate
TestFlight lane.
*Gate:* with the entitlement off, a network trace shows zero lot-related
requests and the UI is identical to the current production build.