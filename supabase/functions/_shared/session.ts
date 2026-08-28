// Card Ladder session management for the Edge Functions (Deno).
//
// Holds the bring-your-own-account credential lifecycle: encrypt/decrypt the user's
// own CL email+password, and hand out a valid Firebase ID token — refreshing with
// the stored refresh token first, falling back to a full sign-in, so we mint new
// tokens rarely. All failures surface as the shared ClError kinds.

import { signIn, refresh, type ClSession } from "./cardladder.ts";
import { encryptSecret, decryptSecret } from "./crypto.ts";

export interface StoredCreds {
  email: string;
  password: string;
}

/** What we persist in cardladder_credentials.session_state. */
export interface SessionState {
  refreshToken: string;
  expiresAt: number;
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
  row: { encrypted_blob: string; session_state: SessionState | null },
  encKey: string,
): Promise<{ idToken: string; sessionState: SessionState }> {
  const rt = row.session_state?.refreshToken;
  if (rt) {
    try {
      const s = await refresh(rt);
      return { idToken: s.idToken, sessionState: toState(s) };
    } catch {
      // refresh token dead → fall through to a full sign-in below.
    }
  }
  const creds = await decodeCreds(row.encrypted_blob, encKey);
  const s = await signIn(creds.email, creds.password);
  return { idToken: s.idToken, sessionState: toState(s) };
}
