// Pins the shared-client fixes from the 2026-10-02 review. Each one is a way a
// wrong answer reached a GLOBAL 24h cache, or a credential sat in the clear.
import { describe, it, expect } from "vitest";
import { fetchCardDetails, CyError } from "../../supabase/functions/_shared/courtyard-scanner";
import {
  resolveCert,
  estimate,
  fetchProfileSales,
  ClError,
} from "../../supabase/functions/_shared/cardladder";
import { encryptSecret, decryptSecret, generateKeyB64 } from "../../supabase/functions/_shared/crypto";
import { sealSession, openSession } from "../../supabase/functions/_shared/session";

const reply = (body: unknown, status = 200): typeof fetch =>
  (async () =>
    new Response(typeof body === "string" ? body : JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    })) as unknown as typeof fetch;

const kindOf = async (p: Promise<unknown>): Promise<string> => {
  try {
    await p;
    return "resolved";
  } catch (e) {
    return (e as { kind?: string }).kind ?? "threw";
  }
};

describe("Courtyard: a 200 is only an answer if it carries the price model", () => {
  it("an empty 200 is transient, not a cacheable 'no price'", async () => {
    expect(await kindOf(fetchCardDetails("96679812", "psa", { fetch: reply({}) }))).toBe("source_error");
  });

  it("an edge page's message-only 200 is transient too", async () => {
    const r = fetchCardDetails("96679812", "psa", { fetch: reply({ message: "please wait" }) });
    await expect(r).rejects.toBeInstanceOf(CyError);
    expect(await kindOf(fetchCardDetails("96679812", "psa", { fetch: reply({ message: "please wait" }) }))).toBe(
      "source_error",
    );
  });

  it("the no-model-price answer (priceModel present, 0/0) is still an answer", async () => {
    const r = await fetchCardDetails("96679812", "psa", {
      fetch: reply({ priceModel: { price: 0, priceConfidence: "0" }, graderData: {} }),
    });
    expect(r.priceCents).toBeNull();
  });
});

describe("Card Ladder: no `result` is not an answer", () => {
  it("`{result: null}` is still 'no such cert'", async () => {
    expect(await resolveCert("t", "12345678", "psa", { fetch: reply({ result: null }) })).toBeNull();
  });

  it("an envelope with no result key is a network error, not 'no such cert'", async () => {
    expect(await kindOf(resolveCert("t", "12345678", "psa", { fetch: reply({}) }))).toBe("network");
  });

  it("an estimate that is not an object is not 'no value'", async () => {
    const card = { profileId: "psa-1", grade: "g9", grader: "psa" as const };
    expect(await kindOf(estimate("t", card, undefined, { fetch: reply({ result: null }) }))).toBe("network");
  });

  it("a sales reply without a list is not 'no comps'", async () => {
    expect(await kindOf(fetchProfileSales("t", "12345678", "psa", { fetch: reply({ result: {} }) }))).toBe("network");
    expect(await fetchProfileSales("t", "12345678", "psa", { fetch: reply({ result: { sales: [] } }) })).toEqual([]);
  });

  it("errors are the shared ClError", async () => {
    await expect(resolveCert("t", "12345678", "psa", { fetch: reply({}) })).rejects.toBeInstanceOf(ClError);
  });
});

describe("Credentials at rest", () => {
  const key = generateKeyB64();

  it("crypto round-trips, and a tampered blob does not decrypt", async () => {
    const blob = await encryptSecret("secret", key);
    expect(await decryptSecret(blob, key)).toBe("secret");
    const bytes = Buffer.from(blob, "base64");
    bytes[bytes.length - 1] ^= 1;
    await expect(decryptSecret(bytes.toString("base64"), key)).rejects.toThrow();
  });

  it("the stored session is sealed — no refresh token in the clear", async () => {
    const state = { refreshToken: "rt-secret", expiresAt: 123 };
    const stored = await sealSession(state, key);
    expect(JSON.stringify(stored)).not.toContain("rt-secret");
    expect(await openSession(stored, key)).toEqual(state);
  });

  it("a row written before sealing still reads", async () => {
    expect(await openSession({ refreshToken: "legacy", expiresAt: 1 }, key)).toEqual({
      refreshToken: "legacy",
      expiresAt: 1,
    });
  });

  it("a sealed session under another key reads as none (falls back to sign-in)", async () => {
    const stored = await sealSession({ refreshToken: "x", expiresAt: 1 }, key);
    expect(await openSession(stored, generateKeyB64())).toBeNull();
  });
});
