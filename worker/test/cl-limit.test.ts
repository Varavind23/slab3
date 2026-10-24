// Pins the 2026-10-19 Card Ladder budget decisions (supabase/functions/_shared/
// cl-limit.ts): the cap, when it resets, and what an over-cap user is handed —
// Card Ladder's last real value WITH its date, or nothing honest at all.
import { describe, it, expect } from "vitest";
import {
  CL_DAILY_CAP,
  nextUtcReset,
  datedReply,
  clLogLine,
  type ClPriceRow,
} from "../../supabase/functions/_shared/cl-limit";

const row = (over: Partial<ClPriceRow> = {}): ClPriceRow => ({
  price_cents: 8900,
  as_of: "2026-10-15T18:04:00.000Z",
  updated_at: "2026-10-15T18:04:01.000Z",
  fetch_status: "ok",
  metric: "cl_value",
  last_sale_cents: 4600,
  last_sale_at: "2026-10-01T00:00:00.000Z",
  source_confidence: 3,
  ...over,
});
const identity = { grade: "10", label: "1999 Pokemon Base Set Charizard" };

describe("the daily cap", () => {
  it("is 400 per user — owner decision 2026-10-19", () => {
    expect(CL_DAILY_CAP).toBe(400);
  });

  it("resets at the next 00:00 UTC, the window spend_cardladder_budget keys on", () => {
    expect(nextUtcReset(new Date("2026-10-19T07:17:00Z"))).toBe("2026-10-20T00:00:00.000Z");
    expect(nextUtcReset(new Date("2026-10-19T23:59:59.999Z"))).toBe("2026-10-20T00:00:00.000Z");
    // Exactly at the boundary the NEW window has begun, so the next reset is a day out.
    expect(nextUtcReset(new Date("2026-10-20T00:00:00Z"))).toBe("2026-10-21T00:00:00.000Z");
    // Month and year roll over.
    expect(nextUtcReset(new Date("2026-12-31T12:00:00Z"))).toBe("2027-01-01T00:00:00.000Z");
  });
});

describe("datedReply: the last real value, labelled with its own date", () => {
  it("hands back an old ok row with the date Card Ladder gave it, never now", () => {
    const r = datedReply(row(), identity, "rate_limited", "2026-10-20T00:00:00.000Z");
    expect(r).toEqual({
      status: "dated",
      reason: "rate_limited",
      priceCents: 8900,
      metric: "cl_value",
      asOf: "2026-10-15T18:04:00.000Z",
      lastSaleCents: 4600,
      lastSaleAt: "2026-10-01T00:00:00.000Z",
      confidence: 3,
      identity,
      resetsAt: "2026-10-20T00:00:00.000Z",
    });
  });

  it("accepts a row of any age — the 24h TTL is for freshness, not honesty", () => {
    const r = datedReply(row({ as_of: "2026-09-01T00:00:00.000Z" }), identity, "rate_limited");
    expect(r?.priceCents).toBe(8900);
    expect(r?.asOf).toBe("2026-09-01T00:00:00.000Z");
  });

  it("falls back to updated_at when the row has no as_of", () => {
    expect(datedReply(row({ as_of: null }), identity, "source_error")?.asOf)
      .toBe("2026-10-15T18:04:01.000Z");
  });

  it("omits resetsAt when there is none (an upstream failure has no reset)", () => {
    expect(datedReply(row(), identity, "source_error")).not.toHaveProperty("resetsAt");
  });

  it("refuses a row cached under another metric — an average sale is not a Value", () => {
    expect(datedReply(row({ metric: "average_sale" }), identity, "rate_limited")).toBeNull();
  });

  it("refuses a cached 'no value' and a missing or zero price — nothing is invented", () => {
    expect(datedReply(row({ fetch_status: "not_found", price_cents: null }), identity, "rate_limited")).toBeNull();
    expect(datedReply(row({ price_cents: null }), identity, "rate_limited")).toBeNull();
    expect(datedReply(row({ price_cents: 0 }), identity, "rate_limited")).toBeNull();
  });

  it("refuses when there is no row", () => {
    expect(datedReply(null, identity, "rate_limited")).toBeNull();
    expect(datedReply(undefined, identity, "source_error")).toBeNull();
  });

  it("carries nulls, not undefined, for supporting figures the row lacks", () => {
    const r = datedReply(
      row({ last_sale_cents: undefined, last_sale_at: undefined, source_confidence: undefined }),
      identity, "rate_limited");
    expect(r).toMatchObject({ lastSaleCents: null, lastSaleAt: null, confidence: null });
  });
});

describe("clLogLine", () => {
  it("is one JSON line with a truncated user id", () => {
    const line = clLogLine({
      fn: "cardladder-price", userId: "6e960470-aaaa-bbbb-cccc-dddddddddddd",
      status: "dated", cached: true, reason: "rate_limited", used: 401, ms: 312.6,
    });
    expect(JSON.parse(line)).toEqual({
      fn: "cardladder-price", u: "6e960470", status: "dated", cached: true,
      reason: "rate_limited", used: 401, ms: 313,
    });
  });

  it("survives an unauthenticated request and an unparseable body", () => {
    expect(JSON.parse(clLogLine({ fn: "cardladder-sales", ms: 5 }))).toEqual({
      fn: "cardladder-sales", u: null, status: null, cached: false, used: null, ms: 5,
    });
  });
});
