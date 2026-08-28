// Symmetric encryption for Card Ladder credentials at rest.
//
// The user's OWN Card Ladder email/password are stored server-side (deny-all table,
// service role only) so the worker can fetch prices on their behalf. We encrypt the
// blob with AES-256-GCM under a key held only as an Edge Function secret
// (`CL_ENC_KEY`, base64 of 32 random bytes) — so a DB dump alone never exposes a
// credential. Web Crypto only ⇒ identical in Deno and Node.

const ALG = "AES-GCM";

async function importKey(keyB64: string): Promise<CryptoKey> {
  const raw = b64decode(keyB64);
  if (raw.length !== 32) throw new Error("CL_ENC_KEY must be base64 of exactly 32 bytes");
  return crypto.subtle.importKey("raw", raw, ALG, false, ["encrypt", "decrypt"]);
}

/** Encrypt plaintext → base64("iv" ‖ ciphertext+tag). */
export async function encryptSecret(plaintext: string, keyB64: string): Promise<string> {
  const key = await importKey(keyB64);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: ALG, iv }, key, new TextEncoder().encode(plaintext)));
  const out = new Uint8Array(iv.length + ct.length);
  out.set(iv, 0);
  out.set(ct, iv.length);
  return b64encode(out);
}

/** Decrypt a blob produced by encryptSecret back to plaintext. */
export async function decryptSecret(blobB64: string, keyB64: string): Promise<string> {
  const key = await importKey(keyB64);
  const buf = b64decode(blobB64);
  const iv = buf.slice(0, 12);
  const ct = buf.slice(12);
  const pt = await crypto.subtle.decrypt({ name: ALG, iv }, key, ct);
  return new TextDecoder().decode(pt);
}

/** Generate a fresh base64 32-byte key (for `supabase secrets set CL_ENC_KEY=...`). */
export function generateKeyB64(): string {
  return b64encode(crypto.getRandomValues(new Uint8Array(32)));
}

function b64encode(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}
function b64decode(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
