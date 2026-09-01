/**
 * Courtyard account connect, Phase A: the Privy email-OTP relay.
 *
 * Why this exists (research 2026-08-29, spike/README.md §2a):
 * Courtyard has NO password to store, so Card Ladder's "keep email+password,
 * sign in server-side" pattern does not port. It authenticates with Privy, and
 * their web bundle drives two plain client endpoints:
 *     POST auth.privy.io/api/v1/passwordless/init          {email}
 *     POST auth.privy.io/api/v1/passwordless/authenticate   {email, code}
 * Both take only the PUBLIC `privy-app-id` header — Privy's app-secret Basic
 * Auth is for their server REST API, which is a different surface. So a server
 * CAN drive the login on the user's behalf: we call init, the user reads the
 * code from their own inbox, we call authenticate. That is the OTP relay.
 *
 * The token that comes back is the API bearer: courtyard.io's bundle sets
 * `OpenAPI.TOKEN = getAccessToken` straight from usePrivyClient(), so the Privy
 * access token IS what api.courtyard.io authenticates. There is no second
 * Courtyard-issued credential to obtain (/users/login exists, and step 5 checks
 * whether it is required — see probe-auth.ts for the full matrix).
 *
 * This is a SPIKE: it proves the flow end-to-end and captures the session for
 * probe-auth.ts. Nothing here ships. The production shape (a `courtyard-connect`
 * Edge Function storing the token encrypted in a deny-all table) is deliberately
 * NOT built until the scanner endpoint is found — see spike/courtyard-plan.md.
 *
 * Run:  CY_EMAIL=you@example.com npx tsx courtyard/privy-auth.ts
 *       (or put CY_EMAIL in spike/.env — gitignored, never committed)
 */
import { chromium } from "playwright";
import { mkdirSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline/promises";

const STATE_DIR = new URL("../.state/", import.meta.url).pathname;
const SESSION_FILE = STATE_DIR + "courtyard-session.json";
const APPID_FILE = STATE_DIR + "courtyard-privy-app.json";
const PRIVY = "https://auth.privy.io/api/v1";
const UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

/** spike/.env is gitignored and holds real credentials; env vars win. */
function fromDotEnv(key: string): string | undefined {
  const path = new URL("../.env", import.meta.url).pathname;
  if (!existsSync(path)) return undefined;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*)$/);
    if (m && m[1] === key) return m[2].trim().replace(/^["']|["']$/g, "");
  }
  return undefined;
}

const EMAIL = process.env.CY_EMAIL ?? fromDotEnv("CY_EMAIL");
if (!EMAIL) {
  console.error("Set CY_EMAIL (env var or spike/.env). Never commit it.");
  process.exit(1);
}
mkdirSync(STATE_DIR, { recursive: true });

/**
 * The app id is a PUBLIC client identifier, but it is injected at runtime — it
 * is in no static chunk on any server-rendered route, so it has to be observed.
 * Load courtyard.io, open the login modal, and read it off the privy-app-id
 * request header. Cached so later runs cost no browser.
 */
async function privyAppId(): Promise<{ appId: string; clientId?: string }> {
  if (existsSync(APPID_FILE)) return JSON.parse(readFileSync(APPID_FILE, "utf8"));

  console.log("[appid] not cached — capturing from courtyard.io ...");
  const browser = await chromium.launch({ headless: true });
  const page = await (await browser.newContext({ userAgent: UA })).newPage();
  let found: { appId: string; clientId?: string } | undefined;

  page.on("request", (r) => {
    if (found || !r.url().includes("privy.io")) return;
    const h = r.headers();
    if (h["privy-app-id"]) found = { appId: h["privy-app-id"], clientId: h["privy-client-id"] };
  });

  await page.goto("https://courtyard.io/", { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(9_000);
  // The Privy SDK only boots when the login modal mounts.
  for (const sel of ['text="Log in"', 'text="Login"', '[href*="login"]']) {
    const el = page.locator(sel).first();
    if (await el.count()) {
      await el.click({ timeout: 4_000 }).catch(() => {});
      break;
    }
  }
  await page.waitForTimeout(8_000);
  await browser.close();

  if (!found) throw new Error("privy-app-id not observed — the login modal may not have mounted");
  writeFileSync(APPID_FILE, JSON.stringify(found, null, 2));
  console.log(`[appid] captured: ${found.appId}`);
  return found;
}

function headers(app: { appId: string; clientId?: string }): Record<string, string> {
  const h: Record<string, string> = {
    "Content-Type": "application/json",
    "privy-app-id": app.appId,
    Origin: "https://courtyard.io",
    Referer: "https://courtyard.io/",
    "User-Agent": UA,
  };
  if (app.clientId) h["privy-client-id"] = app.clientId;
  return h;
}

const app = await privyAppId();

// Verifying the capture shouldn't cost a real OTP email.
if (process.env.CY_CAPTURE_ONLY === "1") {
  console.log(`[capture-only] appId=${app.appId} clientId=${app.clientId ?? "(none)"}`);
  process.exit(0);
}

const rerun = Boolean((process.env.CY_CODE ?? "").trim());
if (rerun) console.log(`[1] skipping init — CY_CODE supplied, code already outstanding for ${EMAIL}`);
else console.log(`[1] passwordless/init -> ${EMAIL}`);
const init = rerun ? undefined : await fetch(`${PRIVY}/passwordless/init`, {
  method: "POST",
  headers: headers(app),
  body: JSON.stringify({ email: EMAIL }),
});
if (init) {
  console.log(`    HTTP ${init.status} ${(await init.text()).slice(0, 200)}`);
  if (!init.ok) process.exit(1);
}

// The code arrives out of band (the user's inbox), so this runs either way:
// interactively on a TTY, or in two steps with CY_CODE when stdin is not a
// terminal — which is how an agent session drives it.
let code = (process.env.CY_CODE ?? "").trim();
if (!code) {
  if (!process.stdin.isTTY) {
    console.log("[2] Code sent. No TTY — rerun with the code once it arrives:");
    console.log("    CY_CODE=123456 npx tsx courtyard/privy-auth.ts");
    process.exit(0);
  }
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  code = (await rl.question("[2] Enter the code Courtyard emailed you: ")).trim();
  rl.close();
}

console.log("[3] passwordless/authenticate ...");
const auth = await fetch(`${PRIVY}/passwordless/authenticate`, {
  method: "POST",
  headers: headers(app),
  body: JSON.stringify({ email: EMAIL, code, mode: "login-or-sign-up" }),
});
const body = await auth.text();
console.log(`    HTTP ${auth.status}`);
if (!auth.ok) {
  console.error(`    ${body.slice(0, 400)}`);
  process.exit(1);
}

const session = JSON.parse(body);
writeFileSync(SESSION_FILE, JSON.stringify({ ...session, capturedAt: new Date().toISOString() }, null, 2));
// Field names vary by Privy version — report which token we actually got.
console.log(`[4] saved -> .state/courtyard-session.json`);
console.log(`    keys: ${Object.keys(session).join(", ")}`);
const token = session.token ?? session.access_token ?? session.identity_token;
console.log(`    bearer: ${token ? `${String(token).slice(0, 24)}... (len ${String(token).length})` : "NOT FOUND — inspect the file"}`);
console.log(`    user:   ${session.user?.id ?? "(none)"}`);
console.log(`    refresh:${session.refresh_token ? " present" : " absent"}`);

// Step 5 (the question that decides Phase 2's design): does api.courtyard.io
// take this token directly, or must it be exchanged at POST /users/login?
if (token) {
  const uid = session.user?.id;
  const probe = await fetch(`https://api.courtyard.io/users/ids/${encodeURIComponent(uid ?? "")}`, {
    headers: { Authorization: `Bearer ${token}`, "User-Agent": UA, Origin: "https://courtyard.io" },
  });
  console.log(`[5] GET /users/ids/{id} with Privy bearer -> HTTP ${probe.status}`);
  console.log(`    ${(await probe.text()).slice(0, 300)}`);
}
