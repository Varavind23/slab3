import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { CourtyardAlgoliaSource, gradeNumber, type AlgoliaSearch } from "../src/sources/courtyard-algolia.js";

const fixture = JSON.parse(
  readFileSync(new URL("./fixtures/courtyard-algolia.json", import.meta.url), "utf8"),
);

// Fixture transport: returns the saved real Algolia result regardless of query.
const fixtureAlgolia: AlgoliaSearch = { query: async () => fixture };
const src = new CourtyardAlgoliaSource(fixtureAlgolia);

describe("gradeNumber", () => {
  it("pulls the leading number from a grade label", () => {
    expect(gradeNumber("10 GEM MINT")).toBe("10");
    expect(gradeNumber("PSA 9")).toBe("9");
    expect(gradeNumber("9.5")).toBe("9.5");
    expect(gradeNumber(undefined)).toBeUndefined();
  });
});

describe("CourtyardAlgoliaSource.lookup (real Algolia fixture)", () => {
  // A different slab of the SAME card: year, card number and grade all agree.
  it("prices a same-card match (year + card number + grade)", async () => {
    const r = await src.lookup({
      cardKey: "x", grader: "psa", name: "Charizard", set: "Base Set",
      grade: "PSA 10", year: 2021, cardNumber: "4",
    });
    expect(r.kind).toBe("ok");
    if (r.kind === "ok") {
      expect(r.priceCents).toBe(53700); // fixture hit 1: estimatedValueUsd 537
      expect(r.metric).toBe("recent_sale");
      expect(r.confidence).toBe("probable");
      expect(r.sourceCanonicalId).toBeTruthy();
    }
  });

  // THE bug this rule exists for. Name + set alone is a lottery across every
  // card of that name Courtyard has vaulted: cert 96679812 (2022 Optic Splash!
  // #10 Curry) got an unrelated Curry's $18 while Courtyard's app said $50.80.
  it("declines rather than pricing a card it cannot identify", async () => {
    const r = await src.lookup({ cardKey: "x", grader: "psa", name: "Charizard", set: "Base Set", grade: "PSA 10" });
    expect(r).toMatchObject({ kind: "error", error: "not_found" });
  });

  it("grade agreement alone is not identification", async () => {
    // Right grade, wrong card: 2002 #40 is in the fixture at grade 10, but this
    // card is 2021 #4. Matching on grade would have taken it.
    const r = await src.lookup({
      cardKey: "x", grader: "psa", name: "Charizard", set: "Base Set",
      grade: "PSA 10", year: 1874, cardNumber: "999",
    });
    expect(r).toMatchObject({ kind: "error", error: "not_found" });
  });

  it("marks an exact cert-number match as confidence 'exact'", async () => {
    // Fixture's first hit certification.number is 98881872.
    const r = await src.lookup({ cardKey: "x", grader: "psa", name: "Charizard", set: "Base Set", grade: "10", certNumber: "98881872" });
    expect(r.kind).toBe("ok");
    if (r.kind === "ok") expect(r.confidence).toBe("exact");
  });

  it("returns not_found when Algolia yields no hits", async () => {
    const empty: AlgoliaSearch = { query: async () => ({ hits: [], nbHits: 0 }) };
    const r = await new CourtyardAlgoliaSource(empty).lookup({ cardKey: "x", grader: "psa", name: "Nonexistent" });
    expect(r).toMatchObject({ kind: "error", error: "not_found" });
  });

  it("maps a network failure to a network error", async () => {
    const down: AlgoliaSearch = { query: async () => { throw new Error("ENOTFOUND"); } };
    const r = await new CourtyardAlgoliaSource(down).lookup({ cardKey: "x", grader: "psa", name: "Charizard" });
    expect(r).toMatchObject({ kind: "error", error: "network" });
  });

  it("the record carries a cert-keyed card render (the app's image source)", () => {
    // Guards the iOS mirror: if Courtyard drops these, the app silently loses
    // its only Courtyard picture and falls back to the camera capture.
    const hit = fixture.hits[0];
    expect(hit.imageUrl).toContain("graded-cards-renders");
    expect(hit.imageUrl).toContain(hit.certification.number);
    expect(typeof hit.lqipBase64).toBe("string");
  });
});
