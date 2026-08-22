import { describe, it, expect } from "vitest";
import { CgcCertLookup } from "../src/sources/cgc.js";
import { HtmlTransportError, type HtmlTransport } from "../src/sources/html-transport.js";

describe("CgcCertLookup (shell — data source pending)", () => {
  it("reports the Cloudflare Turnstile wall as a distinct, expected state", async () => {
    const t: HtmlTransport = { getHtml: async () => { throw new HtmlTransportError("403", 403); } };
    const r = await new CgcCertLookup(t).byCertNumber("1234567");
    expect(r.kind).toBe("error");
    if (r.kind === "error") expect(r.detail).toMatch(/cloudflare|challenge/i);
  });

  it("returns not_found on a 404", async () => {
    const t: HtmlTransport = { getHtml: async () => { throw new HtmlTransportError("404", 404); } };
    const r = await new CgcCertLookup(t).byCertNumber("0000000");
    expect(r.kind).toBe("not_found");
  });

  it("does not fabricate card data when the parser is unwired", async () => {
    const t: HtmlTransport = { getHtml: async () => "<html><body>angular shell</body></html>" };
    const r = await new CgcCertLookup(t).byCertNumber("1234567");
    expect(r.kind).toBe("error"); // never a false 'ok'
  });
});
