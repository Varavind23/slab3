// Canonical Card Ladder client — the VERIFIED Firebase + Cloud Functions contract
// (live-checked against a real account 2026-08-24; see spike/README.md §1 revised).
//
// Why this lives here and is self-contained: the same code runs in TWO runtimes —
// Supabase Edge Functions (Deno) call it in production, and worker/ vitest tests it
// in Node. So it imports NOTHING and uses only web-standard globals (fetch, URL).
// `fetch` is injectable so tests run offline against captured fixtures.
//
// Access reality: Card Ladder's web app + search.cardladder.com are Cloudflare-
// Turnstile-walled, BUT its real data plane is Firebase Cloud Functions on Google
// hosts (us-central1-cardladder-71d53.cloudfunctions.net) that are NOT behind
// Cloudflare and take a plain `Authorization: Bearer <Firebase ID token>`. We use
// that; we never touch search.cardladder.com.

/** Public Firebase web API key = the project identifier, NOT a secret (it ships in
 *  every Card Ladder client and authorizes nothing on its own — the user's ID token
 *  is what grants access). */
export const CL_FIREBASE_API_KEY = "AIzaSyBqbxgaaGlpeb1F6HRvEW319OcuCsbkAHM";
const SIGNIN_URL = `https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${CL_FIREBASE_API_KEY}`;
const REFRESH_URL = `https://securetoken.googleapis.com/v1/token?key=${CL_FIREBASE_API_KEY}`;
const FN_BASE = "https://us-central1-cardladder-71d53.cloudfunctions.net";

export type ClGrader = "psa" | "cgc";

/** The four windows Card Ladder returns; the buyer's "average sale" = one month. */
export type EstimateWindow = "twoWeekData" | "oneMonthData" | "oneQuarterData" | "oneYearData";
export const AVERAGE_SALE_WINDOW: EstimateWindow = "oneMonthData";

export type FetchLike = typeof fetch;
interface Deps {
  fetch?: FetchLike;
}
const f = (d?: Deps): FetchLike => d?.fetch ?? fetch;

// ── Typed failures. Callers map these to the pipeline's SourceError kinds. ──────
export type ClErrorKind =
  | "invalid_credentials" // bad email/password at connect time
  | "auth_expired" // token/session no longer valid → user reconnects
  | "rate_limited" // Card Ladder daily quota (RESOURCE_EXHAUSTED)
  | "not_found" // valid lookup, no card/estimate
  | "network"; // transport/parse failure

export class ClError extends Error {
  constructor(readonly kind: ClErrorKind, message?: string) {
    super(message ?? kind);
    this.name = "ClError";
  }
}

export interface ClSession {
  idToken: string;
  refreshToken: string;
  /** epoch ms when idToken expires (with a small safety margin already applied). */
  expiresAt: number;
}

export interface ClCardIdentity {
  profileId: string; // e.g. "psa-299594"
  grade: string; // grade CODE, e.g. "g9" — REQUIRED as httpcardestimate's `condition`
  grader: ClGrader;
  player?: string;
  set?: string;
  year?: string;
  number?: string;
  label?: string;
  pop?: number;
  category?: string;
  variation?: string;
  /** Card Ladder's canonical render of this card. A Firebase Storage download
   *  URL ending in `?alt=media` with NO token, so the app fetches it directly —
   *  no proxying through an Edge Function (verified against the fixture
   *  2026-08-28). This is the only cert-keyed image source that covers CGC. */
  imageUrl?: string;
}

export interface ClEstimate {
  /** Average-sale price in CENTS for the chosen window, or null when unavailable.
   *  Never 0 — a 0/absent average is reported as null so we never show a bogus price. */
  averageSaleCents: number | null;
  window: EstimateWindow;
  lastSalePriceCents: number | null;
  asOf: string; // ISO 8601 (server "now"; the estimate is a trailing window)
}

// ── Auth ────────────────────────────────────────────────────────────────────
const EXPIRY_MARGIN_MS = 60_000; // refresh a minute early

/** Sign in with a user's OWN Card Ladder email/password (Firebase REST). Throws
 *  ClError("invalid_credentials") on a bad login, ClError("network") otherwise. */
export async function signIn(email: string, password: string, deps?: Deps): Promise<ClSession> {
  let res: Response;
  try {
    res = await f(deps)(SIGNIN_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email, password, returnSecureToken: true }),
    });
  } catch (e) {
    throw new ClError("network", e instanceof Error ? e.message : "signin fetch failed");
  }
  const body = await res.json().catch(() => null);
  if (!res.ok || !body?.idToken) {
    const code = body?.error?.message ?? "";
    // INVALID_PASSWORD / EMAIL_NOT_FOUND / INVALID_LOGIN_CREDENTIALS → user's fault
    if (/PASSWORD|EMAIL|LOGIN|IDENTIFIER|CREDENTIAL/i.test(code)) {
      throw new ClError("invalid_credentials", code);
    }
    throw new ClError("network", code || `signin ${res.status}`);
  }
  return session(body.idToken, body.refreshToken, Number(body.expiresIn ?? 3600));
}

/** Trade a refresh token for a fresh idToken. Throws ClError("auth_expired") when
 *  the refresh token itself is invalid/revoked (user must reconnect). */
export async function refresh(refreshToken: string, deps?: Deps): Promise<ClSession> {
  let res: Response;
  try {
    res = await f(deps)(REFRESH_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: refreshToken }),
    });
  } catch (e) {
    throw new ClError("network", e instanceof Error ? e.message : "refresh fetch failed");
  }
  const body = await res.json().catch(() => null);
  const idToken = body?.id_token ?? body?.idToken;
  const newRt = body?.refresh_token ?? body?.refreshToken ?? refreshToken;
  if (!res.ok || !idToken) throw new ClError("auth_expired", body?.error?.message ?? `refresh ${res.status}`);
  return session(idToken, newRt, Number(body.expires_in ?? body.expiresIn ?? 3600));
}

function session(idToken: string, refreshToken: string, expiresInSec: number): ClSession {
  return { idToken, refreshToken, expiresAt: Date.now() + expiresInSec * 1000 - EXPIRY_MARGIN_MS };
}

export const isExpired = (s: Pick<ClSession, "expiresAt">): boolean => Date.now() >= s.expiresAt;

// ── Callable Cloud Functions ──────────────────────────────────────────────────

/** POST a Firebase callable and unwrap `{result}`. Maps the two failure shapes we
 *  care about: HTTP 401/403 or an UNAUTHENTICATED envelope → auth_expired;
 *  RESOURCE_EXHAUSTED (returned as HTTP 200 with an `error` envelope) → rate_limited. */
async function callFn(name: string, data: unknown, idToken: string, deps?: Deps): Promise<any> {
  let res: Response;
  try {
    res = await f(deps)(`${FN_BASE}/${name}`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${idToken}` },
      body: JSON.stringify({ data }),
    });
  } catch (e) {
    throw new ClError("network", e instanceof Error ? e.message : `${name} fetch failed`);
  }
  if (res.status === 401 || res.status === 403) throw new ClError("auth_expired", `${name} ${res.status}`);
  const text = await res.text();
  let body: any;
  try {
    body = JSON.parse(text);
  } catch {
    // A Google callable always returns JSON; non-JSON means an interstitial/edge
    // failure — treat as auth so the UI prompts a reconnect rather than a silent 0.
    throw new ClError("auth_expired", `${name} returned non-JSON`);
  }
  const status = body?.error?.status;
  if (status === "RESOURCE_EXHAUSTED") throw new ClError("rate_limited", body.error.message);
  if (status === "UNAUTHENTICATED" || status === "PERMISSION_DENIED") throw new ClError("auth_expired", body.error.message);
  if (body?.error) throw new ClError("network", body.error.message ?? `${name} error`);
  if (!res.ok) throw new ClError("network", `${name} ${res.status}`);
  return body?.result;
}

/** Scanned cert + grader → Card Ladder card identity (profileId + grade code).
 *  Returns null when Card Ladder has no such cert. */
export async function resolveCert(idToken: string, cert: string, grader: ClGrader, deps?: Deps): Promise<ClCardIdentity | null> {
  const r = await callFn("httpbuildcollectioncard", { cert, grader }, idToken, deps);
  return parseResolve(r, grader);
}

/** PURE: shape httpbuildcollectioncard's result into a ClCardIdentity. Exported for
 *  fixture tests. Requires profileId + grade (the two fields the estimate needs). */
export function parseResolve(result: any, grader: ClGrader): ClCardIdentity | null {
  if (!result || !result.profileId || !result.grade) return null;
  return {
    profileId: String(result.profileId),
    grade: String(result.grade), // e.g. "g9"
    grader,
    player: result.player ?? undefined,
    set: result.set ?? undefined,
    year: result.year != null ? String(result.year) : undefined,
    number: result.number != null ? String(result.number) : undefined,
    label: result.label ?? undefined,
    pop: typeof result.pop === "number" ? result.pop : undefined,
    category: result.category ?? undefined,
    variation: result.variation || undefined,
    // `image` is the card render; `imageUrl` on the same payload is a SALE comp
    // photo (a pwcc/ebay listing shot), which is a different card's picture.
    imageUrl: result.image ?? undefined,
  };
}

/** card identity → windowed average-sale estimate. `condition` MUST be the grade
 *  code from resolveCert (e.g. "g9"); passing "PSA 9"/"9" makes Card Ladder return
 *  all-zeros (verified 2026-08-24). */
export async function estimate(
  idToken: string,
  card: Pick<ClCardIdentity, "profileId" | "grade" | "grader" | "label">,
  window: EstimateWindow = AVERAGE_SALE_WINDOW,
  deps?: Deps,
): Promise<ClEstimate> {
  const r = await callFn(
    "httpcardestimate",
    { profileId: card.profileId, gradingCompany: card.grader, condition: card.grade, description: card.label ?? "" },
    idToken,
    deps,
  );
  return parseEstimate(r, window);
}

/** PURE: pull the average-sale cents (chosen window) out of httpcardestimate's
 *  result. Exported for fixture tests. 0 / missing → null (never a bogus price). */
export function parseEstimate(result: any, window: EstimateWindow = AVERAGE_SALE_WINDOW): ClEstimate {
  const avgUsd = result?.[window]?.averagePrice;
  const lastUsd = result?.lastSalePrice;
  return {
    averageSaleCents: usdToCents(avgUsd),
    window,
    lastSalePriceCents: usdToCents(lastUsd),
    asOf: new Date().toISOString(),
  };
}

/** USD number → integer cents, or null for 0/absent/non-finite. */
export function usdToCents(usd: unknown): number | null {
  const n = typeof usd === "number" ? usd : Number(usd);
  if (!Number.isFinite(n) || n <= 0) return null;
  return Math.round(n * 100);
}

// ── High-level: one call from a scanned card to an average-sale price ──────────

export type ClLookup =
  | { kind: "ok"; priceCents: number; profileId: string; asOf: string; identity: ClCardIdentity }
  | { kind: "not_found" }
  | { kind: "error"; error: ClErrorKind; detail?: string };

/** Resolve + estimate in one shot. Never throws — every failure becomes a typed
 *  result the pipeline degrades on cleanly. */
export async function lookupAverageSale(
  idToken: string,
  cert: string,
  grader: ClGrader,
  window: EstimateWindow = AVERAGE_SALE_WINDOW,
  deps?: Deps,
): Promise<ClLookup> {
  try {
    const identity = await resolveCert(idToken, cert, grader, deps);
    if (!identity) return { kind: "not_found" };
    const est = await estimate(idToken, identity, window, deps);
    if (est.averageSaleCents === null) return { kind: "not_found" };
    return { kind: "ok", priceCents: est.averageSaleCents, profileId: identity.profileId, asOf: est.asOf, identity };
  } catch (e) {
    if (e instanceof ClError) return { kind: "error", error: e.kind, detail: e.message };
    return { kind: "error", error: "network", detail: e instanceof Error ? e.message : "unknown" };
  }
}
