// Courtyard's SCANNER API — the number their own app shows when it scans a slab.
//
// GET https://api.courtyard.io/scanner/card-details?cert={cert}&grader={PSA|CGC}
// No auth. No account. No browser. Verified 2026-08-31; see spike/README.md §2b.
//
// Why this exists, when courtyard-algolia.ts already prices Courtyard: Algolia
// indexes the MARKETPLACE — the slabs Courtyard has vaulted — and cards age out
// of it (a redeemed slab is `burn`ed and simply vanishes). This endpoint is a
// catalog-backed pricing MODEL keyed by CERT, so it answers for cards Courtyard
// has never held, and it cannot return a different card: the cert is the key, so
// the entire `identify()` guessing problem does not apply to this source.
//
// It was found by tearing down the Android app (io.courtyard.app 1.7.00). The app
// is Expo/React Native but ships HERMES BYTECODE, so `grep` finds nothing in
// index.android.bundle and `strings` finds everything — that is where the URL is.
// The endpoint appears NOWHERE in the 172-endpoint web client.
//
// Cross-runtime by the same contract as cardladder.ts: imports NOTHING, uses only
// web-standard globals, and takes an injectable fetch so worker/ vitest exercises
// in Node the exact code the Deno Edge Function ships.

const SCANNER_BASE = "https://api.courtyard.io/scanner";

export type CyGrader = "psa" | "cgc";

export type FetchLike = typeof fetch;
interface Deps {
  fetch?: FetchLike;
}
const f = (d?: Deps): FetchLike => d?.fetch ?? fetch;

// ── Typed failures, mapped by callers onto the pipeline's SourceError kinds. ───
export type CyErrorKind =
  | "not_found" // 404: Courtyard's catalog has no such cert. AUTHORITATIVE.
  | "source_error" // 5xx, incl. 502 "invalid response from gemrate". TRANSIENT.
  | "network"; // transport/parse failure

export class CyError extends Error {
  constructor(readonly kind: CyErrorKind, message?: string) {
    super(message ?? kind);
    this.name = "CyError";
  }
}

/** The key Courtyard identifies this priced thing by — and it hands it to us:
 *  `graderData.id` is literally "PSA_96679812". Derivable from grader+cert
 *  BEFORE any request, which is what lets a cache be checked first with no
 *  network at all (the same property clSourceKey buys for Card Ladder).
 *
 *  Per-SLAB rather than per-card+grade, unlike Card Ladder's
 *  {profileId}:{gradeCode}, because the response carries no card-level id. Two
 *  slabs of the same card each get a row: more rows than strictly needed, never
 *  a wrong answer — and this source costs no budget, so that trade is free. */
export const cySourceKey = (grader: CyGrader, cert: string): string =>
  `${grader.toUpperCase()}_${cert}`;

/** PURE: any source's grade text → the bare number the app stores. "g10" → "10",
 *  "10 GEM MINT" → "10", "g10pristine" → "10" (CGC's codes are NOT plain numeric,
 *  which is why this cannot reuse Card Ladder's stricter displayGrade).
 *  Mirrors GradeText.normalized in Swift — one spelling, or card_key splits. */
export function gradeLabel(grade: unknown): string | undefined {
  if (typeof grade !== "string") return undefined;
  const m = grade.match(/(\d+(?:\.\d+)?)/);
  return m ? m[1] : undefined;
}

/** PURE: Courtyard's own 1-5 confidence in its number.
 *
 *  **0 IS NOT A CONFIDENCE — it is "not applicable".** A card with no model
 *  price returns `price: 0, priceConfidence: "0"` and Courtyard's own app renders
 *  it as "not applicable" (verified on device, cert 154334127). Returning
 *  undefined here is what keeps that out of the UI as a real number. */
export function cyConfidence(raw: unknown): number | undefined {
  const n = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isFinite(n) || n < 1 || n > 5) return undefined;
  return Math.round(n);
}

/** PURE: dollars → integer cents. `50.8` → `5080`. */
export const usdToCents = (usd: unknown): number | null =>
  typeof usd === "number" && Number.isFinite(usd) ? Math.round(usd * 100) : null;

export interface CyIdentity {
  /** Courtyard's own id for this slab — "PSA_96679812". */
  id: string;
  grader?: string;
  cert?: string;
  /** Assembled title: "2022 Panini Donruss Optic Splash! #10 Stephen Curry - (PSA g10)".
   *  NEVER goes in Card.name — it feeds refreshCardKey(); it belongs in Card.title. */
  title?: string;
  /** The short name: "Stephen Curry". */
  subject?: string;
  cardNumber?: string;
  set?: string;
  year?: number;
  category?: string;
  /** Bare number — "9", "10", "9.5". Cert-exact, and free of a paid account:
   *  before this source, Card Ladder was the ONLY grade supplier and PSA's cert
   *  page has been 403-walled since 2026-08-28. */
  grade?: string;
  /** The graded population at this card+grade, per Courtyard's upstream (GemRate). */
  population?: number;
  imageUrls: string[];
}

/** One comp group. Keyed by GRADER + GRADE, never by `title`: every group repeats
 *  the SCANNED card's title, so cert 96679812 returns two grade-10 groups both
 *  labelled "(PSA g10)" — one PSA (pop 23), one SGC (pop 3). Trusting the title
 *  would report other graders' sales as PSA. Groups may also be for a DIFFERENT
 *  grade than the scanned slab (cert 154334127 is a g9 whose only comps are g10),
 *  which the app handles by labelling the grade — so must we. */
export interface CySaleGroup {
  grader?: string;
  grade?: string;
  population?: number;
  sales: { priceCents: number; soldAt: string }[];
}

export interface CyScanResult {
  sourceKey: string;
  /** null when Courtyard has no model price — `price: 0` / confidence 0. Renders
   *  as the em dash, NEVER as $0. */
  priceCents: number | null;
  confidence?: number;
  identity: CyIdentity;
  comps: CySaleGroup[];
  /** false = "Courtyard isn't buying this card" (their app's own words). */
  acquisitionAccepted?: boolean;
}

/** PURE: the raw response → our shape. Exported for fixture tests. */
export function parseCardDetails(raw: any, grader: CyGrader, cert: string): CyScanResult {
  const pm = raw?.priceModel ?? {};
  const gd = raw?.graderData ?? {};

  const confidence = cyConfidence(pm.priceConfidence);
  const cents = usdToCents(pm.price);
  // Both halves must agree before we call it a price. Courtyard states "no model
  // price" as 0/0, and a 0 that reached the UI would be a fabricated $0 — the
  // one thing the price rules forbid outright.
  const priceCents = confidence === undefined || cents === null || cents <= 0 ? null : cents;

  const year = Number(gd.year);

  return {
    sourceKey: cySourceKey(grader, cert),
    priceCents,
    confidence,
    identity: {
      id: typeof gd.id === "string" && gd.id ? gd.id : cySourceKey(grader, cert),
      grader: gd.grader ?? undefined,
      cert: gd.cert ?? undefined,
      title: gd.title ?? undefined,
      subject: gd.subject ?? undefined,
      cardNumber: gd.cardNumber ?? undefined,
      set: gd.set ?? undefined,
      year: Number.isFinite(year) && year > 0 ? year : undefined,
      category: gd.category ?? undefined,
      grade: gradeLabel(gd.grade),
      population: typeof gd.population === "number" ? gd.population : undefined,
      imageUrls: Array.isArray(gd.primaryImages) ? gd.primaryImages.filter((u: unknown) => typeof u === "string") : [],
    },
    comps: (Array.isArray(raw?.priceHistory) ? raw.priceHistory : []).map((g: any) => ({
      grader: g?.grader ?? undefined,
      grade: gradeLabel(g?.grade),
      population: typeof g?.population === "number" ? g.population : undefined,
      sales: (Array.isArray(g?.sales) ? g.sales : [])
        .map((s: any) => {
          // Prices arrive as decimal STRINGS ("145.00"); dates as UTC midnight
          // ("2026-05-17T00:00:00Z"), which the app must render in LOCAL time or
          // it disagrees with Courtyard's own app by a day.
          const cents = usdToCents(Number(s?.price));
          return cents != null && cents > 0 && typeof s?.date === "string"
            ? { priceCents: cents, soldAt: s.date }
            : null;
        })
        .filter((s: unknown): s is { priceCents: number; soldAt: string } => s !== null)
        .sort((a: { soldAt: string }, b: { soldAt: string }) => b.soldAt.localeCompare(a.soldAt)),
    })),
    acquisitionAccepted:
      typeof raw?.acquisition?.accepted === "boolean" ? raw.acquisition.accepted : undefined,
  };
}

/** Fetch one slab's scanner record. `grader` is optional to Courtyard (the cert
 *  alone resolves) but we always send it — it is free precision. */
export async function fetchCardDetails(
  cert: string,
  grader: CyGrader,
  deps?: Deps,
): Promise<CyScanResult> {
  const url = `${SCANNER_BASE}/card-details?cert=${encodeURIComponent(cert)}&grader=${grader.toUpperCase()}`;
  let res: Response;
  try {
    res = await f(deps)(url, { headers: { Accept: "application/json" } });
  } catch (e) {
    throw new CyError("network", String(e));
  }

  // 404 {"message":"card details not found"} is AUTHORITATIVE — Courtyard has no
  // such card, so the UI shows an em dash. 502 {"message":"invalid response from
  // gemrate"} is their upstream failing and must NOT blank a price the user has
  // already seen (PriceWriteback holds that rule).
  if (res.status === 404) throw new CyError("not_found");
  if (!res.ok) throw new CyError("source_error", `HTTP ${res.status}`);

  let raw: unknown;
  try {
    raw = await res.json();
  } catch (e) {
    throw new CyError("network", String(e));
  }
  return parseCardDetails(raw, grader, cert);
}
