# Teams — lots, buy ranges, claims (LIVE since 2026-09-28, app 0.8)

Moved out of CLAUDE.md (2026-10-01) verbatim.

A lead's team buys into shared LOTS: each a list of buckets (buy ranges: CL-value,
grade, conf and year bounds, plus a card cap AND a dollar budget), at most 3 of one card
at one grade per lot. **It is on the live project**: the migrations
`supabase/migrations/20260925*` + `20260928000000_bucket_band.sql` were pushed
2026-09-28 (owner's yes), so real teams' lots and claims now live in those tables —
change them the way you would change `price_cache`: a new migration, never an edit of an
applied one, and a push only with a yes. `TeamsFeature.isAvailable` is on in every build
(`killSwitch` turns it inert; tests prove the off state makes no request). Every
signed-in user asks once per foreground whether they are on a team; being ON one is what
shows any team UI. Raising the team's Card Ladder budget is still an owner decision (an
Edge Function deploy). The owner's
design decisions (D1–D30, 2026-09-28) live in
`~/.claude/plans/pasted-content-id-4412-for-this-indexed-rabin.md`; `teams.md` is the
original brief and is superseded where they differ.

- **A lot is a shared group.** `LotFolders.sync` mirrors each visible lot as a local
  `Folder` (`teamLotId`). It must only run once lots are LOADED for this team
  (`TeamSync.shouldSyncGroups`): a lead's `isLead` flips before the lots arrive, and a
  sync against the empty launch list detached every lot group (reproduced 2026-09-28).
  `LotFolders.repair` heals phones that split; it runs after every sync, idempotently.
- **The server decides every claim** (`claim_lot_scan`, security definer) from its own
  caches: identity from `cl_resolve_cache`, CL Value + confidence from `price_cache`,
  keyed on CL's `clSourceKey` — never `card_key`. The phone sends lot, cert, grader.
- **`CardFiling` is the only writer of `card.folder`** — filing into a lot claims,
  leaving releases. Claims and releases run ONE AT A TIME through `LotClaimQueue` (a bulk
  file must not burst Card Ladder); releases are written to `PendingReleaseStore`
  BEFORE they are sent, so no signal at a show cannot orphan a slot.
- **Teams-first UI.** The Teams tab exists only on a team (`AppTab.visible`; non-team
  users keep the exact 4-tab app, pinned by `TeamsTabTests`). Members land on it. The
  Scan target (`AppState.scanTargetId`) IS the current lot (`CurrentLot`); lots are
  chosen on Teams, never in the Scan sheet; `ScanTargetRule` resumes / drops a closed lot
  / auto-picks a single open one. Teams leads with what can still be bought
  (`LotRoom`: either cap fills a bucket). Lots are built on one screen
  (`LotBuilderDraft` computes the ops; buckets carry client-chosen ids so a half-failed
  save retries without duplicates). Bands are a label on the bucket (`band`), not rows.
- **Money in lots is CL Value at claim**, labelled so. Team activity (lead-only — UI
  gating; RLS lets members read all claims) counts confirmed + over-limit; room left
  counts confirmed only. The lot buyer's reported figures are hidden (data kept).
- UI is driven end to end in the Simulator with a throwaway XCUITest target built in a
  scratchpad copy of `ios/` (never committed): `SLABS_BACKEND=local`, a local-only test
  account, camera pre-granted (`xcrun simctl privacy … grant camera`), and the keychain
  reset between accounts — a stale session silently loads nobody's team.
