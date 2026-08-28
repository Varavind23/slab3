// Edge Function: fetch a card's Card Ladder average-sale price for the calling user.
//
// Gating (ToS): only users who connected THEIR OWN Card Ladder account get a price —
// even a cache hit is withheld from users without an active connection, so nobody
// ever sees Card Ladder data their own subscription doesn't cover. Cache-first
// (price_cache is global; the average is the same regardless of whose token fetched
// it), then a per-user daily budget, then the verified Firebase callable flow. Every
// failure is a typed status the app degrades on cleanly (the UI already renders a
// no-price state).

import { lookupAverageSale, ClError } from "../_shared/cardladder.ts";
import { acquireIdToken, type SessionState } from "../_shared/session.ts";
import { admin, callerId, encKey, json } from "../_shared/http.ts";

const CACHE_TTL_MS = 24 * 60 * 60 * 1000; // Card Ladder averages move slowly.
const DAILY_CAP = 200; // per-user request ceiling (keeps volume human-shaped, D10).

interface Body {
  cert: string;
  grader: "psa" | "cgc";
  cardKey: string;
  /** Manual refresh: skip the cache READ so the user gets a genuinely current
   *  value. The budget check still applies and the result still updates the cache. */
  force?: boolean;
}

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
  const { cert, grader, cardKey, force = false } = body;
  if (!cert || !grader || !cardKey) return json({ status: "bad_request" }, 400);

  const db = admin();

  // 1) Require an active Card Ladder connection for THIS user.
  const { data: cred } = await db
    .from("cardladder_credentials")
    .select("encrypted_blob, session_state, failure_count")
    .eq("user_id", userId)
    .maybeSingle();
  if (!cred) return json({ status: "not_connected" });

  // The identity block the app shows: Card Ladder's own label/player and its
  // canonical card render. It rides this price call — NEVER fetch it separately,
  // which would burn the daily budget and read to the user as prices going blank.
  const identityOf = (row: Record<string, unknown> | null | undefined) =>
    row
      ? {
          label: row.label ?? undefined,
          player: row.player ?? undefined,
          set: row.card_set ?? undefined,
          year: row.card_year ?? undefined,
          cardNumber: row.card_number ?? undefined,
          imageUrl: row.image_url ?? undefined,
        }
      : undefined;

  // 2) Cache-first: a fresh, ok'd global row serves everyone connected.
  //    A forced (manual) refresh skips this read and goes to the source.
  const { data: cached } = force
    ? { data: null }
    : await db
        .from("price_cache")
        .select("price_cents, as_of, fetch_status, updated_at")
        .eq("card_key", cardKey)
        .eq("source", "cardladder")
        .maybeSingle();
  if (cached && Date.now() - new Date(cached.updated_at).getTime() < CACHE_TTL_MS) {
    if (cached.fetch_status === "ok" && cached.price_cents != null) {
      // Serve the stored identity too, or a cached price leaves the row anonymous.
      const { data: known } = await db
        .from("card_identity_map")
        .select("label, player, card_set, card_year, card_number, image_url")
        .eq("card_key", cardKey)
        .eq("source", "cardladder")
        .maybeSingle();
      return json({
        status: "ok", priceCents: cached.price_cents, metric: "average_sale",
        asOf: cached.as_of, cached: true, identity: identityOf(known),
      });
    }
    if (cached.fetch_status === "not_found") return json({ status: "not_found", cached: true });
  }

  // 3) Per-user daily budget.
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

  // 4) Acquire a valid ID token (refresh-first, sign-in fallback).
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

  // 5) Resolve + estimate.
  const result = await lookupAverageSale(idToken, cert, grader);

  // Count the request against the budget (any outbound lookup counts).
  await db
    .from("scrape_budget")
    .upsert(
      { source: "cardladder", user_id: userId, window_start: windowStart, request_count: (budget?.request_count ?? 0) + 1, cap: DAILY_CAP },
      { onConflict: "source,user_id,window_start" },
    );

  const nowIso = new Date().toISOString();
  if (result.kind === "ok") {
    await db.from("price_cache").upsert({
      card_key: cardKey,
      source: "cardladder",
      metric: "average_sale",
      price_cents: result.priceCents,
      as_of: result.asOf,
      fetch_status: "ok",
      updated_at: nowIso,
    });
    await db.from("card_identity_map").upsert({
      card_key: cardKey,
      source: "cardladder",
      source_canonical_id: result.profileId,
      confidence: "exact",
      label: result.identity.label ?? null,
      player: result.identity.player ?? null,
      card_set: result.identity.set ?? null,
      card_year: result.identity.year ?? null,
      card_number: result.identity.number ?? null,
      image_url: result.identity.imageUrl ?? null,
      updated_at: nowIso,
    });
    return json({
      status: "ok", priceCents: result.priceCents, metric: "average_sale", asOf: result.asOf,
      identity: {
        label: result.identity.label, player: result.identity.player,
        set: result.identity.set, year: result.identity.year,
        cardNumber: result.identity.number, imageUrl: result.identity.imageUrl,
      },
    });
  }

  if (result.kind === "not_found") {
    await db.from("price_cache").upsert({
      card_key: cardKey,
      source: "cardladder",
      metric: "average_sale",
      price_cents: null,
      as_of: nowIso,
      fetch_status: "not_found",
      updated_at: nowIso,
    });
    return json({ status: "not_found" });
  }

  // rate_limited / auth_expired / network → typed degraded state; don't poison cache.
  return json({ status: result.error === "rate_limited" ? "rate_limited" : result.error === "auth_expired" ? "auth_expired" : "source_error" });
});
