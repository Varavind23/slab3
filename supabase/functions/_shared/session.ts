// Card Ladder session management for the Edge Functions (Deno).
//
// Holds the bring-your-own-account credential lifecycle: encrypt/decrypt the user's
// own CL email+password, and hand out a valid Firebase ID token — refreshing with
// the stored refresh token first, falling back to a full sign-in, so we mint new
// tokens rarely. All failures surface as the shared ClError kinds.

import { signIn, refresh, ClError, type ClSession } from "./cardladder.ts";
import { encryptSecret, decryptSecret } from "./crypto.ts";

export interface StoredCreds {
  email: string;
  password: string;
}

/** The live session: what `acquireIdToken` hands back to be persisted. */
export interface SessionState {
  refreshToken: string;
  expiresAt: number;
}

/** What is actually stored in cardladder_credentials.session_state: the session
 *  encrypted like the password (review 2026-10-02). It used to be the plain
 *  SessionState — a Firebase refresh token is standing access to the user's Card
 *  Ladder account, so a DB dump exposed every connected account, against
 *  crypto.ts's own promise. Rows written before this are still plain; they are
 *  read as-is and come back sealed on the next successful call. */
export type StoredSession = { enc: string } | SessionState;

export async function sealSession(s: SessionState, key: string): Promise<StoredSession> {
  return { enc: await encryptSecret(JSON.stringify(s), key) };
}

export async function openSession(stored: StoredSession | null, key: string): Promise<SessionState | null> {
  if (!stored) return null;
  if ("enc" in stored) {
    try {
      return JSON.parse(await decryptSecret(stored.enc, key));
    } catch {
      return null; // unreadable: fall through to a fresh sign-in, which rewrites it
    }
  }
  return stored.refreshToken ? stored : null;
}

export const encodeCreds = (c: StoredCreds, key: string): Promise<string> =>
  encryptSecret(JSON.stringify(c), key);

export async function decodeCreds(blob: string, key: string): Promise<StoredCreds> {
  return JSON.parse(await decryptSecret(blob, key));
}

const toState = (s: ClSession): SessionState => ({ refreshToken: s.refreshToken, expiresAt: s.expiresAt });

/** Get a usable ID token for a stored credential row. Tries refresh-token first
 *  (cheap, no password); on auth_expired falls back to a fresh sign-in with the
 *  decrypted credentials. Returns the token plus the (possibly rotated) session
 *  state to persist. Throws ClError (invalid_credentials/auth_expired/network). */
export async function acquireIdToken(
  row: { encrypted_blob: string; session_state: StoredSession | null },
  encKey: string,
): Promise<{ idToken: string; sessionState: SessionState }> {
  const rt = (await openSession(row.session_state, encKey))?.refreshToken;
  if (rt) {
    try {
      const s = await refresh(rt);
      return { idToken: s.idToken, sessionState: toState(s) };
    } catch (e) {
      // Only a DEAD refresh token falls back to the password. A network blip
      // used to as well — an extra password sign-in on every hiccup, the
      // pattern Firebase answers with TOO_MANY_ATTEMPTS (review 2026-10-02).
      if (!(e instanceof ClError && e.kind === "auth_expired")) throw e;
    }
  }
  let creds: StoredCreds;
  try {
    creds = await decodeCreds(row.encrypted_blob, encKey);
  } catch {
    // Undecryptable (a rotated CL_ENC_KEY, a damaged row). This used to surface
    // as a plain Error → "source_error" forever, with failure_count climbing and
    // the user never asked to reconnect. Reconnecting is the only fix.
    throw new ClError("auth_expired", "stored credentials could not be read");
  }
  const s = await signIn(creds.email, creds.password);
  return { idToken: s.idToken, sessionState: toState(s) };
}
