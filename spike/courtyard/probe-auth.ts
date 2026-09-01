/**
 * Courtyard account connect, Phase B: does authentication unlock a cert-keyed
 * price? (spike/courtyard-plan.md; research 2026-08-29 in spike/README.md §2a)
 *
 * The question this answers, and why it is worth one sitting: their app's
 * scanner prices cards Courtyard does NOT vault, keyed by CERT — the app's own
 * error string is "Failed to fetch scanner data for cert: {{cert}}". No such
 * route exists in the web API: the generated client in their bundle is exactly
 * 172 endpoints and every pricing one is per-vaulted-asset
 * (/index/asset/{id}/estimate) or owner-scoped (/pricing/instant-sell-offer*,
 * which 403s with "caller is not the asset owner"). So the expected result here
 * is NEGATIVE, and a negative is a real result: it retires the "just connect an
 * account" theory with evidence and sends us to the APK teardown.
 *
 * Two rules this file keeps:
 *   * The guess list is FIXED and CAPPED (MAX_GUESSES). This is a bounded check
 *     against a service the owner holds an account with, not open fuzzing; it
 *     stops at the cap whatever it finds.
 *   * Everything is rate-limited. This machine's IP is already 403-blocked on
 *     the /index/* prefix from earlier probing (2026-08-29) while /orderbook/*
 *     and /configs/* still answer 200 — so a 403 on /index/* from here is
 *     INCONCLUSIVE and is flagged as such, never recorded as "closed".
 *
 * Run:  npx tsx courtyard/probe-auth.ts     (needs .state/courtyard-session.json
 *       from privy-auth.ts; runs the anonymous probes without it)
 */
import { existsSync, readFileSync, appendFileSync, mkdirSync } from "node:fs";

const STATE_DIR = new URL("../.state/", import.meta.url).pathname;
const SESSION_FILE = STATE_DIR + "courtyard-session.json";
const OUT = STATE_DIR + "courtyard-probe.jsonl";
const API = "https://api.courtyard.io";
const UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

/** The live bar: Courtyard's own app reads $50.80 / confidence 2 for this cert,
 *  and it is absent from the marketplace index entirely. */
const CERT = "96679812";
const GRADER = "PSA";
/** A slab that IS vaulted, so "authenticated vs anonymous" is a fair comparison.
 *  Resolved from Algolia at runtime — assets age out of the index. */
const ALGOLIA = {
  app: "Y8TL3M06QA",
  key: "3b3ed18284ca0baee9a496aea5f093d6",
  index: "marketplace_prod_recently_listed",
};

const MAX_GUESSES = 20;
const DELAY_MS = 1_100;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

mkdirSync(STATE_DIR, { recursive: true });

let token: string | undefined;
let userId: string | undefined;
if (existsSync(SESSION_FILE)) {
  const s = JSON.parse(readFileSync(SESSION_FILE, "utf8"));
  token = s.token ?? s.access_token ?? s.identity_token;
  userId = s.user?.id;
  console.log(`[session] token ${token ? "present" : "MISSING"}, user ${userId ?? "(none)"}`);
} else {
  console.log("[session] none — run privy-auth.ts first. Anonymous probes only.");
}

interface Probe {
  step: string;
  method: string;
  url: string;
  status: number;
  authed: boolean;
  note?: string;
  body: string;
}

async function probe(step: string, url: string, opts: { method?: string; body?: unknown; authed?: boolean } = {}) {
  const authed = opts.authed ?? false;
  if (authed && !token) return;
  const headers: Record<string, string> = { "User-Agent": UA, Origin: "https://courtyard.io" };
  if (opts.body) headers["Content-Type"] = "application/json";
  if (authed && token) headers.Authorization = `Bearer ${token}`;

  let status = 0;
  let text = "";
  try {
    const res = await fetch(API + url, {
      method: opts.method ?? "GET",
      headers,
      body: opts.body ? JSON.stringify(opts.body) : undefined,
    });
    status = res.status;
    text = (await res.text()).slice(0, 600);
  } catch (e) {
    text = `FETCH ERROR: ${String(e)}`;
  }

  // A 403 on /index/* from this machine is the known IP block, not evidence.
  const note =
    status === 403 && url.startsWith("/index/")
      ? "INCONCLUSIVE: this IP is rate-limited on /index/* — recheck from clean egress"
      : undefined;

  const rec: Probe = { step, method: opts.method ?? "GET", url, status, authed, note, body: text };
  appendFileSync(OUT, JSON.stringify({ ...rec, at: new Date().toISOString() }) + "\n");
  console.log(`  ${authed ? "auth" : "anon"} ${status} ${opts.method ?? "GET"} ${url}${note ? "  <-- " + note : ""}`);
  if (status >= 200 && status < 300) console.log(`       ${text.slice(0, 200)}`);
  await sleep(DELAY_MS);
  return rec;
}

/** A currently-vaulted assetID (proofOfIntegrity on an Algolia hit IS the assetID). */
async function vaultedAssetId(): Promise<string | undefined> {
  const res = await fetch(`https://${ALGOLIA.app}-dsn.algolia.net/1/indexes/${ALGOLIA.index}/query`, {
    method: "POST",
    headers: {
      "X-Algolia-Application-Id": ALGOLIA.app,
      "X-Algolia-API-Key": ALGOLIA.key,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ query: "charizard", hitsPerPage: 1 }),
  });
  const j = await res.json();
  return j?.hits?.[0]?.proofOfIntegrity;
}

console.log("\n=== 1. Does the Privy token authenticate api.courtyard.io? ===");
if (userId) {
  await probe("auth-check", `/users/ids/${userId}`, { authed: true });
  await probe("auth-check", `/users/${userId}`, { authed: true });
  await probe("auth-check-anon", `/users/${userId}`, { authed: false });
}
// If the bearer alone is rejected, the token may need exchanging here. Body shape
// is not in the bundle (the web client never calls it), so try the plausible ones.
for (const body of [{ token }, { privyToken: token }, { accessToken: token }]) {
  if (!token) break;
  await probe("users-login", "/users/login", { method: "POST", body, authed: true });
}

console.log("\n=== 2. Does auth change per-asset pricing? ===");
const assetId = await vaultedAssetId();
console.log(`[algolia] vaulted assetId: ${assetId ?? "NOT RESOLVED"}`);
if (assetId) {
  await probe("estimate-anon", `/index/asset/${assetId}/estimate`, { authed: false });
  await probe("estimate-auth", `/index/asset/${assetId}/estimate`, { authed: true });
  await probe("price-history-auth", `/index/asset/${assetId}/price-history`, { authed: true });
}

console.log("\n=== 3. Does anything accept a CERT? ===");
await probe("attributes", `/index/attributes?certification.number=${CERT}`, { authed: true });
await probe("instant-sell-cert", "/pricing/instant-sell-offers", {
  method: "POST",
  body: { certificationNumber: CERT, grader: GRADER },
  authed: true,
});

console.log(`\n=== 4. Bounded guess list (hard cap ${MAX_GUESSES}) ===`);
// Derived from the react-query keys in their shared bundle:
// GET_SCANNER_CARD_DETAILS = "get_scanner_card_details",
// GET_SCANNER_CARD_GRADER_IMAGE = "get_scanner_card_grader_image".
const GUESSES = [
  `/scanner/card-details?cert=${CERT}`,
  `/scanner/card-details/${CERT}`,
  `/scanner/cards/${CERT}`,
  `/scanner/card/${GRADER}/${CERT}`,
  `/scanner/${GRADER}/${CERT}`,
  `/index/scanner/card-details?cert=${CERT}`,
  `/index/scanner/${CERT}`,
  `/index/cards/${CERT}`,
  `/index/cert/${CERT}`,
  `/cards/${CERT}`,
  `/cards/${GRADER}/${CERT}`,
  `/cards/cert/${CERT}`,
  `/collectible-cards/${CERT}`,
  `/collectible-cards/cert/${CERT}`,
  `/pricing/scanner/${CERT}`,
  `/pricing/card/${CERT}`,
  `/pricing/cert/${CERT}`,
  `/index/asset/cert/${CERT}`,
];
if (GUESSES.length > MAX_GUESSES) throw new Error(`guess list ${GUESSES.length} exceeds cap ${MAX_GUESSES}`);
for (const g of GUESSES) await probe("guess", g, { authed: true });

console.log(`\nDone. Full record: .state/courtyard-probe.jsonl`);
console.log("Any 200 in step 3 or 4 is the finding. Otherwise the theory is retired -> APK teardown.");
