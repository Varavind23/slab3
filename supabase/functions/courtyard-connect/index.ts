// Edge Function: connect a user's OWN Courtyard account (bring-your-own-account).
//
// Why it exists: since ~03:25 UTC 2026-10-29 Courtyard's scanner answers 401 to
// anonymous requests, and the user's own Courtyard login unlocks it
// (spike/README.md §2g; owner decision C1). Courtyard has no password — it logs
// in by emailed code (Privy) — so connecting is two POSTs, not one:
//   {step:"start", email}         Privy emails the user a code.
//   {step:"verify", email, code}  We log in (never signing anyone up), PROVE the
//                                 token unlocks the scanner, then store the
//                                 session sealed in the deny-all
//                                 courtyard_credentials table.
// GET = connected? DELETE = disconnect. Same shape, statuses and "could not ask is
// not disconnected" rule as cardladder-connect. Nothing sensitive is echoed back.

import { startLogin, verifyLogin, logout, emailHint, CyAuthError } from "../_shared/courtyard-auth.ts";
import { sealCySession, openCySession } from "../_shared/courtyard-session.ts";
import { fetchCardDetails, CyError } from "../_shared/courtyard-scanner.ts";
import { admin, callerId, encKey, json } from "../_shared/http.ts";

const TABLE = "courtyard_credentials";
/** spike/README.md §2b's acceptance cert: a slab the scanner always prices. */
const PROOF_CERT = "96679812";

const authError = (e: unknown) => {
  const kind = e instanceof CyAuthError ? e.kind : "network";
  // invalid_email | invalid_code | no_account | rate_limited pass through as-is;
  // anything else is "we couldn't reach Courtyard", never "your code was wrong".
  const passthrough = ["invalid_email", "invalid_code", "no_account", "rate_limited"];
  return json({ ok: false, error: passthrough.includes(kind) ? kind : "courtyard_unreachable" });
};

Deno.serve(async (req) => {
  const userId = await callerId(req);
  if (!userId) return json({ ok: false, error: "unauthorized" }, 401);
  const db = admin();

  if (req.method === "GET") {
    const { data, error } = await db.from(TABLE).select("email_hint").eq("user_id", userId).maybeSingle();
    if (error) return json({ ok: false, error: "store_unreachable" });
    return json({ ok: true, connected: !!data, emailHint: data?.email_hint ?? undefined });
  }

  if (req.method === "DELETE") {
    const { data } = await db.from(TABLE).select("session").eq("user_id", userId).maybeSingle();
    const { error } = await db.from(TABLE).delete().eq("user_id", userId);
    if (error) return json({ ok: false, error: "store_failed" }, 500);
    // Best effort, after the delete: the row going is what stops us acting.
    const s = data ? await openCySession(data.session, encKey()) : null;
    if (s) await logout(s);
    return json({ ok: true, connected: false });
  }

  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

  let body: { step?: string; email?: string; code?: string };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "bad_request" }, 400);
  }
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  if (!email) return json({ ok: false, error: "bad_request" }, 400);

  if (body.step === "start") {
    try {
      await startLogin(email);
    } catch (e) {
      return authError(e);
    }
    return json({ ok: true, sent: true });
  }

  if (body.step !== "verify") return json({ ok: false, error: "bad_request" }, 400);
  const code = typeof body.code === "string" ? body.code.replace(/\s/g, "") : "";
  if (!/^\d{4,8}$/.test(code)) return json({ ok: false, error: "invalid_code" });

  let session;
  try {
    session = await verifyLogin(email, code);
  } catch (e) {
    return authError(e);
  }

  // Prove it before storing it: a session that does not unlock the scanner is
  // not a connection, and storing it would show "Connected" over em dashes.
  try {
    await fetchCardDetails(PROOF_CERT, "psa", { bearer: session.token });
  } catch (e) {
    const kind = e instanceof CyError ? e.kind : "network";
    if (kind === "auth_expired") return json({ ok: false, error: "courtyard_rejected" });
    // 404/5xx on the proof cert says nothing about the login; don't block on it.
    if (kind === "network") return json({ ok: false, error: "courtyard_unreachable" });
  }

  const now = new Date().toISOString();
  const { error } = await db.from(TABLE).upsert({
    user_id: userId,
    session: await sealCySession(session, encKey()),
    privy_user_id: session.privyUserId ?? null,
    email_hint: emailHint(email),
    refresh_lease_until: null,
    last_ok_at: now,
    failure_count: 0,
    updated_at: now,
  });
  if (error) return json({ ok: false, error: "store_failed" }, 500);
  return json({ ok: true, connected: true, emailHint: emailHint(email) });
});
