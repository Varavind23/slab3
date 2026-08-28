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
const INDEX = "marketplace_prod_recently_listed";

interface AlgoliaHit {
  objectID: string;
  title?: string;
  estimatedValueUsd?: number;
  estimatedValueConfidence?: number;
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
interface AlgoliaResult {
  hits: AlgoliaHit[];
  nbHits: number;
}

/** Injectable search surface so tests use a fixture instead of the network. */
export interface AlgoliaSearch {
  query(text: string, facetFilters: string[][]): Promise<AlgoliaResult>;
}

/** Production Algolia client — plain fetch, no browser. */
export class HttpAlgoliaSearch implements AlgoliaSearch {
  async query(text: string, facetFilters: string[][]): Promise<AlgoliaResult> {
    const res = await fetch(
      `https://${ALGOLIA_APP.toLowerCase()}-dsn.algolia.net/1/indexes/${INDEX}/query`,
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

    // Prefer an exact cert-number match; else the top hit whose grade agrees.
    const byCert = identity.certNumber
      ? result.hits.find((h) => h.certification?.number === identity.certNumber)
      : undefined;
    const byGrade = gnum
      ? result.hits.find((h) => gradeNumber(h.certification?.grade ?? h.metadata?.Grade) === gnum)
      : undefined;
    const hit = byCert ?? byGrade ?? result.hits[0];

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
      confidence: byCert ? "exact" : byGrade ? "probable" : "fuzzy",
    };
  }
}
