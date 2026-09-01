// Edge Function: fetch a card's Card Ladder VALUE for the calling user.
//
// Gating (ToS): only users who connected THEIR OWN Card Ladder account get a price —
// even a cache hit is withheld from users without an active connection, so nobody
// ever sees Card Ladder data their own subscription doesn't cover.
//
// TWO caches, because Card Ladder answers two different questions (2026-08-31):
//
//   cl_resolve_cache   cert → profileId + grade + the card's details. A cert is
//                      one physical slab, so this mapping never changes: cached
//                      with NO TTL, and a rescanned slab costs no CL request.
//   price_cache        {profileId}:{gradeCode} → the Value. 24h TTL, global,
//                      shared by every slab of the same card at the same grade.
//
// That split is the fix for V2's "a PSA 9 shows the PSA 10's price". Both caches
// used to be keyed on `card_key`, which is rebuilt in the app from text fields and
// carried NO grade at all (no source populated one — see clSourceKey's header), so
// every grade of a card collapsed onto one global row and whichever grade was
// scanned first answered for all of them. Keying on what Card Ladder itself uses
// makes that class of collision impossible rather than merely less likely.
//
// Every failure is a typed status the app degrades on cleanly (the UI already
// renders a no-price state).

import { resolveCert, estimate, clSourceKey, ClError, type ClCardIdentity } from "../_shared/cardladder.ts";
import { acquireIdToken, type SessionState } from "../_shared/session.ts";
import { admin, callerId, encKey, json } from "../_shared/http.ts";

const CACHE_TTL_MS = 24 * 60 * 60 * 1000; // Card Ladder Value moves slowly.
const DAILY_CAP = 200; // per-user request ceiling (keeps volume human-shaped, D10).
/** What the cached number means. Changed from "average_sale" 2026-08-29 — see the
 *  lookupCardValue header in _shared/cardladder.ts. */
const METRIC = "cl_value" as const;

interface Body {
  cert: string;
  grader: "psa" | "cgc";
  /** Manual refresh: skip the cache READ so the user gets a genuinely current
   *  value. The budget check still applies and the result still updates the cache. */
  force?: boolean;
  /** Accepted and ignored. Older builds send the app's card_key here; it is no
   *  longer a cache key for any source. Kept optional so a TestFlight build in the
   *  field keeps working after this function deploys. */
  cardKey?: string;
}

/** The identity block the app shows, including the GRADE — the only authoritative
 *  grade the pipeline gets, since the barcode carries a cert number and nothing
 *  else and PSA's cert page is walled. It rides this call; never fetch it
 *  separately, which would burn the daily budget. */
const identityOf = (r: {
  grade_label?: string | null; label?: string | null; player?: string | null;
  card_set?: string | null; card_year?: string | null; card_number?: string | null;
  image_url?: string | null;
}) => ({
  grade: r.grade_label ?? undefined,
  label: r.label ?? undefined,
  player: r.player ?? undefined,
  set: r.card_set ?? undefined,
  year: r.card_year ?? undefined,
  cardNumber: r.card_number ?? undefined,
  imageUrl: r.image_url ?? undefined,
});

const rowOf = (id: ClCardIdentity) => ({
  profile_id: id.profileId,
  grade: id.grade,
  grade_label: id.gradeLabel ?? null,
  label: id.label ?? null,
  player: id.player ?? null,
  card_set: id.set ?? null,
  card_year: id.year ?? null,
  card_number: id.number ?? null,
  image_url: id.imageUrl ?? null,
});

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ status: "method_not_allowed" }, 405);

  const userId = await callerId(req);
  if (!userId) return json({ status: "unauthorized" }, 401);

  let body: Body;
  try {
    body = await req.json();
  } catch {
    return json({ status: "bad_request" }, 400);
  }
  const { cert, grader, force = false } = body;
  if (!cert || !grader) return json({ status: "bad_request" }, 400);

  const db = admin();

  // 1) Require an active Card Ladder connection for THIS user.
  const { data: cred } = await db
    .from("cardladder_credentials")
    .select("encrypted_blob, session_state, failure_count")
    .eq("user_id", userId)
    .maybeSingle();
  if (!cred) return json({ status: "not_connected" });

  // 2) Who is this slab? Cert-keyed and immutable, so a known cert answers from
  //    cache with no token, no network and no budget — which is also what lets
  //    the price cache below be checked under the RIGHT key before we spend
  //    anything. A forced refresh does NOT re-resolve: the cert→card mapping
  //    cannot go stale, and re-resolving would spend the budget the user is
  //    forcing a refresh in order to spend on the price.
  const { data: known } = await db
    .from("cl_resolve_cache")
    .select("profile_id, grade, grade_label, label, player, card_set, card_year, card_number, image_url")
    .eq("grader", grader)
    .eq("cert", cert)
    .maybeSingle();

  // 3) Cache-first on the price, but only once we know the key it lives under.
  if (known && !force) {
    const { data: cached } = await db
      .from("price_cache")
      .select("price_cents, as_of, fetch_status, updated_at, metric, last_sale_cents, last_sale_at, source_confidence")
      .eq("source_key", clSourceKey(known.profile_id, known.grade))
      .eq("source", "cardladder")
      .maybeSingle();
    // A row cached under a DIFFERENT metric is not this metric's answer, however
    // fresh it is. Without this the 2026-08-29 switch was invisible: every card
    // kept replaying its `average_sale` row for the full 24h TTL, relabelled as
    // cl_value. Comparing the metric makes any future change self-healing.
    if (cached && cached.metric === METRIC &&
        Date.now() - new Date(cached.updated_at).getTime() < CACHE_TTL_MS) {
      if (cached.fetch_status === "ok" && cached.price_cents != null) {
        return json({
          status: "ok", priceCents: cached.price_cents, metric: METRIC,
          asOf: cached.as_of, cached: true, identity: identityOf(known),
          lastSaleCents: cached.last_sale_cents ?? null,
          lastSaleAt: cached.last_sale_at ?? null,
          confidence: cached.source_confidence ?? null,
        });
      }
      if (cached.fetch_status === "not_found") {
        // A cached "no price" still has a name, a grade and a picture. Card Ladder
        // is the only source naming cards while PSA is walled, so dropping the
        // identity here would leave the row anonymous for the whole TTL.
        return json({ status: "not_found", cached: true, identity: identityOf(known) });
      }
    }
  }

  // 4) Per-user daily budget.
  const today = new Date();
  today.setUTCHours(0, 0, 0, 0);
  const windowStart = today.toISOString();
  const { data: budget } = await db
    .from("scrape_budget")
    .select("request_count")
    .eq("source", "cardladder")
    .eq("user_id", userId)
    .eq("window_start", windowStart)
    .maybeSingle();
  if (budget && budget.request_count >= DAILY_CAP) return json({ status: "rate_limited" });

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
    // invalid_credentials / auth_expired → reconnect; a transient network error is
    // not the user's connection failing.
    if (kind === "network") return json({ status: "source_error" });
    return json({ status: kind === "rate_limited" ? "rate_limited" : "auth_expired" });
  }
  // Persist the (possibly rotated) session + clear the failure counter.
  await db
    .from("cardladder_credentials")
    .update({ session_state: sessionState, last_ok_at: new Date().toISOString(), failure_count: 0, updated_at: new Date().toISOString() })
    .eq("user_id", userId);

  // One outbound lookup = one unit of budget, whether or not it needed a resolve
  // as well. The cap is a ceiling on how many CARDS a user prices in a day, which
  // is what they actually experience; counting Card Ladder callables instead would
  // silently halve it.
  const spend = () =>
    db.from("scrape_budget").upsert(
      { source: "cardladder", user_id: userId, window_start: windowStart, request_count: (budget?.request_count ?? 0) + 1, cap: DAILY_CAP },
      { onConflict: "source,user_id,window_start" },
    );

  // 6) Resolve the cert if we have never seen it.
  let identity: ClCardIdentity | null;
  if (known) {
    identity = {
      profileId: known.profile_id, grade: known.grade, grader,
      gradeLabel: known.grade_label ?? undefined,
      label: known.label ?? undefined, player: known.player ?? undefined,
      set: known.card_set ?? undefined, year: known.card_year ?? undefined,
      number: known.card_number ?? undefined, imageUrl: known.image_url ?? undefined,
    };
  } else {
    try {
      identity = await resolveCert(idToken, cert, grader);
    } catch (e) {
      await spend();
      return json({ status: statusFor(e) });
    }
    if (!identity) {
      // Genuinely unknown cert. Nothing to cache: an unresolvable cert is more
      // often a mis-scan than a card Card Ladder has never heard of, and caching
      // it would make a one-off misread permanent.
      await spend();
      return json({ status: "not_found" });
    }
    await db.from("cl_resolve_cache").upsert({
      grader, cert, ...rowOf(identity), fetched_at: new Date().toISOString(),
    });
  }

  // 7) Estimate — the part that is actually per-card-per-grade and actually stale.
  const sourceKey = clSourceKey(identity.profileId, identity.grade);
  const nowIso = new Date().toISOString();
  try {
    const est = await estimate(idToken, identity);
    await spend();
    if (est.clValueCents === null) {
      await db.from("price_cache").upsert({
        source_key: sourceKey, source: "cardladder", metric: METRIC,
        price_cents: null, as_of: nowIso, fetch_status: "not_found", updated_at: nowIso,
      });
      // "No comps" is not "no card" — the identity stands on its own.
      return json({ status: "not_found", identity: identityOf(rowOf(identity)) });
    }
    await db.from("price_cache").upsert({
      source_key: sourceKey, source: "cardladder", metric: METRIC,
      price_cents: est.clValueCents, as_of: est.asOf, fetch_status: "ok",
      last_sale_cents: est.lastSalePriceCents, last_sale_at: est.lastSaleAt,
      source_confidence: est.confidence, updated_at: nowIso,
    });
    return json({
      status: "ok", priceCents: est.clValueCents, metric: METRIC, asOf: est.asOf,
      lastSaleCents: est.lastSalePriceCents, lastSaleAt: est.lastSaleAt,
      confidence: est.confidence, identity: identityOf(rowOf(identity)),
    });
  } catch (e) {
    // Transient failure: don't poison the cache. The app keeps the last known
    // number and marks the column stale, so it wants nothing from us here.
    await spend();
    return json({ status: statusFor(e) });
  }
});

/** Typed CL failure → the degraded status the app already handles. */
function statusFor(e: unknown): string {
  const kind = e instanceof ClError ? e.kind : "network";
  if (kind === "rate_limited") return "rate_limited";
  if (kind === "auth_expired" || kind === "invalid_credentials") return "auth_expired";
  return "source_error";
}
