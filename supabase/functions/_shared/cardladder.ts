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
  /** Card Ladder's picture of this card. Public — no auth, no proxying needed.
   *  The only cert-keyed image source that covers CGC.
   *
   *  The payload shape VARIES, which is why this goes through `cardImage()`:
   *    * `image` — a Firebase `/o/cards%2F...?alt=media` render (seen on
   *      collection-context responses, e.g. the saved fixture);
   *    * `imageUrl` — usually a CloudFront `/cert/<id>/...jpg` scan, which is
   *      what live lookups actually return (verified 2026-08-28), but on the
   *      fixture it is a Firebase `/o/sales%2F...` SALE COMP — a photo of a
   *      different slab's listing, which must never become this card's picture.
   *  Roughly 1 MB, so callers downscale before storing. */
  imageUrl?: string;
}

export interface ClEstimate {
  /** THE headline number: Card Ladder Value, in CENTS. This is the figure Card
   *  Ladder's own app labels simply "Value" — their bundle's field table gives
   *  `currentValue` the tooltip "Card Ladder Value of the card using our
   *  proprietary algorithm", and for a card in the user's CL collection
   *  `currentValue` and this `estimatedValue` are the same number (verified
   *  2026-08-29, cert 20360362: both 120).
   *
   *  Sourced from the estimate rather than from `httpbuildcollectioncard`'s
   *  `currentValue` on purpose: that field is COLLECTION-CONTEXT ONLY and comes
   *  back null for any card the user doesn't own (verified same day — certs
   *  96679812 and 154334127 both null there, while this is 89 and null
   *  respectively). Estimate answers for every card. */
  clValueCents: number | null;
  /** Card Ladder's own 1–5 confidence in the value above, or null. Same scale the
   *  app's ConfidenceMeter already draws. */
  confidence: number | null;
  /** The single most recent sale CL has on record — their "Last Sold" column. */
  lastSalePriceCents: number | null;
  lastSaleAt: string | null; // ISO 8601, from `lastSaleDate`
  /** Trailing-window average. NO LONGER the headline (see lookupCardValue), kept
   *  because it is real data and arrives on the same payload for free. */
  averageSaleCents: number | null;
  window: EstimateWindow;
  asOf: string; // ISO 8601 (server "now"; the estimate is a trailing window)
}

/** One real sale from Card Ladder's sales archive — an actual completed
 *  transaction, not a derived figure. */
export interface ClSale {
  priceCents: number;
  soldAt: string; // ISO 8601
  platform?: string; // "eBay"
  listingType?: string; // "Auction" | "BestOffer" | "FixedPrice"
  title?: string;
  url?: string;
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
    imageUrl: cardImage(result),
  };
}

/** PURE: pick the picture OF THIS CARD out of a resolve payload, or nothing.
 *
 *  Takes the card render when present, else the cert scan, and rejects Firebase
 *  `sales/` URLs outright: those are photos of somebody else's listing, and
 *  putting one on this row would be the image equivalent of showing a price
 *  that isn't this card's. Exported so the varying shapes are pinned by tests. */
export function cardImage(result: any): string | undefined {
  for (const candidate of [result?.image, result?.imageUrl]) {
    if (typeof candidate !== "string" || !candidate) continue;
    if (/\/o\/sales%2F/i.test(candidate)) continue; // another slab's listing photo
    return candidate;
  }
  return undefined;
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

/** PURE: pull Card Ladder Value, last sale and the window average out of
 *  httpcardestimate's result. Exported for fixture tests. Every money field goes
 *  through usdToCents, so 0 / missing → null (never a bogus price). */
export function parseEstimate(result: any, window: EstimateWindow = AVERAGE_SALE_WINDOW): ClEstimate {
  const conf = result?.confidence;
  return {
    clValueCents: usdToCents(result?.estimatedValue),
    confidence: typeof conf === "number" && Number.isFinite(conf) ? conf : null,
    lastSalePriceCents: usdToCents(result?.lastSalePrice),
    lastSaleAt: isoOrNull(result?.lastSaleDate),
    averageSaleCents: usdToCents(result?.[window]?.averagePrice),
    window,
    asOf: new Date().toISOString(),
  };
}

/** PURE: normalize whatever date shape Card Ladder sends into ISO 8601, or null. */
export function isoOrNull(v: unknown): string | null {
  if (typeof v !== "string" && typeof v !== "number") return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

// ── Sales archive ─────────────────────────────────────────────────────────────

/** How many sales we keep. The UI shows five; we store a few more so a later
 *  "show more" costs no extra call and no extra Card Ladder quota. */
export const MAX_SALES = 20;

/** Scanned cert + grader → Card Ladder's real recent sales for THIS card at THIS
 *  grade, newest first.
 *
 *  Discovered 2026-08-29 in Card Ladder's own web bundle (served un-walled from
 *  the Firebase default origin cardladder-71d53.web.app; app.cardladder.com is
 *  Turnstile-walled). The function documents its own contract in its 400 body:
 *  "Must provide one of: (cert + grader), (psaSpecId + grader), (gemRateId ...)".
 *  Cert + grader is exactly what the scanner already has, so this needs no
 *  profileId and no resolve step ahead of it.
 *
 *  Card Ladder does the grade filtering server-side — verified live, cert
 *  20360362 returned 20 sales all at g9, cert 96679812 six sales all at g10. So
 *  these are true comps, not a mixed-grade feed. */
export async function fetchProfileSales(
  idToken: string,
  cert: string,
  grader: ClGrader,
  deps?: Deps,
): Promise<ClSale[]> {
  const r = await callFn("httpprofilesales", { cert, grader }, idToken, deps);
  return parseSales(r);
}

/** PURE: shape httpprofilesales' result into ClSale[]. Exported for fixture tests.
 *  Drops any entry without a real price or a real date — a comp we can't state
 *  honestly is not a comp. Sorted newest first; an empty archive is a legitimate
 *  answer (cert 154334127 returns zero sales), never an error. */
export function parseSales(result: any): ClSale[] {
  const raw = Array.isArray(result?.sales) ? result.sales : [];
  const out: ClSale[] = [];
  for (const s of raw) {
    const priceCents = usdToCents(s?.price);
    const soldAt = isoOrNull(s?.date);
    if (priceCents === null || soldAt === null) continue;
    out.push({
      priceCents,
      soldAt,
      platform: s?.platform || undefined,
      listingType: s?.listingType || undefined,
      title: s?.title || undefined,
      url: s?.url || undefined,
    });
  }
  out.sort((a, b) => b.soldAt.localeCompare(a.soldAt));
  return out.slice(0, MAX_SALES);
}

/** USD number → integer cents, or null for 0/absent/non-finite. */
export function usdToCents(usd: unknown): number | null {
  const n = typeof usd === "number" ? usd : Number(usd);
  if (!Number.isFinite(n) || n <= 0) return null;
  return Math.round(n * 100);
}

// ── High-level: one call from a scanned card to Card Ladder's Value ───────────

export type ClLookup =
  | {
      kind: "ok";
      /** Card Ladder Value — see ClEstimate.clValueCents. */
      priceCents: number;
      profileId: string;
      asOf: string;
      identity: ClCardIdentity;
      estimate: ClEstimate;
    }
  /** No price. `identity` is present when Card Ladder KNOWS the card but has no
   *  recent comps — a different fact from "no such cert", and the card can still
   *  be named and pictured. Discarding it here is why resolved cards showed up
   *  as "Details pending" (fixed 2026-08-28). */
  | { kind: "not_found"; identity?: ClCardIdentity }
  | { kind: "error"; error: ClErrorKind; detail?: string };

/** Resolve + estimate in one shot, returning Card Ladder VALUE as the price.
 *  Never throws — every failure becomes a typed result the pipeline degrades on.
 *
 *  Was `lookupAverageSale`, returning `oneMonthData.averagePrice`, until
 *  2026-08-29. That window is empty for plenty of perfectly well-known cards, and
 *  since a 0 average maps to null, those cards displayed NO Card Ladder price at
 *  all — the first users' main complaint. Cert 96679812 is the worked example:
 *  one-month average 0, but Card Ladder Value $89, last sale $46, six real comps.
 *  The average was never the number Card Ladder itself shows; see spike/README §1a. */
export async function lookupCardValue(
  idToken: string,
  cert: string,
  grader: ClGrader,
  window: EstimateWindow = AVERAGE_SALE_WINDOW,
  deps?: Deps,
): Promise<ClLookup> {
  try {
    const identity = await resolveCert(idToken, cert, grader, deps);
    // Genuinely unknown cert: nothing to say about it.
    if (!identity) return { kind: "not_found" };
    const est = await estimate(idToken, identity, window, deps);
    // Known card, no value. Keep the identity — it is the only thing naming this
    // card at all when PSA is walled, and a missing price is not a missing card.
    if (est.clValueCents === null) return { kind: "not_found", identity };
    return {
      kind: "ok",
      priceCents: est.clValueCents,
      profileId: identity.profileId,
      asOf: est.asOf,
      identity,
      estimate: est,
    };
  } catch (e) {
    if (e instanceof ClError) return { kind: "error", error: e.kind, detail: e.message };
    return { kind: "error", error: "network", detail: e instanceof Error ? e.message : "unknown" };
  }
}
