import { describe, it, expect } from "vitest";
import { CardLadderSource } from "../src/sources/cardladder.js";
import { TransportError, type JsonTransport } from "../src/sources/transport.js";

const identity = { cardKey: "psa:base-set:charizard:psa-9", grader: "psa" as const, name: "Charizard", set: "Base Set", grade: "PSA 9" };

describe("CardLadderSource error mapping (bridge behavior)", () => {
  it("maps a Cloudflare 403 challenge to auth_expired (reconnect prompt)", async () => {
    const t: JsonTransport = { getJson: async () => { throw new TransportError("403", 403); } };
    const r = await new CardLadderSource(t).lookup(identity);
    expect(r).toMatchObject({ kind: "error", error: "auth_expired" });
  });

  it("maps a 429 to rate_limited", async () => {
    const t: JsonTransport = { getJson: async () => { throw new TransportError("429", 429); } };
    const r = await new CardLadderSource(t).lookup(identity);
    expect(r).toMatchObject({ kind: "error", error: "rate_limited" });
  });

  it("maps a transport failure to a network error", async () => {
    const t: JsonTransport = { getJson: async () => { throw new Error("socket hang up"); } };
    const r = await new CardLadderSource(t).lookup(identity);
    expect(r).toMatchObject({ kind: "error", error: "network" });
  });

  it("degrades to not_found until the search contract is wired (never guesses a price)", async () => {
    const t: JsonTransport = { getJson: async () => ({ some: "shape we have not mapped yet" }) };
    const r = await new CardLadderSource(t).lookup(identity);
    expect(r).toMatchObject({ kind: "error", error: "not_found" });
  });
});
