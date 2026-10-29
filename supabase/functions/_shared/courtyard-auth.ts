// Courtyard login for the USER'S OWN account: Privy passwordless (email code).
//
// Why this exists: since ~03:25 UTC 2026-10-29 Courtyard's /scanner/card-details
// answers 401 to anonymous requests, and a Privy access token from the user's own
// Courtyard login unlocks it (spike/README.md §2g; owner decision C1). There is no
// password to store — Courtyard has none — so the server relays the login: init
// emails the user a code, they type it into Slabs, authenticate returns a session.
//
// Everything here was verified live 2026-10-29 (spike/courtyard/wall-probe.ts):
//   * Privy REFUSES a request without an Origin: 403 {"code":"missing_origin"}.
//     So these calls send Courtyard's web origin — owner decision C4 allows it
//     only because it is required; the User-Agent stays our own (SCANNER_UA).
//   * mode "no-signup" logs an existing account in. The connect flow must never
//     create a Courtyard account behind the user's back.
//   * Courtyard's Privy app runs in HTTP-only COOKIE mode: the body's
//     `refresh_token` is the literal "deprecated" and the real one arrives as a
//     `privy-refresh-token` Set-Cookie (Domain=privy.courtyard.io). The server
//     keeps the `privy-*` cookies itself and sends them back on refresh.
//   * Refresh is POST {privy.courtyard.io}/api/v1/sessions with the bearer and
//     cookies. Inside the token's lifetime it answers session_update_action
//     "ignore" and the same token.
//   * Errors: wrong code 422 {"code":"invalid_credentials"}; bad email 400
//     {"code":"invalid_data"}; a refresh without a valid session 401
//     {"code":"missing_or_invalid_token"}.
//
// Cross-runtime by the same contract as courtyard-scanner.ts: imports nothing
// Deno-only, uses web-standard globals, fetch injectable for worker/ vitest.

import { SCANNER_UA } from "./courtyard-scanner.ts";

/** Public client identifiers, observed off courtyard.io's login modal (§2a). */
export const PRIVY_APP_ID = "cldj2z0b70001mm08l39me9k5";
export const PRIVY_CLIENT_ID = "client-WY2UXndhQ4SHyZxA4a9fAyZtFTD8SFca7MVefZ9EyVom4";
/** init/authenticate verified here; sessions verified on Courtyard's custom
 *  domain, which is where the refresh cookie is scoped. */
const PRIVY_AUTH = "https://auth.privy.io/api/v1";
const PRIVY_SESSIONS = "https://privy.courtyard.io/api/v1";
const ORIGIN = "https://courtyard.io";

export type FetchLike = typeof fetch;
export interface AuthDeps {
  fetch?: FetchLike;
}
export const AUTH_TIMEOUT_MS = 10_000;
const timedFetch: FetchLike = (input, init) =>
  fetch(input, { ...init, signal: init?.signal ?? AbortSignal.timeout(AUTH_TIMEOUT_MS) });
const f = (d?: AuthDeps): FetchLike => d?.fetch ?? timedFetch;

export type CyAuthErrorKind =
  | "invalid_email" // 400 invalid_data on the address
  | "invalid_code" // 422 invalid_credentials: wrong or expired code
  | "no_account" // no-signup refused: no Courtyard account for that email
  | "auth_expired" // the stored session is dead; only a new code fixes it
  | "rate_limited" // 429
  | "network"; // transport, 5xx, or a shape we don't recognise — transient

export class CyAuthError extends Error {
  constructor(readonly kind: CyAuthErrorKind, message?: string) {
    super(message ?? kind);
    this.name = "CyAuthError";
  }
}

/** What the server keeps (sealed) for one connected user. */
export interface CySession {
  /** Privy access token: the api.courtyard.io bearer. ES256 JWT, ~1h. */
  token: string;
  /** ms epoch, from the token's own `exp`. */
  expiresAt: number;
  /** The `privy-*` cookies, by name. `privy-refresh-token` is the refresh token. */
  cookies: Record<string, string>;
  privyUserId?: string;
}

function headers(extra: Record<string, string> = {}): Record<string, string> {
  return {
    "Content-Type": "application/json",
    "privy-app-id": PRIVY_APP_ID,
    "privy-client-id": PRIVY_CLIENT_ID,
    "User-Agent": SCANNER_UA,
    Origin: ORIGIN,
    ...extra,
  };
}

/** PURE: a JWT's `exp` in ms, or undefined. atob is in Node and Deno alike. */
export function jwtExpiry(jwt: unknown): number | undefined {
  if (typeof jwt !== "string") return undefined;
  const part = jwt.split(".")[1];
  if (!part) return undefined;
  try {
    const b64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=");
    const exp = JSON.parse(atob(b64)).exp;
    return typeof exp === "number" ? exp * 1000 : undefined;
  } catch {
    return undefined;
  }
}

/** PURE: fold a response's Set-Cookie headers into a jar. Only `privy-*`
 *  cookies are kept (Cloudflare's __cf_bm etc. are not ours to hold); a
 *  "deleted" / Max-Age=0 cookie removes the entry, as a browser would. */
export function absorbCookies(jar: Record<string, string>, setCookies: string[]): Record<string, string> {
  const out = { ...jar };
  for (const c of setCookies) {
    const pair = c.split(";")[0];
    const i = pair.indexOf("=");
    if (i < 1) continue;
    const name = pair.slice(0, i).trim();
    const value = pair.slice(i + 1).trim();
    if (!name.startsWith("privy-")) continue;
    if (value === "deleted" || value === "" || /;\s*max-age=0\b/i.test(c)) delete out[name];
    else out[name] = value;
  }
  return out;
}

const setCookiesOf = (res: Response): string[] =>
  typeof res.headers.getSetCookie === "function" ? res.headers.getSetCookie() : [];

const cookieHeader = (jar: Record<string, string>): string =>
  Object.entries(jar).map(([k, v]) => `${k}=${v}`).join("; ");

async function bodyOf(res: Response): Promise<any> {
  try {
    return await res.json();
  } catch {
    return undefined;
  }
}

/** PURE: a Privy login/refresh body + cookies → a session, or undefined if the
 *  token is missing or not a JWT with an expiry. */
export function sessionFrom(body: any, cookies: Record<string, string>): CySession | undefined {
  const token = body?.token;
  const expiresAt = jwtExpiry(token);
  if (typeof token !== "string" || expiresAt === undefined) return undefined;
  const privyUserId = typeof body?.user?.id === "string" ? body.user.id : undefined;
  return { token, expiresAt, cookies, privyUserId };
}

/** Map a failed login call. 422 invalid_credentials is a wrong code; a
 *  no-signup refusal is worded as a missing user/account. Anything we do not
 *  recognise is "network": never tell a user their code was wrong on a guess. */
function loginError(status: number, body: any): CyAuthError {
  const code = String(body?.code ?? "");
  const msg = String(body?.error ?? "");
  if (status === 429) return new CyAuthError("rate_limited");
  if (status === 400 && code === "invalid_data") return new CyAuthError("invalid_email", msg);
  if (/sign.?up|not (been )?found|does not exist|no (such )?(user|account)/i.test(`${code} ${msg}`)) {
    return new CyAuthError("no_account", msg);
  }
  if (status === 422 || code === "invalid_credentials") return new CyAuthError("invalid_code", msg);
  return new CyAuthError("network", `HTTP ${status} ${code}`);
}

/** Step 1: Privy emails the user a code. */
export async function startLogin(email: string, deps?: AuthDeps): Promise<void> {
  let res: Response;
  try {
    res = await f(deps)(`${PRIVY_AUTH}/passwordless/init`, {
      method: "POST",
      headers: headers(),
      body: JSON.stringify({ email }),
    });
  } catch (e) {
    throw new CyAuthError("network", String(e));
  }
  if (res.ok) return;
  throw loginError(res.status, await bodyOf(res));
}

/** Step 2: the code the user typed → a session. Never creates an account. */
export async function verifyLogin(email: string, code: string, deps?: AuthDeps): Promise<CySession> {
  let res: Response;
  try {
    res = await f(deps)(`${PRIVY_AUTH}/passwordless/authenticate`, {
      method: "POST",
      headers: headers(),
      body: JSON.stringify({ email, code, mode: "no-signup" }),
    });
  } catch (e) {
    throw new CyAuthError("network", String(e));
  }
  const body = await bodyOf(res);
  if (!res.ok) throw loginError(res.status, body);
  const session = sessionFrom(body, absorbCookies({}, setCookiesOf(res)));
  if (!session) throw new CyAuthError("network", "authenticate: 200 without a usable token");
  if (!session.cookies["privy-refresh-token"]) {
    // Cookie mode is what makes the session outlive the hour. Without the cookie
    // the connection would silently die in 60 minutes — say so now instead.
    throw new CyAuthError("network", "authenticate: no privy-refresh-token cookie");
  }
  return session;
}

/** A new access token for a stored session. 401/403/400 = the session is dead
 *  (auth_expired); a "network" error must never be read as dead. */
export async function refreshSession(s: CySession, deps?: AuthDeps): Promise<CySession> {
  let res: Response;
  try {
    res = await f(deps)(`${PRIVY_SESSIONS}/sessions`, {
      method: "POST",
      headers: headers({ Authorization: `Bearer ${s.token}`, Cookie: cookieHeader(s.cookies) }),
      // Cookie mode: the SDK sends this literal, the real token rides the cookie.
      body: JSON.stringify({ refresh_token: "deprecated" }),
    });
  } catch (e) {
    throw new CyAuthError("network", String(e));
  }
  const body = await bodyOf(res);
  if (res.status === 429) throw new CyAuthError("rate_limited");
  if (res.status === 400 || res.status === 401 || res.status === 403) {
    throw new CyAuthError("auth_expired", `HTTP ${res.status} ${body?.code ?? ""}`);
  }
  if (!res.ok) throw new CyAuthError("network", `HTTP ${res.status}`);
  const next = sessionFrom(body, absorbCookies(s.cookies, setCookiesOf(res)));
  if (!next) throw new CyAuthError("network", "refresh: 200 without a usable token");
  return { ...next, privyUserId: next.privyUserId ?? s.privyUserId };
}

/** Best effort: end the Privy session on disconnect. Never throws — the row is
 *  deleted either way, and that is what stops us acting for the user. */
export async function logout(s: CySession, deps?: AuthDeps): Promise<void> {
  try {
    await f(deps)(`${PRIVY_SESSIONS}/sessions/logout`, {
      method: "POST",
      headers: headers({ Authorization: `Bearer ${s.token}`, Cookie: cookieHeader(s.cookies) }),
      body: JSON.stringify({ refresh_token: "deprecated" }),
    });
  } catch {
    // ignore
  }
}

/** PURE: "sam@example.com" → "s•••@example.com". Which account, not the address. */
export function emailHint(email: string): string {
  const [local, domain] = email.split("@");
  if (!domain) return "•••";
  return `${local.slice(0, 1)}•••@${domain}`;
}
