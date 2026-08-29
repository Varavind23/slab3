// Edge Function: fetch a card's Card Ladder VALUE for the calling user.
//
// Gating (ToS): only users who connected THEIR OWN Card Ladder account get a price —
// even a cache hit is withheld from users without an active connection, so nobody
// ever sees Card Ladder data their own subscription doesn't cover. Cache-first
// (price_cache is global; the average is the same regardless of whose token fetched
// it), then a per-user daily budget, then the verified Firebase callable flow. Every
// failure is a typed status the app degrades on cleanly (the UI already renders a
// no-price state).

import { lookupCardValue, ClError } from "../_shared/cardladder.ts";
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
        .select("price_cents, as_of, fetch_status, updated_at, metric, last_sale_cents, last_sale_at, source_confidence")
        .eq("card_key", cardKey)
        .eq("source", "cardladder")
        .maybeSingle();
  // A row cached under a DIFFERENT metric is not this metric's answer, however
  // fresh it is. Without this the 2026-08-29 switch was invisible: every card
  // kept replaying its `average_sale` row for the full 24h TTL, relabelled as
  // cl_value — and a card whose average window was empty (cached `not_found`,
  // e.g. cert 96679812) kept reporting no Card Ladder price at all, which is
  // precisely the bug the metric change existed to fix. Comparing the metric
  // makes any future change self-healing instead of needing a manual purge.
  const usable = cached && cached.metric === METRIC;
  if (usable && Date.now() - new Date(cached.updated_at).getTime() < CACHE_TTL_MS) {
    if (cached.fetch_status === "ok" && cached.price_cents != null) {
      // Serve the stored identity too, or a cached price leaves the row anonymous.
      const { data: known } = await db
        .from("card_identity_map")
        .select("label, player, card_set, card_year, card_number, image_url")
        .eq("card_key", cardKey)
        .eq("source", "cardladder")
        .maybeSingle();
      return json({
        status: "ok", priceCents: cached.price_cents, metric: METRIC,
        asOf: cached.as_of, cached: true, identity: identityOf(known),
        lastSaleCents: cached.last_sale_cents ?? null,
        lastSaleAt: cached.last_sale_at ?? null,
        confidence: cached.source_confidence ?? null,
      });
    }
    if (cached.fetch_status === "not_found") {
      // A cached "no price" still has a name if we ever resolved one. Card Ladder
      // is the only source naming cards while PSA is walled, so dropping it here
      // would leave the row anonymous for the whole TTL.
      const { data: known } = await db
        .from("card_identity_map")
        .select("label, player, card_set, card_year, card_number, image_url")
        .eq("card_key", cardKey)
        .eq("source", "cardladder")
        .maybeSingle();
      return json({ status: "not_found", cached: true, identity: identityOf(known) });
    }
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
  const result = await lookupCardValue(idToken, cert, grader);

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
      metric: METRIC,
      price_cents: result.priceCents,
      as_of: result.asOf,
      fetch_status: "ok",
      last_sale_cents: result.estimate.lastSalePriceCents,
      last_sale_at: result.estimate.lastSaleAt,
      source_confidence: result.estimate.confidence,
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
      status: "ok", priceCents: result.priceCents, metric: METRIC, asOf: result.asOf,
      lastSaleCents: result.estimate.lastSalePriceCents,
      lastSaleAt: result.estimate.lastSaleAt,
      confidence: result.estimate.confidence,
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
      metric: METRIC,
      price_cents: null,
      as_of: nowIso,
      fetch_status: "not_found",
      updated_at: nowIso,
    });
    // "No comps" is not "no card". When Card Ladder resolved the cert but has no
    // recent sales, keep and return what it told us about the card.
    if (result.identity) {
      await db.from("card_identity_map").upsert({
        card_key: cardKey,
        source: "cardladder",
        source_canonical_id: result.identity.profileId,
        confidence: "exact",
        label: result.identity.label ?? null,
        player: result.identity.player ?? null,
        card_set: result.identity.set ?? null,
        card_year: result.identity.year ?? null,
        card_number: result.identity.number ?? null,
        image_url: result.identity.imageUrl ?? null,
        updated_at: nowIso,
      });
    }
    return json({
      status: "not_found",
      identity: result.identity && {
        label: result.identity.label, player: result.identity.player,
        set: result.identity.set, year: result.identity.year,
        cardNumber: result.identity.number, imageUrl: result.identity.imageUrl,
      },
    });
  }

  // rate_limited / auth_expired / network → typed degraded state; don't poison cache.
  return json({ status: result.error === "rate_limited" ? "rate_limited" : result.error === "auth_expired" ? "auth_expired" : "source_error" });
});
