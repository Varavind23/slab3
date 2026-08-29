import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { CardLadderSource, cardImage, lookupCardValue, parseEstimate, parseResolve, parseSales, isoOrNull, usdToCents } from "../src/sources/cardladder.js";

// Fixtures captured LIVE from the real Card Ladder Firebase callables (2026-08-24).
const load = (n: string) => JSON.parse(readFileSync(new URL(`./fixtures/${n}`, import.meta.url), "utf8"));
const RESOLVE = load("cardladder-resolve.json"); // httpbuildcollectioncard result envelope
const ESTIMATE = load("cardladder-estimate.json"); // httpcardestimate result envelope
const QUOTA = load("cardladder-quota.json"); // RESOURCE_EXHAUSTED envelope
// Captured live 2026-08-29 alongside the metric change.
const SALES = load("cardladder-sales.json"); // httpprofilesales result envelope (cert 20360362)
// Cert 154334127: Card Ladder KNOWS the card but has no value and no comps. The
// honest-empty case, which is the one most likely to regress into a bogus $0.
const ESTIMATE_NOVALUE = load("cardladder-estimate-novalue.json");
const SALES_NOVALUE = load("cardladder-sales-novalue.json");

const identity = { cardKey: "psa:1986-fleer:73:psa-9", grader: "psa" as const, certNumber: "20360362", name: "Kevin McHale" };

/** Build a routing fetch stub over the Google hosts the shared client calls. */
function stubFetch(routes: Array<{ match: string; body: unknown; status?: number }>): typeof fetch {
  return (async (url: string | URL) => {
    const u = String(url);
    const hit = routes.find((r) => u.includes(r.match));
    if (!hit) return new Response("not found", { status: 404 });
    const b = hit.body;
    const text = typeof b === "string" ? b : JSON.stringify(b);
    return new Response(text, { status: hit.status ?? 200, headers: { "content-type": "application/json" } });
  }) as unknown as typeof fetch;
}
const token = async () => "test-id-token";

describe("CardLadderSource — verified Firebase callable contract", () => {
  it("resolves cert then estimates → ok with Card Ladder Value + profileId", async () => {
    const fetchImpl = stubFetch([
      { match: "httpbuildcollectioncard", body: RESOLVE },
      { match: "httpcardestimate", body: ESTIMATE },
    ]);
    const r = await new CardLadderSource(token, fetchImpl).lookup(identity);
    // ESTIMATE.result.estimatedValue = 120 → 12000 cents. NOT oneMonthData's
    // 117.36 — the headline is Card Ladder's own Value as of 2026-08-29.
    expect(r).toMatchObject({
      kind: "ok",
      priceCents: 12000,
      metric: "cl_value",
      confidence: "exact",
      sourceCanonicalId: "psa-299594",
      sourceConfidence: 5,
      lastSaleCents: 12000,
    });
  });

  it("maps the daily-quota envelope (RESOURCE_EXHAUSTED, HTTP 200) to rate_limited", async () => {
    const fetchImpl = stubFetch([
      { match: "httpbuildcollectioncard", body: RESOLVE },
      { match: "httpcardestimate", body: QUOTA },
    ]);
    const r = await new CardLadderSource(token, fetchImpl).lookup(identity);
    expect(r).toMatchObject({ kind: "error", error: "rate_limited" });
  });

  it("maps a 403 challenge/expired token to auth_expired (reconnect prompt)", async () => {
    const fetchImpl = stubFetch([{ match: "httpbuildcollectioncard", body: "<html>Just a moment</html>", status: 403 }]);
    const r = await new CardLadderSource(token, fetchImpl).lookup(identity);
    expect(r).toMatchObject({ kind: "error", error: "auth_expired" });
  });

  it("maps a non-JSON callable body (edge interstitial) to auth_expired, not a bogus price", async () => {
    const fetchImpl = stubFetch([{ match: "httpbuildcollectioncard", body: "<!DOCTYPE html>...", status: 200 }]);
    const r = await new CardLadderSource(token, fetchImpl).lookup(identity);
    expect(r).toMatchObject({ kind: "error", error: "auth_expired" });
  });

  it("returns not_found when Card Ladder has no such cert", async () => {
    const fetchImpl = stubFetch([{ match: "httpbuildcollectioncard", body: { result: null } }]);
    const r = await new CardLadderSource(token, fetchImpl).lookup(identity);
    expect(r).toMatchObject({ kind: "error", error: "not_found" });
  });

  it("maps a transport throw to a network error", async () => {
    const fetchImpl = (async () => {
      throw new Error("socket hang up");
    }) as unknown as typeof fetch;
    const r = await new CardLadderSource(token, fetchImpl).lookup(identity);
    expect(r).toMatchObject({ kind: "error", error: "network" });
  });

  it("returns auth_expired (never crashes) when no Card Ladder connection", async () => {
    const noToken = async () => {
      throw new Error("not connected");
    };
    const r = await new CardLadderSource(noToken).lookup(identity);
    expect(r).toMatchObject({ kind: "error", error: "auth_expired" });
  });
});

describe("Card Ladder pure parsing (the condition=grade gotcha)", () => {
  // Regression: a resolved card with no recent comps used to come back as a bare
  // not_found, throwing away the ONLY identity available while PSA is walled —
  // which showed up in the app as "Details pending" on cards Card Ladder had
  // named perfectly. Verified live against two real certs (2026-08-28).
  it("keeps the identity when the card is known but has no comps", async () => {
    const noComps = { result: { ...ESTIMATE.result, estimatedValue: 0 } };
    const fetchStub = stubFetch([
      { match: "signInWithPassword", body: { idToken: "t", refreshToken: "r", expiresIn: "3600" } },
      { match: "httpbuildcollectioncard", body: RESOLVE },
      { match: "httpcardestimate", body: noComps },
    ]);
    const out = await lookupCardValue("tok", "20360362", "psa", "oneMonthData", { fetch: fetchStub });
    expect(out.kind).toBe("not_found");
    expect((out as any).identity?.label).toBe("1986 Fleer #73 Kevin Mchale");
    expect((out as any).identity?.player).toBe("Kevin McHale");
  });

  it("has no identity when the cert itself is unknown", async () => {
    const fetchStub = stubFetch([
      { match: "httpbuildcollectioncard", body: { result: null } },
    ]);
    const out = await lookupCardValue("tok", "00000000", "psa", "oneMonthData", { fetch: fetchStub });
    expect(out.kind).toBe("not_found");
    expect((out as any).identity).toBeUndefined();
  });

  it("parseResolve requires profileId + grade code", () => {
    expect(parseResolve(RESOLVE.result, "psa")).toMatchObject({ profileId: "psa-299594", grade: "g9" });
    expect(parseResolve({ profileId: "psa-1", grade: null }, "psa")).toBeNull();
    expect(parseResolve(null, "psa")).toBeNull();
  });

  it("parseResolve carries the identity the app shows: label, player, and the card render", () => {
    expect(parseResolve(RESOLVE.result, "psa")).toMatchObject({
      label: "1986 Fleer #73 Kevin Mchale",
      player: "Kevin McHale",
      year: "1986",
      set: "Fleer",
      number: "73",
      category: "Basketball",
      imageUrl: "https://firebasestorage.googleapis.com/v0/b/cardladder-71d53.appspot.com/o/cards%2FZrGfW7rQUkEclfZDFJg0?alt=media",
    });
  });

  // The resolve payload's image fields VARY by response, so these pin both
  // shapes seen in the wild. Getting this wrong puts another slab's listing
  // photo on the card — the image equivalent of showing someone else's price.
  it("prefers the card render when the payload carries one", () => {
    const resolved = parseResolve(RESOLVE.result, "psa");
    expect(resolved?.imageUrl).toContain("/cards%2F");
    expect(resolved?.imageUrl).not.toContain("/sales%2F");
  });

  it("takes the CloudFront cert scan that live lookups actually return", () => {
    // Live shape (verified 2026-08-28): no `image` key at all, and `imageUrl` is
    // the cert scan rather than a comp.
    expect(cardImage({ imageUrl: "https://d1htnxwo4o0jhw.cloudfront.net/cert/164281967/abc.jpg" }))
      .toBe("https://d1htnxwo4o0jhw.cloudfront.net/cert/164281967/abc.jpg");
  });

  it("never takes a Firebase sales/ comp — that is a different slab's listing photo", () => {
    expect(cardImage({
      imageUrl: "https://firebasestorage.googleapis.com/v0/b/cardladder-71d53.appspot.com/o/sales%2Fpwcc-ebay-2679713?alt=media",
    })).toBeUndefined();
  });

  it("has no picture rather than a wrong one", () => {
    expect(cardImage({})).toBeUndefined();
    expect(cardImage(null)).toBeUndefined();
  });

  // The metric that ships. `estimatedValue` is the figure Card Ladder's own app
  // labels "Value"; the window averages stay on the payload but lead nothing.
  it("parseEstimate reads Card Ladder Value, last sale and confidence", () => {
    const e = parseEstimate(ESTIMATE.result);
    expect(e.clValueCents).toBe(12000);
    expect(e.lastSalePriceCents).toBe(12000);
    expect(e.lastSaleAt).toBe("2026-08-28T15:04:10.000Z");
    expect(e.confidence).toBe(5);
  });

  it("still carries the window averages, which are no longer the headline", () => {
    expect(parseEstimate(ESTIMATE.result).averageSaleCents).toBe(11736);
    expect(parseEstimate(ESTIMATE.result, "twoWeekData").averageSaleCents).toBe(12000);
  });

  // THE regression this whole change exists for. Before 2026-08-29 the headline
  // was oneMonthData.averagePrice, so a card with an empty 30-day window showed no
  // Card Ladder price at all even when Card Ladder knew its value perfectly well.
  it("a card with an empty one-month window still has a Card Ladder Value", () => {
    const emptyWindow = { ...ESTIMATE.result, oneMonthData: { velocity: 0, averagePrice: 0 } };
    const e = parseEstimate(emptyWindow);
    expect(e.averageSaleCents).toBeNull(); // what v1 would have shown: nothing
    expect(e.clValueCents).toBe(12000); // what the user actually gets now
  });

  it("an all-zero estimate (what the wrong condition returns) yields null, not $0", () => {
    const zeroed = { estimatedValue: 0, oneMonthData: { velocity: 0, averagePrice: 0 } };
    expect(parseEstimate(zeroed).clValueCents).toBeNull();
    expect(parseEstimate(zeroed).averageSaleCents).toBeNull();
  });

  it("a card Card Ladder has no value for reports null across the board, never $0", () => {
    const e = parseEstimate(ESTIMATE_NOVALUE.result);
    expect(e.clValueCents).toBeNull();
    expect(e.lastSalePriceCents).toBeNull();
    expect(e.lastSaleAt).toBeNull();
    expect(e.confidence).toBeNull();
  });

  // ── httpprofilesales: real comps ───────────────────────────────────────────
  it("parseSales shapes real sales, newest first", () => {
    const sales = parseSales(SALES.result);
    expect(sales).toHaveLength(20);
    expect(sales[0]).toMatchObject({
      priceCents: 12000,
      soldAt: "2026-08-28T15:04:10.000Z",
      platform: "eBay",
      listingType: "BestOffer",
    });
    const dates = sales.map((s) => s.soldAt);
    expect([...dates].sort().reverse()).toEqual(dates);
  });

  it("an empty sales archive is a real answer, not an error", () => {
    expect(parseSales(SALES_NOVALUE.result)).toEqual([]);
    expect(parseSales(null)).toEqual([]);
    expect(parseSales({})).toEqual([]);
  });

  // A comp we cannot state honestly is not a comp.
  it("parseSales drops entries missing a real price or a real date", () => {
    const out = parseSales({ sales: [
      { price: 0, date: "2026-08-01T00:00:00.000Z" },
      { price: 50, date: null },
      { price: 50, date: "not a date" },
      { price: 50, date: "2026-08-01T00:00:00.000Z" },
    ] });
    expect(out).toEqual([{ priceCents: 5000, soldAt: "2026-08-01T00:00:00.000Z" }]);
  });

  it("isoOrNull normalizes or refuses", () => {
    expect(isoOrNull("2026-08-28T15:04:10.000Z")).toBe("2026-08-28T15:04:10.000Z");
    expect(isoOrNull("garbage")).toBeNull();
    expect(isoOrNull(null)).toBeNull();
  });

  it("usdToCents guards 0/absent/non-finite", () => {
    expect(usdToCents(116.92)).toBe(11692);
    expect(usdToCents(0)).toBeNull();
    expect(usdToCents(null)).toBeNull();
    expect(usdToCents(undefined)).toBeNull();
  });
});
