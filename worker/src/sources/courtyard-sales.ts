// Courtyard recent SALES — real completed transactions, not an estimate.
//
// Discovered 2026-08-29. Two pieces, both browserless:
//
//   1. Algolia index `marketplace_prod_recently_sold` (sibling of the
//      `recently_listed` index the price adapter uses, same public search key)
//      gives candidate slabs of the same card + grade. It carries lastSaleDate
//      but NOT the sale amount.
//   2. `GET api.courtyard.io/index/asset/{assetID}/transactions` gives that
//      slab's own ledger, including `paymentAmount` in USDC 6-decimals. Verified
//      209810000 -> $209.81.
//
// Two findings that shape this file:
//
//   * `proofOfIntegrity` on an Algolia hit IS the assetID — which is the
//     card_key -> assetID resolution courtyard.ts:resolveAssetId has been stubbed
//     out waiting for (D10). No separate resolution step needed.
//   * Unlike /index/asset/{id} (Cloudflare-fingerprinted, needs the browser
//     transport), the /transactions subpath answers a plain request. So this runs
//     with no BrowserPool.
//
// COVERAGE IS THIN AND THAT IS EXPECTED: sampling ten recently_sold hits, only
// two had a sale transaction at all — the rest carry a lone `mint`. Returning
// fewer than five comps, or none, is a normal result and never an error. We do
// not pad the list with estimates; a fabricated comp is the same sin as a
// fabricated price.

import type { CardIdentity, RecentSale } from "./types.js";
import type { JsonTransport } from "./transport.js";
import { type AlgoliaSearch, HttpAlgoliaSearch, gradeNumber } from "./courtyard-algolia.js";

/** Polygon USDC, 6 decimals — the only payment token a real sale settles in. */
const USDC_POLYGON = "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359";

/** How many candidate slabs to open ledgers for. Sized against the ~20% of
 *  vaulted slabs that actually carry a sale, to land five without hammering. */
export const CANDIDATE_LIMIT = 12;
/** How many comps the detail screen shows. */
export const SALES_WANTED = 5;

interface CourtyardTx {
  txTime: string;
  txType: string;
  paymentToken?: string;
  paymentAmount?: string;
}

/** USDC 6-decimal string → integer cents. Null for anything not a real amount. */
export function usdcToCents(raw: unknown): number | null {
  if (typeof raw !== "string" || !/^\d+$/.test(raw)) return null;
  const cents = Math.round(Number(raw) / 10_000); // 1e6 units per USD → cents
  return Number.isFinite(cents) && cents > 0 ? cents : null;
}

/** PURE: the most recent real SALE in one slab's ledger, or null.
 *  `mint` is excluded deliberately — a vending-machine pack purchase (its
 *  paymentToken is literally "stripe") is not a comp for the card. */
export function latestSale(transactions: CourtyardTx[] | undefined): { priceCents: number; soldAt: string } | null {
  const sales = (transactions ?? [])
    .filter((t) => t.txType === "sale" && (t.paymentToken ?? "").toLowerCase() === USDC_POLYGON)
    .map((t) => ({ priceCents: usdcToCents(t.paymentAmount), soldAt: t.txTime }))
    .filter((s): s is { priceCents: number; soldAt: string } => s.priceCents !== null && !!s.soldAt);
  if (!sales.length) return null;
  sales.sort((a, b) => b.soldAt.localeCompare(a.soldAt));
  return sales[0];
}

export class CourtyardSalesSource {
  constructor(
    private readonly transport: JsonTransport,
    private readonly algolia: AlgoliaSearch = new HttpAlgoliaSearch("marketplace_prod_recently_sold"),
  ) {}

  /** Recent real sales of this card at this grade, newest first. An empty array
   *  means Courtyard has no comps — a legitimate answer, not a failure. */
  async recentSales(identity: CardIdentity): Promise<RecentSale[]> {
    const text = [identity.name, identity.set].filter(Boolean).join(" ").trim();
    if (!text) return [];
    const gnum = gradeNumber(identity.grade);

    let hits;
    try {
      const result = await this.algolia.query(text, [[`metadata.Grader:${identity.grader.toUpperCase()}`]]);
      hits = result.hits ?? [];
    } catch {
      return [];
    }

    // Grade is compared client-side: Algolia stores it as free text ("10 GEM
    // MINT") and, as of 2026-08-29, cert/serial are not facetable at all.
    const candidates = hits
      .filter((h) => !gnum || gradeNumber(h.certification?.grade ?? h.metadata?.Grade) === gnum)
      .slice(0, CANDIDATE_LIMIT);

    const ledgers = await Promise.all(
      candidates.map(async (h): Promise<RecentSale | null> => {
        const assetId = (h as { proofOfIntegrity?: string }).proofOfIntegrity ?? h.objectID;
        try {
          const raw = (await this.transport.getJson(
            `https://api.courtyard.io/index/asset/${assetId}/transactions`,
          )) as { transactions?: CourtyardTx[] };
          const sale = latestSale(raw?.transactions);
          if (!sale) return null;
          return {
            priceCents: sale.priceCents,
            soldAt: sale.soldAt,
            platform: "Courtyard",
            title: h.title,
          };
        } catch {
          // One unreachable ledger must not lose the comps we did find.
          return null;
        }
      }),
    );

    return ledgers
      .filter((s): s is RecentSale => s !== null)
      .sort((a, b) => b.soldAt.localeCompare(a.soldAt))
      .slice(0, SALES_WANTED);
  }
}
