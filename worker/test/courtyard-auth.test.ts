// Courtyard bring-your-own-account (2026-10-29): the Privy login relay, the
// session lease, and the scanner's bearer. Each case pins a fact measured live in
// spike/courtyard/wall-probe.ts (spike/README.md §2g) or a way a session could be
// lost — there is no password to fall back on, so a lost session means the user
// has to go find a new emailed code.
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import {
  startLogin,
  verifyLogin,
  refreshSession,
  absorbCookies,
  jwtExpiry,
  emailHint,
  type CySession,
} from "../../supabase/functions/_shared/courtyard-auth";
import {
  acquireCyToken,
  sealCySession,
  openCySession,
  REFRESH_MARGIN_MS,
  type CyCredStore,
  type SealedSession,
} from "../../supabase/functions/_shared/courtyard-session";
import { fetchCardDetails, fetchGraderImages } from "../../supabase/functions/_shared/courtyard-scanner";
import { generateKeyB64 } from "../../supabase/functions/_shared/crypto";

const PSA = JSON.parse(readFileSync(new URL("./fixtures/courtyard-scanner-psa.json", import.meta.url), "utf8"));
const NOW = Date.parse("2026-10-29T18:00:00Z");
const jwt = (expMs: number) =>
  `eyJhbGciOiJFUzI1NiJ9.${Buffer.from(JSON.stringify({ sid: "s", exp: Math.floor(expMs / 1000) })).toString("base64url")}.sig`;

/** A fetch that answers from a list and records what it was sent. */
function scripted(...answers: Array<{ status: number; body?: unknown; cookies?: string[] }>) {
  const seen: Array<{ url: string; init: RequestInit }> = [];
  const fetchFn = (async (url: string, init: RequestInit) => {
    seen.push({ url, init });
    const a = answers.shift() ?? { status: 500 };
    const h = new Headers({ "content-type": "application/json" });
    for (const c of a.cookies ?? []) h.append("set-cookie", c);
    return new Response(a.body === undefined ? "" : JSON.stringify(a.body), { status: a.status, headers: h });
  }) as unknown as typeof fetch;
  return { seen, fetchFn };
}
const kindOf = async (p: Promise<unknown>) => {
  try {
    await p;
    return "resolved";
  } catch (e) {
    return (e as { kind?: string }).kind ?? "threw";
  }
};

// Live 2026-10-29: authenticate's body says refresh_token "deprecated"; the real
// one is a cookie on Courtyard's Privy custom domain.
const LOGIN_COOKIES = [
  "privy-token=TOK; Domain=courtyard.io; Path=/; HttpOnly; Secure; SameSite=Strict",
  "privy-access-token=ACC; Domain=privy.courtyard.io; Path=/; HttpOnly; Secure",
  "privy-refresh-token=RT1; Domain=privy.courtyard.io; Path=/; HttpOnly; Secure",
  "privy-session=t; Domain=courtyard.io; Path=/; Secure",
  "__cf_bm=cloudflare; Domain=privy.io; Path=/",
];
const loginBody = (exp: number) => ({
  user: { id: "did:privy:abc" },
  token: jwt(exp),
  privy_access_token: null,
  refresh_token: "deprecated",
  session_update_action: "set",
  is_new_user: false,
});

describe("Privy login relay", () => {
  it("init sends Courtyard's Origin (Privy 403s missing_origin without it) and our own UA", async () => {
    const { seen, fetchFn } = scripted({ status: 200, body: { success: true } });
    await startLogin("a@b.co", { fetch: fetchFn });
    const h = seen[0].init.headers as Record<string, string>;
    expect(seen[0].url).toBe("https://auth.privy.io/api/v1/passwordless/init");
    expect(h.Origin).toBe("https://courtyard.io");
    expect(h["User-Agent"]).toMatch(/^Slabs\//);
    expect(h["privy-app-id"]).toBe("cldj2z0b70001mm08l39me9k5");
  });

  it("never signs anyone up: authenticate asks for no-signup", async () => {
    const { seen, fetchFn } = scripted({ status: 200, body: loginBody(NOW + 3600e3), cookies: LOGIN_COOKIES });
    await verifyLogin("a@b.co", "123456", { fetch: fetchFn });
    expect(JSON.parse(String(seen[0].init.body)).mode).toBe("no-signup");
  });

  it("keeps the privy-* cookies (the refresh token lives there) and drops Cloudflare's", async () => {
    const { fetchFn } = scripted({ status: 200, body: loginBody(NOW + 3600e3), cookies: LOGIN_COOKIES });
    const s = await verifyLogin("a@b.co", "123456", { fetch: fetchFn });
    expect(s.cookies).toEqual({
      "privy-token": "TOK",
      "privy-access-token": "ACC",
      "privy-refresh-token": "RT1",
      "privy-session": "t",
    });
    expect(s.expiresAt).toBe(Math.floor((NOW + 3600e3) / 1000) * 1000);
    expect(s.privyUserId).toBe("did:privy:abc");
  });

  it("a login without the refresh cookie is refused now, not silently dead in an hour", async () => {
    const { fetchFn } = scripted({ status: 200, body: loginBody(NOW + 3600e3) });
    expect(await kindOf(verifyLogin("a@b.co", "123456", { fetch: fetchFn }))).toBe("network");
  });

  it("maps Privy's live error shapes", async () => {
    const cases: Array<[number, unknown, string]> = [
      [422, { error: "Invalid email and code combination", code: "invalid_credentials" }, "invalid_code"],
      [400, { error: "[Input error] `email`: Invalid email address", code: "invalid_data" }, "invalid_email"],
      [429, { error: "Too many requests" }, "rate_limited"],
      [403, { error: "User does not exist", code: "no_signup" }, "no_account"],
      [503, { error: "upstream" }, "network"],
    ];
    for (const [status, body, kind] of cases) {
      const { fetchFn } = scripted({ status, body });
      expect(await kindOf(verifyLogin("a@b.co", "123456", { fetch: fetchFn })), `${status}`).toBe(kind);
    }
  });

  it("an unrecognised 4xx is never reported as a wrong code", async () => {
    const { fetchFn } = scripted({ status: 409, body: { error: "something new" } });
    expect(await kindOf(verifyLogin("a@b.co", "123456", { fetch: fetchFn }))).toBe("network");
  });
});

describe("Privy refresh (cookie mode)", () => {
  const s: CySession = {
    token: jwt(NOW - 1000),
    expiresAt: NOW - 1000,
    cookies: { "privy-refresh-token": "RT1", "privy-token": "TOK" },
    privyUserId: "did:privy:abc",
  };

  it("posts the bearer + cookies to Courtyard's Privy domain, and rotates the cookie", async () => {
    const { seen, fetchFn } = scripted({
      status: 200,
      body: { ...loginBody(NOW + 3600e3), session_update_action: "set" },
      cookies: ["privy-refresh-token=RT2; Domain=privy.courtyard.io; Path=/; HttpOnly"],
    });
    const next = await refreshSession(s, { fetch: fetchFn });
    const h = seen[0].init.headers as Record<string, string>;
    expect(seen[0].url).toBe("https://privy.courtyard.io/api/v1/sessions");
    expect(h.Authorization).toBe(`Bearer ${s.token}`);
    expect(h.Cookie).toContain("privy-refresh-token=RT1");
    expect(JSON.parse(String(seen[0].init.body))).toEqual({ refresh_token: "deprecated" });
    expect(next.cookies["privy-refresh-token"]).toBe("RT2");
    expect(next.cookies["privy-token"]).toBe("TOK"); // untouched cookies survive
    expect(next.expiresAt).toBeGreaterThan(NOW);
  });

  it("a refused refresh is a dead session; a 5xx or a dropped connection is not", async () => {
    expect(await kindOf(refreshSession(s, { fetch: scripted({ status: 401, body: { code: "missing_or_invalid_token" } }).fetchFn }))).toBe("auth_expired");
    expect(await kindOf(refreshSession(s, { fetch: scripted({ status: 502 }).fetchFn }))).toBe("network");
    const dropped = (async () => { throw new TypeError("fetch failed"); }) as unknown as typeof fetch;
    expect(await kindOf(refreshSession(s, { fetch: dropped }))).toBe("network");
  });

  it("a deleted cookie leaves the jar, as in a browser", () => {
    expect(absorbCookies({ "privy-refresh-token": "RT1" }, ["privy-refresh-token=deleted; Max-Age=0; Path=/"])).toEqual({});
  });
});

/** An in-memory courtyard_credentials row with the same lease semantics. */
function memStore(initial: SealedSession | null) {
  const st = { sealed: initial, leaseUntil: 0, writes: 0, leases: 0 };
  const store: CyCredStore = {
    async read() { return st.sealed; },
    async tryLease(until, now) {
      if (st.leaseUntil > now) return false;
      st.leaseUntil = until; st.leases++;
      return true;
    },
    async write(sealed) { st.sealed = sealed; st.leaseUntil = 0; st.writes++; },
    async release() { st.leaseUntil = 0; },
  };
  return { st, store };
}

describe("acquireCyToken: one refresh at a time, and a blip is never a dead session", () => {
  const key = generateKeyB64();
  const session = (exp: number): CySession => ({ token: jwt(exp), expiresAt: exp, cookies: { "privy-refresh-token": "RT1" } });
  const refreshed = scripted; // alias for readability
  const noSleep = async () => {};

  it("reuses a token that is not near expiry — no Privy call at all", async () => {
    const s = session(NOW + REFRESH_MARGIN_MS + 60_000);
    const { store } = memStore(await sealCySession(s, key));
    const { seen, fetchFn } = refreshed();
    expect(await acquireCyToken(store, key, { fetch: fetchFn, now: () => NOW })).toBe(s.token);
    expect(seen).toHaveLength(0);
  });

  it("refreshes near expiry, under the lease, and persists the rotated session", async () => {
    const { st, store } = memStore(await sealCySession(session(NOW + 60_000), key));
    const { fetchFn } = refreshed({
      status: 200,
      body: loginBody(NOW + 3600e3),
      cookies: ["privy-refresh-token=RT2; Path=/"],
    });
    const token = await acquireCyToken(store, key, { fetch: fetchFn, now: () => NOW });
    expect(token).toBe(jwt(NOW + 3600e3));
    expect(st.writes).toBe(1);
    expect(st.leaseUntil).toBe(0);
    expect((await openCySession(st.sealed, key))!.cookies["privy-refresh-token"]).toBe("RT2");
  });

  it("a caller that loses the lease never refreshes: it waits for the winner's row", async () => {
    const { st, store } = memStore(await sealCySession(session(NOW - 1000), key));
    st.leaseUntil = NOW + 10_000; // someone else is mid-refresh
    const winner = session(NOW + 3600e3);
    let reads = 0;
    const base = store.read;
    store.read = async () => {
      if (++reads === 2) st.sealed = await sealCySession(winner, key); // the winner writes
      return base();
    };
    const { seen, fetchFn } = refreshed();
    expect(await acquireCyToken(store, key, { fetch: fetchFn, now: () => NOW, sleep: noSleep })).toBe(winner.token);
    expect(seen).toHaveLength(0);
  });

  it("a loser that never sees a fresh row is TRANSIENT, not auth_expired", async () => {
    const { st, store } = memStore(await sealCySession(session(NOW - 1000), key));
    st.leaseUntil = NOW + 10_000;
    expect(await kindOf(acquireCyToken(store, key, { fetch: refreshed().fetchFn, now: () => NOW, sleep: noSleep }))).toBe("network");
  });

  it("a refresh blip with a still-valid token uses that token and frees the lease", async () => {
    const s = session(NOW + 60_000);
    const { st, store } = memStore(await sealCySession(s, key));
    expect(await acquireCyToken(store, key, { fetch: refreshed({ status: 502 }).fetchFn, now: () => NOW })).toBe(s.token);
    expect(st.leaseUntil).toBe(0);
  });

  it("only Privy refusing the refresh is auth_expired, and the row is kept", async () => {
    const { st, store } = memStore(await sealCySession(session(NOW - 1000), key));
    expect(await kindOf(acquireCyToken(store, key, { fetch: refreshed({ status: 401 }).fetchFn, now: () => NOW }))).toBe("auth_expired");
    expect(st.sealed).not.toBeNull();
    expect(st.leaseUntil).toBe(0);
  });

  it("an unreadable row (rotated key) is auth_expired — there is no password to fall back on", async () => {
    const { store } = memStore(await sealCySession(session(NOW + 3600e3), generateKeyB64()));
    expect(await kindOf(acquireCyToken(store, key, { fetch: refreshed().fetchFn, now: () => NOW }))).toBe("auth_expired");
  });

  it("the sealed row does not contain the token or the refresh cookie", async () => {
    const sealed = JSON.stringify(await sealCySession(session(NOW), key));
    expect(sealed).not.toContain("RT1");
    expect(sealed).not.toContain("eyJ");
  });
});

describe("scanner bearer (2026-10-29: card-details 401s anonymously)", () => {
  it("card-details carries the user's bearer", async () => {
    const { seen, fetchFn } = scripted({ status: 200, body: PSA });
    await fetchCardDetails("96679812", "psa", { fetch: fetchFn, bearer: "T" });
    expect((seen[0].init.headers as Record<string, string>).Authorization).toBe("Bearer T");
  });

  it("a 401 is auth_expired and stops at one call — not walked through the grader pairings", async () => {
    const { seen, fetchFn } = scripted({ status: 401, body: { message: "authentication required" } }, { status: 200, body: PSA });
    expect(await kindOf(fetchCardDetails("96679812", "psa", { fetch: fetchFn, bearer: "T" }))).toBe("auth_expired");
    expect(seen).toHaveLength(1);
  });

  it("a 403 (the UA wall's bare HTML) stays source_error — not the user's credential", async () => {
    const { fetchFn } = scripted({ status: 403 });
    expect(await kindOf(fetchCardDetails("96679812", "psa", { fetch: fetchFn, bearer: "T" }))).toBe("source_error");
  });

  it("card-grader-image is still anonymous: no bearer is sent", async () => {
    const { seen, fetchFn } = scripted({ status: 200, body: {} });
    await fetchGraderImages("96679812", "psa", { fetch: fetchFn, bearer: "T" });
    expect((seen[0].init.headers as Record<string, string>).Authorization).toBeUndefined();
  });
});

describe("small pure helpers", () => {
  it("jwtExpiry reads exp, and anything else is undefined", () => {
    expect(jwtExpiry(jwt(NOW))).toBe(NOW);
    expect(jwtExpiry("not.a.jwt")).toBeUndefined();
    expect(jwtExpiry(null)).toBeUndefined();
  });
  it("emailHint says which account without keeping the address", () => {
    expect(emailHint("sam@example.com")).toBe("s•••@example.com");
  });
});

