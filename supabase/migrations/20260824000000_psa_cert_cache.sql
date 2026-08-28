-- Shared PSA identity cache. Clients never read this table directly; the
-- authenticated psa-cert Edge Function validates callers and owns all access.
create table psa_cert_cache (
  cert_number text primary key,
  subject text,
  card_set text,
  card_year int,
  grade text,
  image_url text,
  fetch_status fetch_status not null default 'pending',
  updated_at timestamptz not null default now(),
  constraint psa_cert_number_format check (cert_number ~ '^[0-9]{7,10}$')
);

alter table psa_cert_cache enable row level security;

