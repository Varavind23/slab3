import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import {
  parseCardDetails,
  fetchCardDetails,
  cySourceKey,
  gradeLabel,
  cyConfidence,
  salesForGrade,
  populationForGrade,
  CyError,
} from "../src/sources/courtyard-scanner.js";

// Fixtures captured LIVE from api.courtyard.io/scanner/card-details (2026-08-31).
const load = (n: string) => JSON.parse(readFileSync(new URL(`./fixtures/${n}`, import.meta.url), "utf8"));
// cert 96679812: the acceptance bar — Courtyard's own app shows $50.80 / medium
// confidence for this slab, confirmed on device by the owner.
const PSA = load("courtyard-scanner-psa.json");
// cert 154334127: Courtyard KNOWS the card but has no model price — it returns
// price 0 / confidence "0" and their app renders "not applicable". The case most
// likely to regress into a fabricated $0.
const NOPRICE = load("courtyard-scanner-noprice.json");
// cert 4260611176: CGC, whose grade code is "g10pristine" — NOT plain numeric.
const CGC = load("courtyard-scanner-cgc.json");
const NOTFOUND = load("courtyard-scanner-notfound.json");

const stub = (body: unknown, status = 200): typeof fetch =>
  (async () =>
    new Response(typeof body === "string" ? body : JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    })) as unknown as typeof fetch;

describe("cySourceKey", () => {
  it("is Courtyard's own graderData.id, derivable before any request", () => {
    expect(cySourceKey("psa", "96679812")).toBe("PSA_96679812");
    expect(cySourceKey("psa", "96679812")).toBe(PSA.graderData.id);
    expect(cySourceKey("cgc", "4260611176")).toBe(CGC.graderData.id);
  });
});

describe("gradeLabel", () => {
  it("normalizes every source's spelling to a bare number", () => {
    expect(gradeLabel("g10")).toBe("10");
    expect(gradeLabel("10 GEM MINT")).toBe("10");
    expect(gradeLabel("PSA 9")).toBe("9");
    expect(gradeLabel("9.5")).toBe("9.5");
  });
  it("handles CGC's non-numeric codes, which Card Ladder's displayGrade rejects", () => {
    expect(gradeLabel("g10pristine")).toBe("10");
    expect(gradeLabel(CGC.graderData.grade)).toBe("10");
  });
  it("says nothing rather than guessing when there is no number", () => {
    expect(gradeLabel("AUTH")).toBeUndefined();
    expect(gradeLabel(undefined)).toBeUndefined();
  });
});

describe("cyConfidence", () => {
  it("keeps 1-5", () => {
    expect(cyConfidence("2")).toBe(2);
    expect(cyConfidence(5)).toBe(5);
  });
  it("rejects 0 — that is 'not applicable', not a confidence", () => {
    expect(cyConfidence("0")).toBeUndefined();
    expect(cyConfidence(0)).toBeUndefined();
  });
});

describe("parseCardDetails — the priced case", () => {
  const r = parseCardDetails(PSA, "psa", "96679812");

  it("reads the number Courtyard's own app displays", () => {
    // THE LIVE BAR. Their app shows $50.80, medium confidence, for this slab.
    expect(r.priceCents).toBe(5080);
    expect(r.confidence).toBe(2);
  });

  it("carries a cert-exact identity, including the grade", () => {
    // The grade matters beyond the badge: it is a card_key segment, and before
    // this source Card Ladder was the ONLY supplier (PSA's cert page is walled).
    expect(r.identity.grade).toBe("10");
    expect(r.identity.subject).toBe("Stephen Curry");
    expect(r.identity.cardNumber).toBe("10");
    expect(r.identity.year).toBe(2022);
    expect(r.identity.id).toBe("PSA_96679812");
  });

  it("reports acquisition, the app's 'Courtyard isn't buying this card' flag", () => {
    expect(r.acquisitionAccepted).toBe(true);
  });
});

describe("parseCardDetails — no model price", () => {
  const r = parseCardDetails(NOPRICE, "psa", "154334127");

  it("maps price 0 / confidence 0 to NO price, never $0", () => {
    // Courtyard's app renders this slab as "not applicable" (confirmed on device).
    // A 0 reaching the UI would be a fabricated price — the one thing forbidden.
    expect(r.priceCents).toBeNull();
    expect(r.confidence).toBeUndefined();
  });

  it("still yields the identity, so the row is not left anonymous", () => {
    expect(r.identity.grade).toBe("9");
    expect(r.identity.title).toContain("Lewis Hamilton");
  });

  it("keeps comps that are for a DIFFERENT grade than the slab", () => {
    // This is a g9 whose only sales are g10. The app labels the grade rather than
    // hiding them, so the data must survive parsing; salesForGrade does the gating.
    expect(r.comps).toHaveLength(1);
    expect(r.comps[0].grade).toBe("10");
    expect(r.comps[0].sales[0]).toEqual({ priceCents: 14500, soldAt: "2026-05-17T00:00:00Z" });
  });
});

describe("comps are keyed by grader AND grade", () => {
  const r = parseCardDetails(PSA, "psa", "96679812");

  it("does not merge two graders' grade-10 groups", () => {
    // cert 96679812 returns TWO grade-10 groups: PSA (pop 23) and SGC (pop 3).
    // Every group repeats the SCANNED card's title, so `title` says "(PSA g10)"
    // on both — keying off it would report SGC's sales as PSA's.
    const tens = r.comps.filter((g) => g.grade === "10");
    expect(tens).toHaveLength(2);
    expect(tens.map((g) => g.grader).sort()).toEqual(["PSA", "SGC"]);
  });

  it("returns only the slab's own grader+grade sales", () => {
    const sales = salesForGrade(r, "PSA", "10");
    expect(sales.length).toBe(12);
    expect(populationForGrade(r, "PSA", "10")).toBe(23);
    // The SGC group is a different set entirely.
    expect(salesForGrade(r, "SGC", "10").length).toBe(1);
  });

  it("returns [] — not another grade's sales — when the slab's grade has none", () => {
    const g9 = parseCardDetails(NOPRICE, "psa", "154334127");
    expect(salesForGrade(g9, "PSA", "9")).toEqual([]);
  });

  it("sorts sales newest first", () => {
    const sales = salesForGrade(r, "PSA", "10");
    const dates = sales.map((s) => s.soldAt);
    expect([...dates].sort((a, b) => b.localeCompare(a))).toEqual(dates);
  });
});

describe("CGC", () => {
  const r = parseCardDetails(CGC, "cgc", "4260611176");
  it("is a real source for CGC, which had none before", () => {
    expect(r.priceCents).toBe(11100);
    expect(r.confidence).toBe(5);
    expect(r.identity.grade).toBe("10");
  });
});

describe("fetchCardDetails error semantics", () => {
  it("404 is AUTHORITATIVE not_found — the UI shows an em dash", async () => {
    await expect(fetchCardDetails("133653550", "psa", { fetch: stub(NOTFOUND, 404) })).rejects.toMatchObject({
      kind: "not_found",
    });
  });

  it("502 from their gemrate upstream is TRANSIENT, not a missing card", async () => {
    // Must not blank a price the user already saw — PriceWriteback holds that rule.
    await expect(
      fetchCardDetails("00000001", "psa", { fetch: stub({ message: "invalid response from gemrate" }, 502) }),
    ).rejects.toMatchObject({ kind: "source_error" });
  });

  it("a transport failure is a network error, not a not_found", async () => {
    const boom = (async () => {
      throw new Error("connection reset");
    }) as unknown as typeof fetch;
    await expect(fetchCardDetails("96679812", "psa", { fetch: boom })).rejects.toBeInstanceOf(CyError);
  });

  it("round-trips a live-shaped response", async () => {
    const r = await fetchCardDetails("96679812", "psa", { fetch: stub(PSA) });
    expect(r.priceCents).toBe(5080);
    expect(r.sourceKey).toBe("PSA_96679812");
  });
});
