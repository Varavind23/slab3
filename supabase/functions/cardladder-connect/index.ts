// Edge Function: connect a user's OWN Card Ladder account (bring-your-own-account).
//
// The user enters their Card Ladder email/password in the app. We validate them by
// doing a real Firebase sign-in, then store them AES-GCM-encrypted in the deny-all
// cardladder_credentials table (service role). Nothing sensitive is ever echoed
// back — only a connected/failed verdict. Their subscription, their credentials,
// their consent: this is the ToS-defensible access model.

import { signIn, ClError } from "../_shared/cardladder.ts";
import { encodeCreds, type SessionState } from "../_shared/session.ts";
import { admin, callerId, encKey, json } from "../_shared/http.ts";

Deno.serve(async (req) => {
  const userId = await callerId(req);
  if (!userId) return json({ ok: false, error: "unauthorized" }, 401);

  // GET = "is THIS user connected?" — the server is the authority, because the
  // credentials live here (per auth user), not on the device.
  //
  // Added 2026-08-29: the app tracked connection in a local UserDefaults flag, so
  // a reinstall (or a second build with its own container) reported "not
  // connected" and short-circuited BEFORE ever calling the server — the user's
  // Card Ladder prices silently vanished until they retyped credentials the
  // server already had. Costs no Card Ladder request: it only asks whether a
  // credentials row exists.
  if (req.method === "GET") {
    const { data } = await admin()
      .from("cardladder_credentials")
      .select("user_id")
      .eq("user_id", userId)
      .maybeSingle();
    return json({ ok: true, connected: !!data });
  }

  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

  let email: string, password: string;
  try {
    ({ email, password } = await req.json());
  } catch {
    return json({ ok: false, error: "bad_request" }, 400);
  }
  if (!email || !password) return json({ ok: false, error: "bad_request" }, 400);

  // Validate against Card Ladder before we store anything.
  let session;
  try {
    session = await signIn(email, password);
  } catch (e) {
    // Business outcomes return 200 so the client decodes them uniformly (only
    // transport/auth problems throw on the client side).
    if (e instanceof ClError && e.kind === "invalid_credentials") {
      return json({ ok: false, error: "invalid_credentials" });
    }
    return json({ ok: false, error: "card_ladder_unreachable" });
  }

  const sessionState: SessionState = { refreshToken: session.refreshToken, expiresAt: session.expiresAt };
  const encrypted_blob = await encodeCreds({ email, password }, encKey());

  const { error } = await admin()
    .from("cardladder_credentials")
    .upsert({
      user_id: userId,
      encrypted_blob,
      session_state: sessionState,
      last_ok_at: new Date().toISOString(),
      failure_count: 0,
      updated_at: new Date().toISOString(),
    });
  if (error) return json({ ok: false, error: "store_failed" }, 500);

  return json({ ok: true, connected: true });
});
