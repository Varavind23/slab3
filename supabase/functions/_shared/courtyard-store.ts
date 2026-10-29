// courtyard_credentials over Supabase: the CyCredStore that courtyard-session.ts
// leases and writes through. Deno-only (imports supabase-js from esm.sh), so it is
// kept out of the cross-runtime courtyard-session.ts that worker/ vitest imports.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import type { CyCredStore, SealedSession } from "./courtyard-session.ts";

const TABLE = "courtyard_credentials";

export function cyCredStore(db: SupabaseClient, userId: string): CyCredStore {
  return {
    async read() {
      const { data, error } = await db.from(TABLE).select("session").eq("user_id", userId).maybeSingle();
      // Could not ask is not "disconnected": surface it as a transient failure.
      if (error) throw new Error(`courtyard_credentials read: ${error.message}`);
      return data ? data.session : null;
    },

    // The lease is a conditional UPDATE: it only matches when no live lease is
    // held, so of two concurrent callers exactly one gets its row back.
    async tryLease(untilMs, nowMs) {
      const { data, error } = await db
        .from(TABLE)
        .update({ refresh_lease_until: new Date(untilMs).toISOString() })
        .eq("user_id", userId)
        .or(`refresh_lease_until.is.null,refresh_lease_until.lt."${new Date(nowMs).toISOString()}"`)
        .select("user_id");
      if (error) return false;
      return (data?.length ?? 0) === 1;
    },

    async write(sealed: SealedSession) {
      const now = new Date().toISOString();
      const { error } = await db
        .from(TABLE)
        .update({ session: sealed, refresh_lease_until: null, last_ok_at: now, failure_count: 0, updated_at: now })
        .eq("user_id", userId);
      if (error) console.error(`courtyard_credentials write failed: ${error.message}`);
    },

    async release() {
      const { error } = await db.from(TABLE).update({ refresh_lease_until: null }).eq("user_id", userId);
      if (error) console.error(`courtyard_credentials lease release failed: ${error.message}`);
    },
  };
}

/** Count a failure without touching the session (it is never deleted on a
 *  failure — only the user's own disconnect deletes the row). */
export async function noteCyFailure(db: SupabaseClient, userId: string): Promise<void> {
  const { data } = await db.from(TABLE).select("failure_count").eq("user_id", userId).maybeSingle();
  if (!data) return;
  await db
    .from(TABLE)
    .update({ failure_count: (data.failure_count ?? 0) + 1, updated_at: new Date().toISOString() })
    .eq("user_id", userId);
}
