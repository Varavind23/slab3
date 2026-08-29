import { describe, it, expect } from "vitest";
import { CourtyardSalesSource, latestSale, usdcToCents, SALES_WANTED } from "../src/sources/courtyard-sales.js";
import { FixtureTransport } from "../src/sources/transport.js";
import type { AlgoliaSearch } from "../src/sources/courtyard-algolia.js";

const identity = {
  cardKey: "psa:pokemon-xy-black-star-promo:xy17:psa-9",
  grader: "psa" as const,
  name: "Charizard EX",
  set: "Pokémon XY Black Star Promo",
  grade: "9 MINT",
};

/** Algolia stub over the recently_sold index. proofOfIntegrity IS the assetID. */
function algoliaStub(hits: unknown[]): AlgoliaSearch {
  return { query: async () => ({ hits, nbHits: hits.length }) as never };
}
const hit = (asset: string, grade = "9 MINT") => ({
  objectID: asset,
  proofOfIntegrity: asset,
  title: `A card (PSA ${grade})`,
  certification: { number: "1", grade },
  metadata: { Grader: "PSA", Grade: grade },
});

/** A ledger. Amounts are USDC 6-decimals, as Courtyard really sends them. */
const USDC = "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359";
const ledger = (txs: unknown[]) => ({ transactions: txs });
const sale = (amount: string, time: string) => ({ txType: "sale", paymentToken: USDC, paymentAmount: amount, txTime: time });

describe("usdcToCents — 6 decimals, and nothing else counts as money", () => {
  it("converts a real sale amount", () => {
    // Verified live 2026-08-29 against a real Courtyard ledger.
    expect(usdcToCents("209810000")).toBe(20981);
  });
  it("refuses empty, non-numeric and zero amounts rather than reporting $0", () => {
    expect(usdcToCents("")).toBeNull();
    expect(usdcToCents("0")).toBeNull();
    expect(usdcToCents(undefined)).toBeNull();
    expect(usdcToCents(12345)).toBeNull(); // Courtyard sends strings; a number is a surprise
  });
});

describe("latestSale — a mint is not a comp", () => {
  it("takes the newest real sale", () => {
    expect(latestSale([
      sale("50000000", "2026-08-01T00:00:00Z"),
      sale("70000000", "2026-08-20T00:00:00Z"),
    ])).toEqual({ priceCents: 7000, soldAt: "2026-08-20T00:00:00Z" });
  });

  // The common shape: most vaulted slabs have only ever been minted. A pack
  // purchase (paymentToken "stripe") is not evidence of this card's market price.
  it("ignores mint and burn, so a mint-only ledger yields nothing", () => {
    expect(latestSale([
      { txType: "mint", paymentToken: "stripe", paymentAmount: "249000000", txTime: "2026-08-01T00:00:00Z" },
      { txType: "burn", paymentToken: "", paymentAmount: "", txTime: "2026-08-02T00:00:00Z" },
    ])).toBeNull();
  });

  it("ignores a sale settled in some other token", () => {
    expect(latestSale([
      { txType: "sale", paymentToken: "0xdeadbeef", paymentAmount: "50000000", txTime: "2026-08-01T00:00:00Z" },
    ])).toBeNull();
  });

  it("an empty or absent ledger is not an error", () => {
    expect(latestSale([])).toBeNull();
    expect(latestSale(undefined)).toBeNull();
  });
});

describe("CourtyardSalesSource", () => {
  it("returns real comps, newest first", async () => {
    const src = new CourtyardSalesSource(
      new FixtureTransport([
        { match: "/asset/a1/", body: ledger([sale("100000000", "2026-08-10T00:00:00Z")]) },
        { match: "/asset/a2/", body: ledger([sale("120000000", "2026-08-20T00:00:00Z")]) },
      ]),
      algoliaStub([hit("a1"), hit("a2")]),
    );
    const out = await src.recentSales(identity);
    expect(out.map((s) => s.priceCents)).toEqual([12000, 10000]);
    expect(out[0].platform).toBe("Courtyard");
  });

  // Roughly 20% of recently_sold slabs carry a sale at all (measured 2026-08-29).
  // Fewer than five comps is the NORMAL case, and must not read as a failure.
  it("returns what it finds when most ledgers have no sale", async () => {
    const src = new CourtyardSalesSource(
      new FixtureTransport([
        { match: "/asset/a1/", body: ledger([sale("100000000", "2026-08-10T00:00:00Z")]) },
        { match: "/asset/", body: ledger([{ txType: "mint", paymentToken: "stripe", paymentAmount: "1", txTime: "2026-01-01T00:00:00Z" }]) },
      ]),
      algoliaStub([hit("a1"), hit("a2"), hit("a3"), hit("a4")]),
    );
    expect(await src.recentSales(identity)).toHaveLength(1);
  });

  it("no comps at all is an empty list, never an error", async () => {
    const src = new CourtyardSalesSource(new FixtureTransport([]), algoliaStub([]));
    expect(await src.recentSales(identity)).toEqual([]);
  });

  // Cert is not facetable in Algolia (verified 2026-08-29), so grade is the only
  // filter that keeps a PSA 10 sale out of a PSA 9's comps.
  it("drops candidates whose grade does not match", async () => {
    const src = new CourtyardSalesSource(
      new FixtureTransport([{ match: "/asset/", body: ledger([sale("99000000", "2026-08-10T00:00:00Z")]) }]),
      algoliaStub([hit("a1", "10 GEM MINT"), hit("a2", "9 MINT")]),
    );
    expect(await src.recentSales(identity)).toHaveLength(1);
  });

  it("one unreachable ledger does not lose the comps we did find", async () => {
    const src = new CourtyardSalesSource(
      new FixtureTransport([{ match: "/asset/a2/", body: ledger([sale("88000000", "2026-08-10T00:00:00Z")]) }]),
      algoliaStub([hit("a1"), hit("a2")]), // a1 has no fixture route → throws
    );
    const out = await src.recentSales(identity);
    expect(out.map((s) => s.priceCents)).toEqual([8800]);
  });

  it("caps the list at what the screen shows", async () => {
    const hits = Array.from({ length: 8 }, (_, i) => hit(`a${i}`));
    const src = new CourtyardSalesSource(
      new FixtureTransport([{ match: "/asset/", body: ledger([sale("10000000", "2026-08-10T00:00:00Z")]) }]),
      algoliaStub(hits),
    );
    expect(await src.recentSales(identity)).toHaveLength(SALES_WANTED);
  });

  it("a search failure yields no comps rather than throwing into the pipeline", async () => {
    const src = new CourtyardSalesSource(new FixtureTransport([]), {
      query: async () => { throw new Error("algolia down"); },
    });
    expect(await src.recentSales(identity)).toEqual([]);
  });
});
