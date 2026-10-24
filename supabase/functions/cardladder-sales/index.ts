// Edge Function: fetch a card's real recent SALES from Card Ladder (2026-08-29).
//
// Why this is its own function and not part of cardladder-price: sales are fetched
// LAZILY, when a card's detail screen opens. Card Ladder answers RESOURCE_EXHAUSTED
// on its own quota and our per-user cap is 400/day, so folding a second callable
// into every scan would halve the number of slabs a user can run through a stack —
// and read to them as prices going blank, which is exactly the failure mode the
// cache-first rule already exists to prevent.
//
// Source: httpprofilesales {cert, grader} — discovered 2026-08-29 in Card Ladder's
// own web bundle (served un-walled from the Firebase default origin
// cardladder-71d53.web.app; app.cardladder.com is Turnstile-walled). It takes the
// scanned cert directly, needs no profileId, and filters to the same grade
// server-side, so the rows really are comps. See spike/README.md §1a.
//
// CACHED under {profileId}:{gradeCode}, not the app's card_key (2026-08-31). The
// call is made with a cert, but its ANSWER is the same for every slab of that card
// at that grade — which is exactly what the key says and what makes the row safe
// to share. Under card_key it was not: that key carried no grade at all, so a
// PSA 9's detail screen was served the PSA 10's comps. See the migration
// 20260831000000_cl_profile_keyed_cache.sql for the full account.
//
// Gating (ToS) is identical to cardladder-price: only users who connected THEIR
// OWN Card Ladder account get data, cache hits included.

import { fetchProfileSales, resolveCert, clSourceKey, ClError } from "../_shared/cardladder.ts";
import { acquireIdToken, sealSession, type SessionState } from "../_shared/session.ts";
import { admin, callerId, encKey, isSlab, json, logWrite } from "../_shared/http.ts";
import { CL_DAILY_CAP, clLogLine, nextUtcReset } from "../_shared/cl-limit.ts";

const CACHE_TTL_MS = 24 * 60 * 60 * 1000; // matches the price cache.
/** Shares the per-user Card Ladder budget with prices — one constant for both
 *  (cl-limit.ts; 200 until 2026-10-19). */
const DAILY_CAP = CL_DAILY_CAP;

interface Body {
  cert: string;
  grader: "psa" | "cgc";
  force?: boolean;
  /** Accepted and ignored — see cardladder-price. Kept optional so a TestFlight
   *  build already in the field keeps working after this function deploys. */
  cardKey?: string;
}

/** What the log line reports about a request, filled in as it runs. */
interface Trace {
  userId?: string | null;
  used?: number | null;
}

Deno.serve(async (req) => {
  const started = Date.now();
  const trace: Trace = {};
  const res = await handle(req, trace);
  // Same one line per request as cardladder-price. Only the status is read back —
  // a sales list can be 20 entries, so it is parsed but never logged.
  const body = await res.clone().json().catch(() => null);
  console.log(clLogLine({
    fn: "cardladder-sales", userId: trace.userId, status: body?.status,
    cached: body?.cached, reason: body?.stale ? "stale" : undefined,
    used: trace.used, ms: Date.now() - started,
  }));
  return res;
});

async function handle(req: Request, trace: Trace): Promise<Response> {
  if (req.method !== "POST") return json({ status: "method_not_allowed" }, 405);

  const userId = await callerId(req);
  trace.userId = userId;
  if (!userId) return json({ status: "unauthorized" }, 401);

  let body: Body;
  try {
    body = await req.json();
  } catch {
    return json({ status: "bad_request" }, 400);
  }
  const { cert, grader, force = false } = body;
  if (!isSlab(cert, grader)) return json({ status: "bad_request" }, 400);

  const db = admin();

  // 1) Require an active Card Ladder connection for THIS user. A failed read is
  //    transient, never "not connected" (see cardladder-price).
  const { data: cred, error: credError } = await db
    .from("cardladder_credentials")
    .select("encrypted_blob, session_state, failure_count")
    .eq("user_id", userId)
    .maybeSingle();
  if (credError) return json({ status: "source_error" });
  if (!cred) return json({ status: "not_connected" });

  // 2) Which card + grade is this slab? Cert-keyed and immutable, so this is
  //    normally already warm: cardladder-price fills it on the scan that put the
  //    card in the list, long before anyone opens its detail screen.
  const { data: known, error: knownError } = await db
    .from("cl_resolve_cache")
    .select("profile_id, grade")
    .eq("grader", grader)
    .eq("cert", cert)
    .maybeSingle();
  if (knownError) return json({ status: "source_error" });
  let sourceKey = known ? clSourceKey(known.profile_id, known.grade) : null;

  // 3) Cache-first. An empty array is a real cached answer — "Card Ladder has no
  //    comps for this card" is a fact worth caching, not a miss to retry all day.
  const { data: cached } = sourceKey && !force
    ? await db
        .from("card_sales_cache")
        .select("sales, fetch_status, fetched_at")
        .eq("source_key", sourceKey)
        .eq("source", "cardladder")
        .maybeSingle()
    : { data: null };
  if (
    cached &&
    cached.fetch_status === "ok" &&
    Date.now() - new Date(cached.fetched_at).getTime() < CACHE_TTL_MS
  ) {
    return json({ status: "ok", sales: cached.sales ?? [], cached: true });
  }

  // 4) Per-user daily budget (shared with cardladder-price), taken atomically
  //    before the call — see cardladder-price step 4.
  const { data: used, error: budgetError } = await db.rpc("spend_cardladder_budget", {
    p_user_id: userId, p_cap: DAILY_CAP,
  });
  trace.used = used ?? null;
  if (budgetError) {
    if (cached?.sales) return json({ status: "ok", sales: cached.sales, cached: true, stale: true });
    return json({ status: "source_error" });
  }
  if (used > DAILY_CAP) {
    // Serve a stale list rather than nothing: an old real comp beats an empty
    // panel, same rule prices follow when a refresh fails.
    if (cached?.sales) return json({ status: "ok", sales: cached.sales, cached: true, stale: true });
    return json({ status: "rate_limited", resetsAt: nextUtcReset(), cap: DAILY_CAP });
  }

  // 5) Acquire a valid ID token (refresh-first, sign-in fallback).
  let idToken: string, sessionState: SessionState;
  try {
    ({ idToken, sessionState } = await acquireIdToken(cred, encKey()));
  } catch (e) {
    await db
      .from("cardladder_credentials")
      .update({ failure_count: (cred.failure_count ?? 0) + 1, updated_at: new Date().toISOString() })
      .eq("user_id", userId);
    const kind = e instanceof ClError ? e.kind : "network";
    if (kind === "network") return json({ status: "source_error" });
    return json({ status: kind === "rate_limited" ? "rate_limited" : "auth_expired" });
  }
  await db
    .from("cardladder_credentials")
    .update({ session_state: await sealSession(sessionState, encKey()), last_ok_at: new Date().toISOString(), failure_count: 0, updated_at: new Date().toISOString() })
    .eq("user_id", userId);

  // 6) Resolve the cert if this slab has never been priced, so the comps land
  //    under the same key a price would use rather than a second key shape.
  if (!sourceKey) {
    try {
      const identity = await resolveCert(idToken, cert, grader);
      if (!identity) return json({ status: "ok", sales: [] });
      logWrite("cl_resolve_cache", (await db.from("cl_resolve_cache").upsert({
        grader, cert, profile_id: identity.profileId, grade: identity.grade,
        grade_label: identity.gradeLabel ?? null, label: identity.label ?? null,
        player: identity.player ?? null, card_set: identity.set ?? null,
        card_year: identity.year ?? null, card_number: identity.number ?? null,
        image_url: identity.imageUrl ?? null, fetched_at: new Date().toISOString(),
      })).error);
      sourceKey = clSourceKey(identity.profileId, identity.grade);
    } catch (e) {
      // Say WHY: an expired connection or Card Ladder's quota is something the
      // app acts on; "source_error" hid both (review 2026-10-02).
      return json({ status: statusFor(e) });
    }
  }

  // 7) Fetch.
  let sales;
  try {
    sales = await fetchProfileSales(idToken, cert, grader);
  } catch (e) {
    // A failed fetch must not erase a list the user already saw.
    if (cached?.sales) return json({ status: "ok", sales: cached.sales, cached: true, stale: true });
    return json({ status: statusFor(e) });
  }

  logWrite("card_sales_cache", (await db.from("card_sales_cache").upsert({
    source_key: sourceKey,
    source: "cardladder",
    sales,
    fetch_status: "ok",
    fetched_at: new Date().toISOString(),
  })).error);

  return json({ status: "ok", sales });
}

/** Typed CL failure → the degraded status the app already handles (as in
 *  cardladder-price). */
function statusFor(e: unknown): string {
  const kind = e instanceof ClError ? e.kind : "network";
  if (kind === "rate_limited") return "rate_limited";
  if (kind === "auth_expired" || kind === "invalid_credentials") return "auth_expired";
  return "source_error";
}
