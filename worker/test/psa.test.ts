import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { PsaCertLookup } from "../src/sources/psa.js";
import { FixtureTransport, TransportError, type JsonTransport } from "../src/sources/transport.js";

const load = (f: string) =>
  JSON.parse(readFileSync(new URL(`./fixtures/${f}`, import.meta.url), "utf8"));

const CERT = "cert/GetByCertNumber";

describe("PsaCertLookup.byCertNumber", () => {
  it("parses a successful cert into CertData (documented shape)", async () => {
    const psa = new PsaCertLookup(new FixtureTransport([{ match: CERT, body: load("psa-charizard.json") }]));
    const r = await psa.byCertNumber("49385027");
    expect(r.kind).toBe("ok");
    if (r.kind === "ok") {
      expect(r.cert).toMatchObject({
        grader: "psa",
        certNumber: "49385027",
        name: "CHARIZARD-HOLO",
        set: "POKEMON GAME",
        year: 1999,
        grade: "9",
      });
    }
  });

  it("returns invalid for a malformed cert number", async () => {
    const psa = new PsaCertLookup(new FixtureTransport([{ match: CERT, body: load("psa-invalid.json") }]));
    const r = await psa.byCertNumber("abc");
    expect(r.kind).toBe("invalid");
  });

  it("returns not_found when the cert format is valid but has no data", async () => {
    const psa = new PsaCertLookup(new FixtureTransport([{ match: CERT, body: load("psa-nodata.json") }]));
    const r = await psa.byCertNumber("00000000");
    expect(r.kind).toBe("not_found");
  });

  it("maps 403 to not_approved (account not approved for PSA API)", async () => {
    const t403: JsonTransport = { getJson: async () => { throw new TransportError("403", 403); } };
    const r = await new PsaCertLookup(t403).byCertNumber("49385027");
    expect(r.kind).toBe("not_approved");
  });

  it("maps 429 to quota (daily limit exceeded)", async () => {
    const t429: JsonTransport = { getJson: async () => { throw new TransportError("429", 429); } };
    const r = await new PsaCertLookup(t429).byCertNumber("49385027");
    expect(r.kind).toBe("quota");
  });

  it("reads cert fields whether nested under PSACert or inlined top-level", async () => {
    const inlined = { ...load("psa-charizard.json").PSACert, IsValidRequest: true, ServerMessage: "Request successful" };
    const psa = new PsaCertLookup(new FixtureTransport([{ match: CERT, body: inlined }]));
    const r = await psa.byCertNumber("49385027");
    expect(r.kind).toBe("ok");
    if (r.kind === "ok") expect(r.cert.name).toBe("CHARIZARD-HOLO");
  });
});
