-- Identity fields for the scan rebuild (2026-08-28).
--
-- WHY: a scanned row showed a cert number and nothing else. Identity was
-- single-sourced to PSA, and PSA is the weakest of the three sources we already
-- call on every scan:
--   * PSA's cert page carries the assembled title in its <h1> ("2000 POKEMON
--     ROCKET #12 DARK SLOWBRO-HOLO") but we only stored the bare Subject, and it
--     carries NO photo of the card at all unless the cert has SecureScan imagery
--     (verified against a real cert page fixture — the repo's own test pins the
--     absence).
--   * Card Ladder's httpbuildcollectioncard returns label/player/set/number AND a
--     canonical card render, and it covers CGC. We parsed the text and dropped
--     the image; none of it ever reached the app.
--   * Courtyard's Algolia records carry a cert-keyed render.
-- So identity and imagery now resolve through a ranked chain, and both caches
-- need somewhere to keep what they learned.

-- PSA cert cache: the assembled title and the number printed on the card.
-- Rows written before today have title IS NULL under a 30-day TTL; psa-cert
-- treats that as a cache miss so the fix doesn't wait a month to appear.
alter table psa_cert_cache
  add column if not exists title       text,
  add column if not exists card_number text;

-- card_identity_map already keys canonical identity by (card_key, source) — it
-- held only the source's id. Carrying the identity itself lets cardladder-price
-- answer a CACHED price with a name and a picture; without it a cache hit
-- returns a number and the row stays anonymous.
alter table card_identity_map
  add column if not exists label       text,
  add column if not exists player      text,
  add column if not exists card_set    text,
  add column if not exists card_year   text,
  add column if not exists card_number text,
  add column if not exists image_url   text;
