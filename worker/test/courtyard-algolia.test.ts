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
  it("returns a priced match for a searched card", async () => {
    const r = await src.lookup({ cardKey: "x", grader: "psa", name: "Charizard", set: "Base Set", grade: "PSA 10" });
    expect(r.kind).toBe("ok");
    if (r.kind === "ok") {
      expect(r.priceCents).toBeGreaterThan(0);
      expect(r.metric).toBe("recent_sale");
      expect(r.sourceCanonicalId).toBeTruthy(); // objectID present
    }
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
});
