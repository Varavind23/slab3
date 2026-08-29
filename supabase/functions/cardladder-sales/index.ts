// Edge Function: fetch a card's real recent SALES from Card Ladder (2026-08-29).
//
// Why this is its own function and not part of cardladder-price: sales are fetched
// LAZILY, when a card's detail screen opens. Card Ladder answers RESOURCE_EXHAUSTED
// on its own quota and our per-user cap is 200/day, so folding a second callable
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
// Gating (ToS) is identical to cardladder-price: only users who connected THEIR
// OWN Card Ladder account get data, cache hits included.

import { fetchProfileSales, ClError } from "../_shared/cardladder.ts";
import { acquireIdToken, type SessionState } from "../_shared/session.ts";
import { admin, callerId, encKey, json } from "../_shared/http.ts";

const CACHE_TTL_MS = 24 * 60 * 60 * 1000; // matches the price cache.
const DAILY_CAP = 200; // shares the per-user Card Ladder budget with prices.

interface Body {
  cert: string;
  grader: "psa" | "cgc";
  cardKey: string;
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

  // 2) Cache-first. An empty array is a real cached answer — "Card Ladder has no
  //    comps for this card" is a fact worth caching, not a miss to retry all day.
  const { data: cached } = force
    ? { data: null }
    : await db
        .from("card_sales_cache")
        .select("sales, fetch_status, fetched_at")
        .eq("card_key", cardKey)
        .eq("source", "cardladder")
        .maybeSingle();
  if (
    cached &&
    cached.fetch_status === "ok" &&
    Date.now() - new Date(cached.fetched_at).getTime() < CACHE_TTL_MS
  ) {
    return json({ status: "ok", sales: cached.sales ?? [], cached: true });
  }

  // 3) Per-user daily budget (shared with cardladder-price).
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
  if (budget && budget.request_count >= DAILY_CAP) {
    // Serve a stale list rather than nothing: an old real comp beats an empty
    // panel, same rule prices follow when a refresh fails.
    if (cached?.sales) return json({ status: "ok", sales: cached.sales, cached: true, stale: true });
    return json({ status: "rate_limited" });
  }

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
    if (kind === "network") return json({ status: "source_error" });
    return json({ status: kind === "rate_limited" ? "rate_limited" : "auth_expired" });
  }
  await db
    .from("cardladder_credentials")
    .update({ session_state: sessionState, last_ok_at: new Date().toISOString(), failure_count: 0, updated_at: new Date().toISOString() })
    .eq("user_id", userId);

  // 5) Fetch.
  let sales;
  try {
    sales = await fetchProfileSales(idToken, cert, grader);
  } catch (e) {
    const kind = e instanceof ClError ? e.kind : "network";
    // A failed fetch must not erase a list the user already saw.
    if (cached?.sales) return json({ status: "ok", sales: cached.sales, cached: true, stale: true });
    if (kind === "rate_limited") return json({ status: "rate_limited" });
    if (kind === "auth_expired" || kind === "invalid_credentials") return json({ status: "auth_expired" });
    return json({ status: "source_error" });
  } finally {
    await db
      .from("scrape_budget")
      .upsert(
        { source: "cardladder", user_id: userId, window_start: windowStart, request_count: (budget?.request_count ?? 0) + 1, cap: DAILY_CAP },
        { onConflict: "source,user_id,window_start" },
      );
  }

  await db.from("card_sales_cache").upsert({
    card_key: cardKey,
    source: "cardladder",
    sales,
    fetch_status: "ok",
    fetched_at: new Date().toISOString(),
  });

  return json({ status: "ok", sales });
});
