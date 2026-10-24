import { describe, it, expect } from "vitest";
import { CL_WEB_REFERER, signIn, refresh, resolveCert } from "../src/sources/cardladder.js";

// 2026-10-23: Card Ladder restricted its Firebase API key to its web app's
// referrers. Without a Referer on sign-in and refresh, Google answers 403
// API_KEY_HTTP_REFERRER_BLOCKED and every user's CL prices fail. Pins that both
// auth calls carry it, and that the Bearer-token data calls stay as they were.
type Call = { url: string; headers: Record<string, string> };
const recorder = (reply: unknown) => {
  const calls: Call[] = [];
  const fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({ url: String(input), headers: { ...(init?.headers as Record<string, string>) } });
    return new Response(JSON.stringify(reply), { status: 200, headers: { "content-type": "application/json" } });
  }) as typeof globalThis.fetch;
  return { calls, fetch };
};

describe("Card Ladder auth Referer", () => {
  it("is Card Ladder's web app", () => {
    expect(CL_WEB_REFERER).toBe("https://app.cardladder.com/");
  });

  it("is sent on sign-in", async () => {
    const r = recorder({ idToken: "id", refreshToken: "rt", expiresIn: "3600" });
    await signIn("a@b.c", "pw", { fetch: r.fetch });
    expect(r.calls).toHaveLength(1);
    expect(r.calls[0].url).toContain("identitytoolkit.googleapis.com");
    expect(r.calls[0].headers.referer).toBe(CL_WEB_REFERER);
  });

  it("is sent on token refresh", async () => {
    const r = recorder({ id_token: "id", refresh_token: "rt2", expires_in: "3600" });
    await refresh("rt", { fetch: r.fetch });
    expect(r.calls).toHaveLength(1);
    expect(r.calls[0].url).toContain("securetoken.googleapis.com");
    expect(r.calls[0].headers.referer).toBe(CL_WEB_REFERER);
  });

  it("is not sent on the Cloud Functions data calls", async () => {
    const r = recorder({ result: null });
    await resolveCert("tok", "20360362", "psa", { fetch: r.fetch }).catch(() => undefined);
    expect(r.calls.length).toBeGreaterThan(0);
    for (const c of r.calls) {
      expect(c.url).toContain("cloudfunctions.net");
      expect(c.headers.referer).toBeUndefined();
      expect(c.headers.authorization).toBe("Bearer tok");
    }
  });
});
