// Card Ladder price source (plan: T4). Metric = AVERAGE SALE (buyer decision).
//
// Access model (M0 spike, revised 2026-08-22): app + search.cardladder.com are
// both behind Cloudflare Turnstile — headless automation gets walled. v1 bridges
// via a HUMAN-OBTAINED session (user logs in themselves, we ride the cookies)
// while official API access is pursued in parallel. Auth is Firebase; the search
// host is search.cardladder.com.
//
// This adapter is the seam. The one thing still needed is the search request +
// response contract, captured by spike/cardladder/capture-session.ts once the
// user runs it (human-in-the-loop). parseAverageSale() is where that shape gets
// wired; until the fixture exists it returns null → lookup() degrades to
// not_found rather than guessing. Error mapping (challenge → reconnect prompt)
// is implemented and tested now.

import type { CardIdentity, Lookup, PriceSource } from "./types.js";
import { notFound, networkError } from "./types.js";
import { type JsonTransport, TransportError } from "./transport.js";

/** Parse the average-sale price (cents) out of a Card Ladder search response.
 *  SEAM: fill in against worker/test/fixtures/cardladder-search.json once the
 *  human-session capture records the real shape. Returns null when the average
 *  field is absent/unknown. */
export function parseAverageSale(_response: unknown): number | null {
  // TODO(contract): map the captured search response → average-sale cents.
  // Kept null-returning (not guessed) so we never surface a wrong price.
  return null;
}

export class CardLadderSource implements PriceSource {
  readonly name = "cardladder" as const;
  readonly metric = "average_sale" as const;

  /** transport must be a SESSION-AUTHENTICATED browser transport (rides the
   *  human-obtained Card Ladder cookies). */
  constructor(private readonly transport: JsonTransport) {}

  async lookup(identity: CardIdentity): Promise<Lookup> {
    let raw: unknown;
    try {
      const q = encodeURIComponent(
        [identity.name, identity.set, identity.grade].filter(Boolean).join(" "),
      );
      raw = await this.transport.getJson(`https://search.cardladder.com/search?q=${q}`);
    } catch (e) {
      if (e instanceof TransportError && (e.status === 403 || e.status === 401)) {
        // Cloudflare challenge or expired session → user must reconnect.
        return { kind: "error", error: "auth_expired", detail: "Card Ladder session invalid — reconnect your account" };
      }
      if (e instanceof TransportError && e.status === 429) {
        return { kind: "error", error: "rate_limited", detail: "Card Ladder rate limited" };
      }
      return networkError(e instanceof Error ? e.message : "unknown");
    }

    const cents = parseAverageSale(raw);
    if (cents === null) {
      return notFound("no Card Ladder average-sale match (or contract not yet wired)");
    }
    return { kind: "ok", priceCents: cents, metric: this.metric, asOf: new Date().toISOString(), confidence: "probable" };
  }
}
