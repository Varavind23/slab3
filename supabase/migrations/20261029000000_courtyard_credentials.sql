-- A user's OWN Courtyard session (2026-10-29; owner decisions C1–C4).
--
-- WHY. Since ~03:25 UTC 2026-10-29 Courtyard's /scanner/card-details answers 401
-- "authentication required" to every anonymous request (spike/README.md §2g). A
-- fresh Privy bearer from the user's own Courtyard login unlocks it, so Courtyard
-- becomes bring-your-own-account exactly like Card Ladder (C1), and its data —
-- cache hits included — goes only to connected users (C2).
--
-- WHAT IS STORED. There is no password: Courtyard logs in by emailed code (Privy
-- passwordless). The session is the Privy access token plus the `privy-*` cookies
-- — Courtyard's Privy app runs in HTTP-only COOKIE mode, so the refresh token is
-- the `privy-refresh-token` cookie, not a body field. All of it is sealed with
-- CL_ENC_KEY (`{enc}`, _shared/courtyard-session.ts): standing access to the
-- user's Courtyard account, which also holds their wallet.
--
-- WHY A LEASE, not "whoever refreshes wins". Privy refresh tokens are single-use
-- and rotated, so two calls refreshing at once (PricePacer, two devices) can burn
-- the session and sign the user out. `refresh_lease_until` lets exactly one call
-- refresh; the others wait for the row it writes. Taken with a conditional
-- UPDATE (… where lease is null or past), so it needs no RPC.
--
-- Worker table: RLS on with ZERO policies = deny-all, service role only, like
-- cardladder_credentials (20260821233917_initial_schema.sql).
create table courtyard_credentials (
  user_id             uuid primary key references auth.users(id) on delete cascade,
  session             jsonb not null,
  privy_user_id       text,
  -- "s•••@example.com": enough to say WHICH Courtyard account is connected,
  -- without keeping the address itself.
  email_hint          text,
  refresh_lease_until timestamptz,
  last_ok_at          timestamptz,
  failure_count       int not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

alter table courtyard_credentials enable row level security;
revoke all on courtyard_credentials from anon, authenticated;
