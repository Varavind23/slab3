/**
 * The 2026-10-29 scanner auth wall: does a Courtyard account get the data back?
 *
 * Why this exists: since ~03:25 UTC 2026-10-29 `/scanner/card-details` answers
 * 401 {"message":"authentication required"} to every anonymous request
 * (spike/README.md §2g). The fix (bring-your-own Courtyard account, owner
 * decisions C1–C4) rests on facts this script establishes before anything is
 * built:
 *   1. Which headers Privy's passwordless login needs from a SERVER. Owner
 *      decision C4: try honest headers first; send courtyard.io's Origin only
 *      if Privy refuses without it — and record which.
 *   2. Whether a fresh bearer unlocks card-details (bar: 96679812 = $50.80,
 *      confidence 2), and WHICH of the returned tokens it is.
 *   3. The refresh call's shape, and what replaying a spent refresh token does
 *      — Privy rotates them single-use, which decides how the server must
 *      serialize concurrent refreshes.
 *
 * Two runs, because the code arrives out of band:
 *   npx tsx courtyard/wall-probe.ts                 # sends the code
 *   CY_CODE=123456 npx tsx courtyard/wall-probe.ts  # everything else
 * Prints statuses, key names and expiries only — never a token. The session is
 * written to .state/ (gitignored). SPIKE_HOME points at the spike dir that holds
 * .env/.state when running from a worktree.
 */
import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";

const HOME = process.env.SPIKE_HOME ?? new URL("..", import.meta.url).pathname;
const STATE = `${HOME}/.state`;
const SESSION_FILE = `${STATE}/courtyard-session.json`;
const MODE_FILE = `${STATE}/courtyard-wall-headers.json`;
const PRIVY = "https://auth.privy.io/api/v1";
const UA = "Slabs/1.0 (graded-card inventory)";
const SCANNER = "https://api.courtyard.io/scanner/card-details?cert=96679812&grader=PSA";

function fromDotEnv(key: string): string | undefined {
  const path = `${HOME}/.env`;
  if (!existsSync(path)) return undefined;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*)$/);
    if (m && m[1] === key) return m[2].trim().replace(/^["']|["']$/g, "");
  }
}

const EMAIL = process.env.CY_EMAIL ?? fromDotEnv("CY_EMAIL");
if (!EMAIL) throw new Error("Set CY_EMAIL (env or spike/.env)");
mkdirSync(STATE, { recursive: true });
const app = JSON.parse(readFileSync(`${STATE}/courtyard-privy-app.json`, "utf8")) as {
  appId: string;
  clientId?: string;
};

type HeaderMode = "honest" | "origin";
function privyHeaders(mode: HeaderMode, bearer?: string): Record<string, string> {
  const h: Record<string, string> = {
    "Content-Type": "application/json",
    "privy-app-id": app.appId,
    "User-Agent": UA,
  };
  if (app.clientId) h["privy-client-id"] = app.clientId;
  if (mode === "origin") Object.assign(h, { Origin: "https://courtyard.io", Referer: "https://courtyard.io/" });
  if (bearer) h.Authorization = `Bearer ${bearer}`;
  return h;
}

const exp = (jwt?: string) => {
  try {
    return new Date(JSON.parse(Buffer.from(jwt!.split(".")[1], "base64url").toString()).exp * 1000).toISOString();
  } catch {
    return "(not a JWT)";
  }
};
const short = (s: string) => s.replace(/[A-Za-z0-9_\-.]{40,}/g, "<redacted>").slice(0, 300);

// Courtyard's Privy app runs in HTTP-only COOKIE mode (found 2026-10-29): the
// body's refresh_token is the literal "deprecated" and the real one arrives as a
// `privy-refresh-token` Set-Cookie. A server keeps the cookies itself.
type Jar = Record<string, string>;
function absorb(jar: Jar, r: Response) {
  for (const c of r.headers.getSetCookie()) {
    const [pair] = c.split(";");
    const i = pair.indexOf("=");
    const name = pair.slice(0, i).trim(), value = pair.slice(i + 1).trim();
    if (!name.startsWith("privy-")) continue;
    if (value === "deleted" || /Max-Age=0/i.test(c)) delete jar[name];
    else jar[name] = value;
  }
}
const cookieHeader = (jar: Jar) => Object.entries(jar).map(([k, v]) => `${k}=${v}`).join("; ");

async function post(path: string, mode: HeaderMode, body: unknown, bearer?: string, jar?: Jar, base = PRIVY) {
  const headers = privyHeaders(mode, bearer);
  if (jar && Object.keys(jar).length) headers.Cookie = cookieHeader(jar);
  const r = await fetch(`${base}${path}`, { method: "POST", headers, body: JSON.stringify(body) });
  const text = await r.text();
  const setCookies = r.headers.getSetCookie().map((c) => c.split("=")[0]);
  if (jar) absorb(jar, r);
  return { status: r.status, text, setCookies };
}

async function scanner(label: string, bearer?: string) {
  const h: Record<string, string> = { Accept: "application/json", "User-Agent": UA, "cy-supports-acquisition-status": "1" };
  if (bearer) h.Authorization = `Bearer ${bearer}`;
  const r = await fetch(SCANNER, { headers: h });
  const t = await r.text();
  let summary = short(t);
  try {
    const j = JSON.parse(t);
    if (j.priceModel) summary = `price=${j.priceModel.price} confidence=${j.priceModel.priceConfidence}`;
  } catch {}
  console.log(`    [scanner] ${label}: HTTP ${r.status} ${summary}`);
  return r.status;
}

const code = (process.env.CY_CODE ?? "").trim();

if (!code) {
  // ── Run 1: send the code. Honest headers first (C4). ──────────────────────
  for (const mode of ["honest", "origin"] as HeaderMode[]) {
    const r = await post("/passwordless/init", mode, { email: EMAIL });
    console.log(`[init] headers=${mode}: HTTP ${r.status} ${short(r.text)}`);
    if (r.status === 200) {
      writeFileSync(MODE_FILE, JSON.stringify({ mode, at: new Date().toISOString() }));
      console.log(`Code sent with ${mode} headers. Rerun with CY_CODE=<code>.`);
      process.exit(0);
    }
  }
  console.log("init refused with both header sets — stop, record it.");
  process.exit(1);
}

// ── Run 2 ────────────────────────────────────────────────────────────────────
const { mode } = JSON.parse(readFileSync(MODE_FILE, "utf8")) as { mode: HeaderMode };
console.log(`[auth] using the ${mode} headers that sent the code`);

// `no-signup` first: the connect flow must never create a Courtyard account
// behind the user's back. If Privy rejects the mode itself, fall back and say so.
const jar: Jar = {};
let auth = await post("/passwordless/authenticate", mode, { email: EMAIL, code, mode: "no-signup" }, undefined, jar);
console.log(`[auth] mode=no-signup: HTTP ${auth.status}${auth.status === 200 ? "" : " " + short(auth.text)}`);
if (auth.status !== 200 && /mode/i.test(auth.text)) {
  auth = await post("/passwordless/authenticate", mode, { email: EMAIL, code, mode: "login-or-sign-up" }, undefined, jar);
  console.log(`[auth] mode=login-or-sign-up: HTTP ${auth.status}${auth.status === 200 ? "" : " " + short(auth.text)}`);
}
if (auth.status !== 200) process.exit(1);

const s = JSON.parse(auth.text);
writeFileSync(SESSION_FILE, JSON.stringify({ ...s, cookies: jar, capturedAt: new Date().toISOString() }, null, 2));
console.log(`    set-cookie names: ${auth.setCookies.join(", ")}; jar: ${Object.keys(jar).join(", ")}`);
console.log(`    keys: ${Object.keys(s).join(", ")}`);
console.log(`    is_new_user=${s.is_new_user} token exp=${exp(s.token)} privy_access_token exp=${exp(s.privy_access_token)} identity_token=${s.identity_token ? "present" : "absent"} refresh=${s.refresh_token ? "present" : "absent"}`);
console.log(`    token === privy_access_token: ${s.token === s.privy_access_token}`);

// ── Does a bearer unlock the scanner, and which one? ─────────────────────────
console.log("[2] scanner, cert 96679812 (bar: $50.80, confidence 2)");
await scanner("anonymous");
await scanner("token", s.token);
if (s.privy_access_token && s.privy_access_token !== s.token) await scanner("privy_access_token", s.privy_access_token);
if (s.identity_token) await scanner("identity_token", s.identity_token);

// ── Refresh: shape, rotation, and what a replayed refresh token does ─────────
// The cookie domain is privy.courtyard.io (Courtyard's Privy custom domain), so
// try it first; auth.privy.io is the fallback. Body carries "deprecated", as the
// SDK sends it in cookie mode.
console.log("[3] refresh (cookie mode)");
const jar0 = { ...jar };
let base = "";
let r1: Awaited<ReturnType<typeof post>> | undefined;
for (const b of ["https://privy.courtyard.io/api/v1", PRIVY]) {
  const trial = { ...jar0 };
  const r = await post("/sessions", mode, { refresh_token: s.refresh_token }, s.token, trial, b);
  console.log(`    refresh #1 via ${b}: HTTP ${r.status}${r.status === 200 ? "" : " " + short(r.text)} set-cookie: ${r.setCookies.join(",")}`);
  if (r.status === 200) { r1 = r; base = b; Object.assign(jar, trial); for (const k of Object.keys(jar)) if (!(k in trial)) delete jar[k]; break; }
}
if (!r1) process.exit(0);
const s1 = JSON.parse(r1.text);
console.log(`    keys: ${Object.keys(s1).join(", ")}`);
console.log(`    refresh cookie rotated=${jar["privy-refresh-token"] !== jar0["privy-refresh-token"]} new token exp=${exp(s1.token)} session_update_action=${s1.session_update_action}`);
writeFileSync(SESSION_FILE, JSON.stringify({ ...s1, cookies: jar, base, capturedAt: new Date().toISOString() }, null, 2));
await scanner("refreshed token", s1.token);

// Replay the spent cookie: the race loser's view.
const replayJar = { ...jar0 };
const r2 = await post("/sessions", mode, { refresh_token: s.refresh_token }, s.token, replayJar, base);
console.log(`    replay spent refresh cookie: HTTP ${r2.status} ${short(r2.text)}`);
// Did the replay revoke the family (the winner's session too)?
const r3 = await post("/sessions", mode, { refresh_token: s1.refresh_token }, s1.token, jar, base);
console.log(`    winner refreshes after replay: HTTP ${r3.status}${r3.status === 200 ? "" : " " + short(r3.text)}`);
if (r3.status === 200) {
  const s3 = JSON.parse(r3.text);
  writeFileSync(SESSION_FILE, JSON.stringify({ ...s3, cookies: jar, base, capturedAt: new Date().toISOString() }, null, 2));
  await scanner("token after second refresh", s3.token);
}
console.log("done — session (if alive) in .state/courtyard-session.json");
