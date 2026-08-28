import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { CardLadderSource, cardImage, lookupAverageSale, parseEstimate, parseResolve, usdToCents } from "../src/sources/cardladder.js";

// Fixtures captured LIVE from the real Card Ladder Firebase callables (2026-08-24).
const load = (n: string) => JSON.parse(readFileSync(new URL(`./fixtures/${n}`, import.meta.url), "utf8"));
const RESOLVE = load("cardladder-resolve.json"); // httpbuildcollectioncard result envelope
const ESTIMATE = load("cardladder-estimate.json"); // httpcardestimate result envelope
const QUOTA = load("cardladder-quota.json"); // RESOURCE_EXHAUSTED envelope

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
  it("resolves cert then estimates → ok with average-sale cents + profileId", async () => {
    const fetchImpl = stubFetch([
      { match: "httpbuildcollectioncard", body: RESOLVE },
      { match: "httpcardestimate", body: ESTIMATE },
    ]);
    const r = await new CardLadderSource(token, fetchImpl).lookup(identity);
    // ESTIMATE.result.oneMonthData.averagePrice = 116.92 → 11692 cents.
    expect(r).toMatchObject({
      kind: "ok",
      priceCents: 11692,
      metric: "average_sale",
      confidence: "exact",
      sourceCanonicalId: "psa-299594",
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
    const noComps = { result: { ...ESTIMATE.result, oneMonthData: { velocity: 0, averagePrice: 0 } } };
    const fetchStub = stubFetch([
      { match: "signInWithPassword", body: { idToken: "t", refreshToken: "r", expiresIn: "3600" } },
      { match: "httpbuildcollectioncard", body: RESOLVE },
      { match: "httpcardestimate", body: noComps },
    ]);
    const out = await lookupAverageSale("tok", "20360362", "psa", "oneMonthData", { fetch: fetchStub });
    expect(out.kind).toBe("not_found");
    expect((out as any).identity?.label).toBe("1986 Fleer #73 Kevin Mchale");
    expect((out as any).identity?.player).toBe("Kevin McHale");
  });

  it("has no identity when the cert itself is unknown", async () => {
    const fetchStub = stubFetch([
      { match: "httpbuildcollectioncard", body: { result: null } },
    ]);
    const out = await lookupAverageSale("tok", "00000000", "psa", "oneMonthData", { fetch: fetchStub });
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

  it("parseEstimate reads the one-month average as the default metric", () => {
    expect(parseEstimate(ESTIMATE.result).averageSaleCents).toBe(11692);
    expect(parseEstimate(ESTIMATE.result, "twoWeekData").averageSaleCents).toBe(12500);
  });

  it("an all-zero estimate (what the wrong condition returns) yields null, not $0", () => {
    const zeroed = { oneMonthData: { velocity: 0, averagePrice: 0 } };
    expect(parseEstimate(zeroed).averageSaleCents).toBeNull();
  });

  it("usdToCents guards 0/absent/non-finite", () => {
    expect(usdToCents(116.92)).toBe(11692);
    expect(usdToCents(0)).toBeNull();
    expect(usdToCents(null)).toBeNull();
    expect(usdToCents(undefined)).toBeNull();
  });
});
