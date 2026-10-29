/**
 * Privy refresh AFTER the access token expires — the half wall-probe.ts could
 * not test (a refresh inside the token's lifetime answers
 * session_update_action "ignore" with the same token, so rotation never runs).
 *
 * Why it matters (spike/README.md §2g): Courtyard's Privy app is in HTTP-only
 * cookie mode, so the refresh token is the `privy-refresh-token` cookie the
 * server keeps. Privy documents refresh tokens as single-use and rotated; this
 * records whether the cookie actually rotates on expiry, and what a replay of
 * the spent cookie answers — the race loser's view, which decides whether
 * courtyard-session.ts may let two calls refresh at once (it does not: it
 * leases the refresh, so the answer here only sharpens the error mapping).
 *
 * Reads .state/courtyard-session.json as written by wall-probe.ts. Prints
 * statuses and cookie NAMES only.
 *   SPIKE_HOME=~/slab3/spike npx tsx courtyard/privy-refresh.ts
 */
import { readFileSync, writeFileSync } from "node:fs";

const HOME = process.env.SPIKE_HOME ?? new URL("..", import.meta.url).pathname;
const FILE = `${HOME}/.state/courtyard-session.json`;
const app = JSON.parse(readFileSync(`${HOME}/.state/courtyard-privy-app.json`, "utf8"));
const s = JSON.parse(readFileSync(FILE, "utf8"));
const base: string = s.base ?? "https://privy.courtyard.io/api/v1";
const UA = "Slabs/1.0 (graded-card inventory)";
const exp = (jwt: string) => JSON.parse(Buffer.from(jwt.split(".")[1], "base64url").toString()).exp * 1000;
const red = (t: string) => t.replace(/[A-Za-z0-9_\-.]{40,}/g, "<redacted>").slice(0, 200);

type Jar = Record<string, string>;
async function refresh(token: string, jar: Jar) {
  const r = await fetch(`${base}/sessions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json", "privy-app-id": app.appId, "privy-client-id": app.clientId,
      "User-Agent": UA, Origin: "https://courtyard.io", Referer: "https://courtyard.io/",
      Authorization: `Bearer ${token}`,
      Cookie: Object.entries(jar).map(([k, v]) => `${k}=${v}`).join("; "),
    },
    body: JSON.stringify({ refresh_token: "deprecated" }),
  });
  const text = await r.text();
  const out: Jar = { ...jar };
  for (const c of r.headers.getSetCookie()) {
    const [pair] = c.split(";"); const i = pair.indexOf("=");
    const k = pair.slice(0, i), v = pair.slice(i + 1);
    if (!k.startsWith("privy-")) continue;
    if (v === "deleted" || /Max-Age=0/i.test(c)) delete out[k]; else out[k] = v;
  }
  return { status: r.status, text, jar: out };
}
async function scanner(token: string) {
  const r = await fetch("https://api.courtyard.io/scanner/card-details?cert=96679812&grader=PSA", {
    headers: { Accept: "application/json", "User-Agent": UA, "cy-supports-acquisition-status": "1", Authorization: `Bearer ${token}` },
  });
  return r.status;
}

console.log(`token expired: ${Date.now() > exp(s.token)} (exp ${new Date(exp(s.token)).toISOString()})`);
console.log(`scanner with expired token: HTTP ${await scanner(s.token)}`);

const r1 = await refresh(s.token, s.cookies);
console.log(`refresh #1: HTTP ${r1.status}${r1.status === 200 ? "" : " " + red(r1.text)}`);
if (r1.status !== 200) process.exit(0);
const s1 = JSON.parse(r1.text);
const rotated = r1.jar["privy-refresh-token"] !== s.cookies["privy-refresh-token"];
console.log(`  action=${s1.session_update_action} rotated=${rotated} new exp=${new Date(exp(s1.token)).toISOString()} cookies=${Object.keys(r1.jar).join(",")}`);
writeFileSync(FILE, JSON.stringify({ ...s1, cookies: r1.jar, base, capturedAt: new Date().toISOString() }, null, 2));
console.log(`scanner with refreshed token: HTTP ${await scanner(s1.token)}`);

if (rotated) {
  const r2 = await refresh(s.token, s.cookies);
  console.log(`replay of the spent cookie: HTTP ${r2.status} ${red(r2.text)}`);
  // The winner's new token is fresh, so its refresh answers "ignore" without
  // proving the family survived; what we can see is whether its own refresh
  // still answers 200 or is now refused.
  const r3 = await refresh(s1.token, r1.jar);
  console.log(`winner refresh after replay: HTTP ${r3.status} action=${r3.status === 200 ? JSON.parse(r3.text).session_update_action : red(r3.text)}`);
  if (r3.status === 200) writeFileSync(FILE, JSON.stringify({ ...JSON.parse(r3.text), cookies: r3.jar, base, capturedAt: new Date().toISOString() }, null, 2));
}
