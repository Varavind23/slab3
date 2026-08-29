// Courtyard search via Algolia (plan: T5) — the browserless path.
//
// M0 finding (2026-08-22): Courtyard's marketplace search is Algolia, hosted on
// algolia.net (NOT behind Cloudflare), with a public search-only key embedded in
// their web client. So we query it directly — no Playwright, no bot wall. Each
// record carries card metadata (Grader, Grade, Set, Year, Subject), the cert
// (certification.number), Courtyard's estimatedValueUsd (confidence-scored),
// the current listing (latestListing.price.amount.usd), and lastSaleDate.
//
// Matching: query text = "{name} {set}", facet-filtered by Grader + Grade, so
// the top hit is the right card type. Exact when the scanned cert matches a
// hit's certification.number; probable otherwise.

import type { CardIdentity, Lookup, PriceSource } from "./types.js";
import { notFound, networkError } from "./types.js";
import { usdToCents } from "./courtyard.js";

const ALGOLIA_APP = "Y8TL3M06QA";
const ALGOLIA_KEY = "3b3ed18284ca0baee9a496aea5f093d6"; // public search-only key
export const INDEX_LISTED = "marketplace_prod_recently_listed";
/** Sibling index of the same Algolia app, found 2026-08-29 — the comps feed. */
export const INDEX_SOLD = "marketplace_prod_recently_sold";

export interface AlgoliaHit {
  objectID: string;
  /** Courtyard's assetID under another name — confirmed 2026-08-29. It is what
   *  /index/asset/{id}/transactions is keyed by, so an Algolia hit resolves
   *  straight to a slab's ledger with no extra lookup (the D10 gap). */
  proofOfIntegrity?: string;
  title?: string;
  estimatedValueUsd?: number;
  estimatedValueConfidence?: number | string;
  lastSaleDate?: string;
  latestListing?: { price?: { amount?: { usd?: number } } };
  certification?: { agency?: string; number?: string; grade?: string };
  metadata?: Record<string, string>;
  // Courtyard's own render of the graded card, cert-keyed
  // (.../graded-cards-renders/PSA%2098881872/nft_image.jpg), plus a ~90-byte
  // inline preview. This adapter implements PriceSource, which is a PRICE
  // contract, so it doesn't surface them — the iOS mirror
  // (ios/Slab3/Pricing/CourtyardClient.swift) consumes them for the card's
  // picture. Declared here so the two stay honest about the record shape.
  imageUrl?: string;
  lqipBase64?: string;
}
export interface AlgoliaResult {
  hits: AlgoliaHit[];
  nbHits: number;
}

/** Injectable search surface so tests use a fixture instead of the network. */
export interface AlgoliaSearch {
  query(text: string, facetFilters: string[][]): Promise<AlgoliaResult>;
}

/** Production Algolia client — plain fetch, no browser. */
export class HttpAlgoliaSearch implements AlgoliaSearch {
  constructor(private readonly index: string = INDEX_LISTED) {}

  async query(text: string, facetFilters: string[][]): Promise<AlgoliaResult> {
    const res = await fetch(
      `https://${ALGOLIA_APP.toLowerCase()}-dsn.algolia.net/1/indexes/${this.index}/query`,
      {
        method: "POST",
        headers: {
          "X-Algolia-Application-Id": ALGOLIA_APP,
          "X-Algolia-API-Key": ALGOLIA_KEY,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ query: text, hitsPerPage: 10, facetFilters }),
      },
    );
    if (!res.ok) throw new Error(`algolia ${res.status}`);
    return (await res.json()) as AlgoliaResult;
  }
}

/** Normalize a grade like "10 GEM MINT" / "PSA 9" → the leading number "10"/"9"
 *  for facet filtering and comparison. */
export function gradeNumber(grade: string | undefined): string | undefined {
  const m = grade?.match(/(\d+(?:\.\d+)?)/);
  return m ? m[1] : undefined;
}

/** Courtyard sends estimatedValueConfidence as a STRING ("4") on live records and
 *  a number on others. Normalize to 1-5, or undefined when it says nothing. */
export function sourceConfidence(raw: unknown): number | undefined {
  const n = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isFinite(n) || n < 1 || n > 5) return undefined;
  return Math.round(n);
}

/** Which hit, if any, IS this card — mirrored in CourtyardClient.swift:identify.
 *
 *  Two tiers, both of which must identify the same card:
 *    - cert matches            -> this exact slab;
 *    - year + card number + grade all agree -> a different slab of the same card.
 *
 *  There used to be a third tier that took the top priced hit when nothing
 *  agreed, and a grade-only tier above it. Both are gone (2026-08-29): on a query
 *  like "Stephen Curry Splash" they are a lottery across every Splash card
 *  Courtyard ever vaulted, and we showed an unrelated Curry's $18 against cert
 *  96679812 while Courtyard's own app said $50.80. A price belonging to another
 *  card is a fabricated price for this one.
 *
 *  Note what this CANNOT do: cert is neither searchable nor facetable in these
 *  indices (verified 2026-08-29 — `restrictSearchableAttributes` on
 *  certification.number returns 0, and a bare cert query returns typo-tolerant
 *  near-misses belonging to unrelated cards). So an exact tier is reachable only
 *  by luck, and the same-card tier only for cards currently in the recent-activity
 *  feeds. Declining is the correct outcome for everything else. */
export function identify(
  hits: AlgoliaHit[],
  identity: Pick<CardIdentity, "certNumber" | "grade" | "year" | "cardNumber">,
): { hit: AlgoliaHit; byCert: boolean } | null {
  if (identity.certNumber) {
    const byCert = hits.find((h) => h.certification?.number === identity.certNumber);
    if (byCert) return { hit: byCert, byCert: true };
  }
  const gnum = gradeNumber(identity.grade);
  if (!gnum || identity.year == null || !identity.cardNumber) return null;
  const sameCard = hits.find((h) => {
    if (gradeNumber(h.certification?.grade ?? h.metadata?.Grade) !== gnum) return false;
    const year = Number(h.metadata?.Year);
    if (!Number.isFinite(year) || year !== identity.year) return false;
    const num = h.metadata?.["Card Number"];
    return !!num && num.toLowerCase() === identity.cardNumber!.toLowerCase();
  });
  return sameCard ? { hit: sameCard, byCert: false } : null;
}

export class CourtyardAlgoliaSource implements PriceSource {
  readonly name = "courtyard" as const;
  // What Slabs shows for Courtyard: the confidence-scored value estimate, which
  // is Courtyard's own number derived from recent sales. (True single last-sale
  // price is available per-asset via the transactions feed if we ever want it.)
  readonly metric = "recent_sale" as const;

  constructor(private readonly algolia: AlgoliaSearch = new HttpAlgoliaSearch()) {}

  async lookup(identity: CardIdentity): Promise<Lookup> {
    const text = [identity.name, identity.set].filter(Boolean).join(" ").trim();
    const gnum = gradeNumber(identity.grade);
    const grader = identity.grader.toUpperCase();

    // Facet-filter to the same grader; grade is matched below (Algolia stores it
    // as "10 GEM MINT", so we compare the leading number rather than facet-exact).
    const facetFilters: string[][] = [[`metadata.Grader:${grader}`]];

    let result: AlgoliaResult;
    try {
      result = await this.algolia.query(text || (identity.certNumber ?? ""), facetFilters);
    } catch (e) {
      return networkError(e instanceof Error ? e.message : "algolia error");
    }
    if (!result.hits?.length) return notFound(`no Courtyard match for "${text}"`);

    // Identify the card, or decline. Two tiers only — see `identify`.
    const found = identify(result.hits, identity);
    if (!found) return notFound("no Courtyard hit identifies this card");
    const { hit, byCert } = found;

    const cents = usdToCents(hit.estimatedValueUsd);
    if (cents === null) {
      // Value estimate absent — fall back to the current listing ask.
      const ask = usdToCents(hit.latestListing?.price?.amount?.usd);
      if (ask === null) return notFound("Courtyard match has no price");
      return {
        kind: "ok",
        priceCents: ask,
        metric: this.metric,
        asOf: hit.lastSaleDate ?? new Date().toISOString(),
        sourceCanonicalId: hit.objectID,
        confidence: byCert ? "exact" : "probable",
      };
    }
    return {
      kind: "ok",
      priceCents: cents,
      metric: this.metric,
      asOf: hit.lastSaleDate ?? new Date().toISOString(),
      sourceCanonicalId: hit.objectID,
      confidence: byCert ? "exact" : "probable",
      // Courtyard's OWN 1-5 confidence in its estimate — the number its app shows
      // beside the value. Carried only on an exact cert match: on a fuzzy hit the
      // value belongs to a DIFFERENT card, so quoting Courtyard's confidence in it
      // would overstate what we know. Same rule the official image already follows.
      sourceConfidence: byCert ? sourceConfidence(hit.estimatedValueConfidence) : undefined,
    };
  }
}
