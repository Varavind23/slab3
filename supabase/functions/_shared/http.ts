// Small shared helpers for the Edge Functions: JSON responses + identifying the
// caller (their Supabase user) and getting a service-role client for the deny-all
// worker tables.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

export const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

/** Service-role client — bypasses RLS, for the worker tables. */
export const admin = (): SupabaseClient =>
  createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

/** Resolve the calling Supabase user from the request's Authorization header, or
 *  null if unauthenticated. The token is passed explicitly to getUser() — without
 *  it, getUser() looks for a (non-existent) stored session and returns null even
 *  for a valid Bearer token. */
export async function callerId(req: Request): Promise<string | null> {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return null;
  const client = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
  const { data, error } = await client.auth.getUser(token);
  if (error) return null;
  return data.user?.id ?? null;
}

export function encKey(): string {
  const k = Deno.env.get("CL_ENC_KEY");
  if (!k) throw new Error("CL_ENC_KEY secret not set");
  return k;
}

/** The only certs and graders any function forwards upstream (review 2026-10-02).
 *  Nothing was checked: `grader` went unencoded into Courtyard's query string
 *  (`psa&cert=…` injected parameters), any string became a global cache row, and
 *  a script could loop `force` requests through our egress IP — which Courtyard
 *  403s when hammered, blanking it for every user. Same rule as CertParser and
 *  psa-cert: 7–10 digits. */
export function isSlab(cert: unknown, grader: unknown): cert is string {
  return typeof cert === "string" && /^\d{7,10}$/.test(cert) && (grader === "psa" || grader === "cgc");
}

/** A failed cache/credential write is not worth failing the request over — the
 *  answer is already in hand — but it must not vanish either. */
export function logWrite(what: string, error: { message: string } | null): void {
  if (error) console.error(`${what} write failed: ${error.message}`);
}
