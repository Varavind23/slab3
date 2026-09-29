-- A bucket's band, as a label on the bucket itself (teams-first plan, D11, 2026-09-28).
--
-- WHY. Bands group a lot's buckets under one headline price row (the dashboard the
-- team already reads daily). They were rows of their own (lot_bands, 20260925120000)
-- with a separate editor, categories, and a long-press "Move to band" — the most
-- steps in lot setup, for what is only a grouping. The owner wanted setup to be one
-- screen, so a bucket now simply carries an optional band label ("$0–$100"): buckets
-- with the same label group together; no label stands alone.
--
-- Stored on the library template too, so a saved bucket keeps its band when it is
-- dropped into the next lot. The band's price span and allocation are still derived
-- from its buckets in the app (LotDashboard.build) — the label only groups.
--
-- lot_bands stays in place, unread by the app from this migration on; dropping it is
-- a separate, later decision (TODOS.md). Nothing here touches claim_lot_scan: bands
-- never affected which bucket a card lands in.
--
-- LOCAL ONLY, like every Teams migration until the owner says it ships.

alter table buy_range_templates
  add column band text check (band is null or length(trim(band)) > 0);

alter table lot_buy_ranges
  add column band text check (band is null or length(trim(band)) > 0);
