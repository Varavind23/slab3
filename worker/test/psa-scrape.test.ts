import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { PsaScrapeLookup, parseCertLabels, parseGrade } from "../src/sources/psa-scrape.js";
import { FixtureHtmlTransport, HtmlTransportError, type HtmlTransport } from "../src/sources/html-transport.js";

const realPage = readFileSync(new URL("./fixtures/psa-cert-page.html", import.meta.url), "utf8");

describe("parseGrade", () => {
  it("extracts the numeric grade from a label", () => {
    expect(parseGrade("EX 5")).toBe("5");
    expect(parseGrade("MINT 9")).toBe("9");
    expect(parseGrade("GEM MT 10")).toBe("10");
    expect(parseGrade("AUTHENTIC")).toBe("AUTHENTIC");
    expect(parseGrade(undefined)).toBeUndefined();
  });
});

describe("parseCertLabels (real PSA page fixture)", () => {
  it("extracts the cert details table", () => {
    const labels = parseCertLabels(realPage);
    expect(labels["Cert Number"]).toBe("49385027");
    expect(labels["Subject"]).toBe("DARK SLOWBRO-HOLO");
    expect(labels["Brand/Title"]).toBe("POKEMON ROCKET");
    expect(labels["Year"]).toBe("2000");
    expect(labels["Item Grade"]).toBe("EX 5");
  });
});

describe("PsaScrapeLookup.byCertNumber", () => {
  it("parses a real cert page into CertData", async () => {
    const psa = new PsaScrapeLookup(new FixtureHtmlTransport([{ match: "/cert/", html: realPage }]));
    const r = await psa.byCertNumber("49385027");
    expect(r.kind).toBe("ok");
    if (r.kind === "ok") {
      expect(r.cert).toMatchObject({
        grader: "psa",
        certNumber: "49385027",
        name: "DARK SLOWBRO-HOLO",
        set: "POKEMON ROCKET",
        year: 2000,
        grade: "5",
      });
    }
  });

  it("reports layout_changed when the details table is gone", async () => {
    const psa = new PsaScrapeLookup(new FixtureHtmlTransport([{ match: "/cert/", html: "<html><body>redesigned</body></html>" }]));
    const r = await psa.byCertNumber("49385027");
    expect(r).toMatchObject({ kind: "error" });
    if (r.kind === "error") expect(r.detail).toMatch(/layout changed/i);
  });

  it("returns not_found on a 404 page", async () => {
    const t: HtmlTransport = { getHtml: async () => { throw new HtmlTransportError("404", 404); } };
    const r = await new PsaScrapeLookup(t).byCertNumber("00000000");
    expect(r.kind).toBe("not_found");
  });

  it("surfaces a bot-block (403) as an error, not a false not_found", async () => {
    const t: HtmlTransport = { getHtml: async () => { throw new HtmlTransportError("403", 403); } };
    const r = await new PsaScrapeLookup(t).byCertNumber("49385027");
    expect(r).toMatchObject({ kind: "error" });
  });
});
