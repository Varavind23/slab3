-- The grade WITH its qualifier, for BGS rows of the Courtyard cache (2026-10-21).
--
-- `grade` is a bare number ('9', '10', '9.5') because card_key, lot grade ranges
-- and the app all read it as one. Beckett's top grade comes in three kinds that
-- sell for very different money — a plain 10, a Pristine 10 and a Black Label 10
-- (Courtyard's comp groups '10', '10p', '10b'; cert 20281646 has all of them) — and
-- a bare '10' cannot say which a slab is. This column keeps that ('10b', '10p',
-- '9.5') so the app matches comps on it, while `grade` stays the number.
--
-- Written ONLY for grader = 'bgs' (courtyard-price reads and writes it for BGS
-- requests alone). PSA and CGC rows leave it null and no PSA/CGC query names it.
-- CGC's own Pristine gap (TODOS.md §4) could reuse it later; that is a separate
-- decision. Nullable with no default: a metadata-only change, no table rewrite.

alter table cy_scan_cache add column if not exists grade_key text;
