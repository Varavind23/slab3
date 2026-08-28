import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import {
  PsaScrapeLookup,
  certReplyFromHtml,
  parseCertImageUrl,
  parseCertLabels,
  parseCertTitle,
  parseGrade,
} from "../src/sources/psa-scrape.js";
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

describe("parseCertImageUrl", () => {
  it("selects a SecureScan image and ignores PSA site chrome", () => {
    const html = `<img src="https://i.psacard.com/psacard/images/logo.png"><img src="https://i.psacard.com/certimages/123/front.jpg?x=1&amp;y=2">`;
    expect(parseCertImageUrl(html)).toBe("https://i.psacard.com/certimages/123/front.jpg?x=1&y=2");
  });

  it("is optional for certs without SecureScan", () => {
    expect(parseCertImageUrl(realPage)).toBeUndefined();
  });
});

describe("parseCertTitle", () => {
  it("reads the assembled title from the real page's <h1>", () => {
    expect(parseCertTitle(realPage, "DARK SLOWBRO-HOLO")).toBe("2000 POKEMON ROCKET #12 DARK SLOWBRO-HOLO");
  });

  it("falls back to the RSC payload when the heading is gone", () => {
    // The payload's quotes are backslash-escaped because it lives inside a JS
    // string literal — a plain `"description":"` pattern finds nothing.
    const noHeading = realPage.replace(/<h1\b[^>]*>[\s\S]*?<\/h1>/i, "");
    expect(parseCertTitle(noHeading, "DARK SLOWBRO-HOLO")).toBe("2000 POKEMON ROCKET #12 DARK SLOWBRO-HOLO");
  });

  it("decodes entities and strips inline markup", () => {
    expect(parseCertTitle('<h1>1998 Pok&#39;mon <span>Jungle</span> #1 Clefable</h1>'))
      .toBe("1998 Pok'mon Jungle #1 Clefable");
  });

  it("rejects a heading that is neither the subject nor dated", () => {
    // Otherwise a not-found page's heading becomes the card's title.
    expect(parseCertTitle("<h1>Cert Verification</h1>", "DARK SLOWBRO-HOLO")).toBeUndefined();
  });
});

describe("certReplyFromHtml (the assembly the deployed Worker returns)", () => {
  it("builds the full reply from the real page", () => {
    expect(certReplyFromHtml("49385027", realPage)).toEqual({
      status: "ok",
      certNumber: "49385027",
      subject: "DARK SLOWBRO-HOLO",
      set: "POKEMON ROCKET",
      year: 2000,
      grade: "5",
      title: "2000 POKEMON ROCKET #12 DARK SLOWBRO-HOLO",
      cardNumber: "12",
      imageUrl: undefined,
    });
  });

  it("reports a layout change rather than a false not-found", () => {
    expect(certReplyFromHtml("49385027", "<html><body>unexpected</body></html>"))
      .toEqual({ status: "source_error", reason: "details_not_found" });
  });

  it("passes through a genuine not-found page", () => {
    expect(certReplyFromHtml("49385027", "<html><body>No results found</body></html>"))
      .toEqual({ status: "not_found" });
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
