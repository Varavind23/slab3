import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { CourtyardSource, usdcToCents } from "../src/sources/courtyard.js";
import { FixtureTransport } from "../src/sources/transport.js";

const txFixture = JSON.parse(
  readFileSync(new URL("./fixtures/courtyard-transactions.json", import.meta.url), "utf8"),
);
const realAssetId: string = txFixture.transactions[0].assetID;
const realAmount: string = txFixture.transactions[0].paymentAmount;

const transport = new FixtureTransport([{ match: "index/transactions", body: txFixture }]);
const src = new CourtyardSource(transport);

describe("usdcToCents", () => {
  it("converts 6-decimal USDC to integer cents", () => {
    expect(usdcToCents("8460000")).toBe(846); // $8.46
    expect(usdcToCents("1000000")).toBe(100); // $1.00
    expect(usdcToCents("123450000")).toBe(12345); // $123.45
  });
  it("rejects non-numeric amounts", () => {
    expect(usdcToCents("")).toBeNull();
    expect(usdcToCents("12.5")).toBeNull();
    expect(usdcToCents("abc")).toBeNull();
  });
});

describe("CourtyardSource.recentSaleForAsset", () => {
  it("returns the recent USDC sale for a known asset (real fixture)", async () => {
    const r = await src.recentSaleForAsset(realAssetId);
    expect(r.kind).toBe("ok");
    if (r.kind === "ok") {
      expect(r.metric).toBe("recent_sale");
      expect(r.priceCents).toBe(usdcToCents(realAmount));
      expect(r.confidence).toBe("exact");
      expect(Date.parse(r.asOf)).not.toBeNaN();
    }
  });

  it("returns not_found for an asset with no sale in the feed", async () => {
    const r = await src.recentSaleForAsset("deadbeef-not-in-feed");
    expect(r).toMatchObject({ kind: "error", error: "not_found" });
  });

  it("flags layout_changed when transactions[] is missing", async () => {
    const bad = new CourtyardSource(new FixtureTransport([{ match: "index/transactions", body: { foo: 1 } }]));
    const r = await bad.recentSaleForAsset("x");
    expect(r).toMatchObject({ kind: "error", error: "layout_changed" });
  });

  it("maps 5xx transport failure to network error", async () => {
    const down = new CourtyardSource(new FixtureTransport([{ match: "index/transactions", body: null, status: 503 }]));
    const r = await down.recentSaleForAsset("x");
    expect(r).toMatchObject({ kind: "error", error: "network" });
  });
});

describe("CourtyardSource.lookup", () => {
  it("degrades to not_found until the M3 card→asset search endpoint lands", async () => {
    const r = await src.lookup({ cardKey: "psa:base-set:charizard:psa-9", grader: "psa" });
    expect(r).toMatchObject({ kind: "error", error: "not_found" });
  });
});
