// Which Courtyard bearer to send for one user, and when to refresh it.
//
// Why this is not _shared/session.ts (Card Ladder) reused: Card Ladder refreshes
// on every call and falls back to a stored password. Courtyard has no password,
// and Privy refresh tokens are single-use and rotated — so refreshing on every
// call is wasteful, and two calls refreshing AT ONCE can burn the session and sign
// the user out with no way back but a new emailed code. So:
//   1. Reuse the stored token until it is within REFRESH_MARGIN_MS of expiry.
//   2. Exactly one caller refreshes: it must win the row's lease
//      (courtyard_credentials.refresh_lease_until). Losers wait for the row the
//      winner writes, and fall back to the old token while it is still valid.
//   3. Only a refresh Privy REFUSES is a dead session (auth_expired). A network
//      failure never is — the user would be told to reconnect over a blip.
//
// Cross-runtime: imports only crypto.ts and courtyard-auth.ts; the database is
// behind the injected CyCredStore so worker/ vitest drives the lease logic.

import { encryptSecret, decryptSecret } from "./crypto.ts";
import { refreshSession, CyAuthError, type CySession, type AuthDeps } from "./courtyard-auth.ts";

/** Refresh this long before `exp`, so a token never expires mid-request. */
export const REFRESH_MARGIN_MS = 5 * 60_000;
/** Longer than a refresh can take (AUTH_TIMEOUT_MS), so a lease never lapses
 *  under a live refresh, and short enough that a crashed one frees the row soon. */
export const LEASE_MS = 20_000;
/** A loser re-reads this many times, this far apart, before giving up. */
const WAIT_TRIES = 4;
const WAIT_MS = 750;

export type SealedSession = { enc: string };

export async function sealCySession(s: CySession, key: string): Promise<SealedSession> {
  return { enc: await encryptSecret(JSON.stringify(s), key) };
}

/** null = unreadable (rotated key, damaged row): the caller treats it as a dead
 *  session, because there is no password to fall back to. */
export async function openCySession(stored: unknown, key: string): Promise<CySession | null> {
  const enc = (stored as SealedSession | null)?.enc;
  if (typeof enc !== "string") return null;
  try {
    const s = JSON.parse(await decryptSecret(enc, key));
    return typeof s?.token === "string" && typeof s?.expiresAt === "number" ? s : null;
  } catch {
    return null;
  }
}

/** The database half, injected. Implemented over Supabase in courtyard-store.ts. */
export interface CyCredStore {
  /** The sealed session, or null if the user has no row (disconnected meanwhile). */
  read(): Promise<unknown | null>;
  /** Take the refresh lease iff nobody holds a live one. */
  tryLease(untilMs: number, nowMs: number): Promise<boolean>;
  /** Persist a refreshed session and release the lease. */
  write(sealed: SealedSession): Promise<void>;
  /** Release the lease without writing (refresh failed). */
  release(): Promise<void>;
}

export interface AcquireDeps extends AuthDeps {
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
}

const fresh = (s: CySession, now: number) => s.expiresAt - now > REFRESH_MARGIN_MS;
const usable = (s: CySession, now: number) => s.expiresAt - now > 15_000;

/** The bearer to send. Throws CyAuthError: auth_expired (reconnect) or
 *  network/rate_limited (transient — never clears anything). */
export async function acquireCyToken(
  store: CyCredStore,
  encKey: string,
  deps: AcquireDeps = {},
): Promise<string> {
  const now = deps.now ?? Date.now;
  const sleep = deps.sleep ?? ((ms: number) => new Promise((r) => setTimeout(r, ms)));

  const stored = await store.read();
  if (stored === null) throw new CyAuthError("auth_expired", "not connected");
  const s = await openCySession(stored, encKey);
  if (!s) throw new CyAuthError("auth_expired", "stored session could not be read");
  if (fresh(s, now())) return s.token;

  if (await store.tryLease(now() + LEASE_MS, now())) {
    try {
      const next = await refreshSession(s, deps);
      await store.write(await sealCySession(next, encKey));
      return next.token;
    } catch (e) {
      await store.release();
      const err = e instanceof CyAuthError ? e : new CyAuthError("network", String(e));
      // A blip with a still-valid token in hand: use it, refresh next time.
      if (err.kind !== "auth_expired" && usable(s, now())) return s.token;
      throw err;
    }
  }

  // Someone else is refreshing. Wait for what they write.
  for (let i = 0; i < WAIT_TRIES; i++) {
    await sleep(WAIT_MS);
    const again = await store.read();
    if (again === null) throw new CyAuthError("auth_expired", "not connected");
    const t = await openCySession(again, encKey);
    if (t && fresh(t, now())) return t.token;
  }
  if (usable(s, now())) return s.token;
  // Not a verdict on the session — the winner may still succeed. Transient.
  throw new CyAuthError("network", "refresh in progress elsewhere");
}
