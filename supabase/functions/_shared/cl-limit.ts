// The per-user Card Ladder daily budget, and what a request says when it is spent.
//
// Why this exists (2026-10-19). Users' Card Ladder column went to em dashes on busy
// weekends while Courtyard priced fine. Edge logs + scrape_budget showed ~98% of CL
// failures were OUR cap, not Card Ladder: since the atomic spend_cardladder_budget
// (20260930000000 §6, deployed 10/02) 200/day was a hard stop, and heavy users
// needed 300–400. A refused card had no earlier value, so it showed nothing, and
// nothing ever re-priced it after the reset. Owner decisions that day: the cap goes
// to 400, and over it a user is shown Card Ladder's last cached value WITH ITS DATE
// rather than nothing.
//
// Cross-runtime like cardladder.ts: no imports, Web-API only, so worker/ vitest
// tests the exact code Deno ships. The function bodies have no tests — the
// decisions live here instead.

/** One unit = one Card Ladder lookup for a card nobody priced in the last 24h
 *  (cache hits are free). Shared by cardladder-price and cardladder-sales; it is
 *  ONE constant so the two can never disagree about a user's day again. */
export const CL_DAILY_CAP = 400;

/** When the budget window rolls over: spend_cardladder_budget keys the window on
 *  date_trunc('day', now() at time zone 'utc'), so the next 00:00 UTC. */
export function nextUtcReset(now: Date = new Date()): string {
  const next = new Date(now.getTime());
  next.setUTCHours(24, 0, 0, 0);
  return next.toISOString();
}

/** The price_cache columns cardladder-price reads. */
export interface ClPriceRow {
  price_cents: number | null;
  as_of: string | null;
  updated_at: string;
  fetch_status: string;
  metric: string;
  last_sale_cents?: number | null;
  last_sale_at?: string | null;
  source_confidence?: number | null;
}

/** Why a dated value was served instead of a current one. */
export type DatedReason = "rate_limited" | "source_error";

/** PURE: the reply that hands back Card Ladder's last real answer, of ANY age,
 *  labelled as such. Null when there is no honest value to hand back — a row under
 *  another metric (the 2026-08-29 switch: an `average_sale` figure is not a Value),
 *  a cached "no value", or no price at all.
 *
 *  `asOf` is when Card Ladder gave that number, never "now": the date belongs to
 *  the value, and it is what lets the app draw it as dated rather than current.
 *  Only builds that send `acceptsDated` ever receive this status. */
export function datedReply(
  row: ClPriceRow | null | undefined,
  identity: unknown,
  reason: DatedReason,
  resetsAt?: string,
): Record<string, unknown> | null {
  if (!row || row.metric !== "cl_value" || row.fetch_status !== "ok") return null;
  if (typeof row.price_cents !== "number" || row.price_cents <= 0) return null;
  return {
    status: "dated",
    reason,
    priceCents: row.price_cents,
    metric: "cl_value",
    asOf: row.as_of ?? row.updated_at,
    lastSaleCents: row.last_sale_cents ?? null,
    lastSaleAt: row.last_sale_at ?? null,
    confidence: row.source_confidence ?? null,
    identity,
    ...(resetsAt ? { resetsAt } : {}),
  };
}

/** PURE: the one structured log line per request. Until this, the only way to tell
 *  a refusal from an upstream failure in the logs was the gzipped response size
 *  (2026-10-19). The user id is truncated: enough to match a scrape_budget row,
 *  not an identifier worth leaking. */
export function clLogLine(fields: {
  fn: string;
  userId?: string | null;
  status?: unknown;
  cached?: unknown;
  reason?: unknown;
  used?: number | null;
  ms: number;
}): string {
  return JSON.stringify({
    fn: fields.fn,
    u: fields.userId ? fields.userId.slice(0, 8) : null,
    status: typeof fields.status === "string" ? fields.status : null,
    cached: fields.cached === true,
    ...(typeof fields.reason === "string" ? { reason: fields.reason } : {}),
    used: typeof fields.used === "number" ? fields.used : null,
    ms: Math.round(fields.ms),
  });
}
