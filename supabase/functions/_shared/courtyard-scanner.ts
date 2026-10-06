// Courtyard's SCANNER API — the number their own app shows when it scans a slab.
//
// GET https://api.courtyard.io/scanner/card-details?cert={cert}&grader={PSA|CGC}
// No auth. No account. No browser. Verified 2026-08-31; see spike/README.md §2b.
// It IS User-Agent-walled as of 2026-09-03 — see SCANNER_UA below. That is the one
// header this request cannot go out without.
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

/** The User-Agent every request MUST carry. `/scanner/*` is now behind a WAF that
 *  blocks requests by User-Agent, added some time after this endpoint was found
 *  (spike/README.md §2b records plain curl working throughout 2026-08-31; it 403s
 *  now). Measured 2026-09-03, same machine, same minute:
 *
 *    403  curl/8.7.1 · python-requests · Go-http-client · node · EMPTY/absent
 *    200  browsers · Deno/1.45.5 · supabase-edge-runtime · undici · okhttp · this
 *
 *  It is a blocklist of obvious tool agents, and the 403 comes from in front of
 *  their stack — bare HTML, every header stripped, no `server: Google Frontend`.
 *
 *  Why this is set EXPLICITLY rather than left to the runtime: this module runs
 *  under three runtimes on purpose (Deno on the Edge Function, Node under vitest,
 *  and whatever a future caller brings), each with a different default, and an
 *  ABSENT User-Agent is a 403. Inheriting the default made reachability depend on
 *  where the code happened to be running — which is exactly the shape of an
 *  intermittent, unexplained blank price, since a 403 lands on the same
 *  `source_error` path as a genuine GemRate outage.
 *
 *  Deliberately truthful rather than a copied browser or Courtyard-app string: a
 *  custom agent passes the wall (verified above), so there is nothing to gain by
 *  claiming to be someone else. Not tied to MARKETING_VERSION — it identifies the
 *  client, not the release, and must not need a bump to keep working. */
export const SCANNER_UA = "Slabs/1.0 (graded-card inventory)";

/** The second header this endpoint cannot go out without, and the one that decides
 *  whether a cert RESOLVES AT ALL.
 *
 *  Without it, `card-details` answers `404 {"card details not found"}` for a large
 *  class of certs — indistinguishable from a cert their catalog genuinely does not
 *  know, which is exactly how it read to us for weeks: "Courtyard shows an em dash
 *  while Card Ladder prices the same slab fine". With it, the identical request
 *  returns a full priced record.
 *
 *  Measured live 2026-09-06, same minute, varying ONLY this header:
 *
 *    cert 60928769 PSA   404  ->  200 $144.40 conf 5   (1999 Pokemon Game Movie Mewtwo)
 *    cert 66581638 PSA   404  ->  200 $155.40 conf 5
 *    cert 129123650 PSA  404  ->  200 $38.40  conf 5   (spike/README.md §2e, open since 09-05)
 *    cert 133653550 PSA  404  ->  200 $125.40 conf 5   (§2b's "authoritative 404" cert!)
 *    cert 96679812 PSA   200  ->  200 $50.80  conf 2   (unchanged — strict superset)
 *
 *  It is a STRICT SUPERSET: no cert that already answered changed price, confidence
 *  or response shape (the `acquisition` block is present either way), so this does
 *  not select a different document — it gates which certs the backend will resolve.
 *
 *  Found by disassembling Courtyard's Android app (io.courtyard.app 1.7.10, Hermes
 *  bytecode — `hermes-dec`, because the header is assembled in CODE and the string
 *  table alone does not show the conditional). Their `getCustomHeaders` adds it to
 *  every request whose URL contains `/scanner/`, so we do the same. Sending it is
 *  truthful: we already read and surface `acquisition.accepted`.
 *
 *  NOT the gate, though the app sends it too: `cy-client-id` (a Statsig anonymous
 *  id). Sending that alone still 404s. Neither is auth — a fresh Privy bearer makes
 *  no difference — nor the User-Agent, nor the grader, nor the URL. See
 *  spike/README.md §2f for the full elimination table. */
export const SCANNER_ACQ_HEADER = "cy-supports-acquisition-status";

export type CyGrader = "psa" | "cgc";

export type FetchLike = typeof fetch;
interface Deps {
  fetch?: FetchLike;
}
/** Every outbound call gives up after this long (review 2026-10-02): a hung
 *  upstream used to hold the Edge Function — up to 8 sequential calls on the
 *  unresolvable path — until the platform killed it. An abort is "network". */
export const FETCH_TIMEOUT_MS = 10_000;
const timedFetch: FetchLike = (input, init) =>
  fetch(input, { ...init, signal: init?.signal ?? AbortSignal.timeout(FETCH_TIMEOUT_MS) });
const f = (d?: Deps): FetchLike => d?.fetch ?? timedFetch;

// ── Typed failures, mapped by callers onto the pipeline's SourceError kinds. ───
export type CyErrorKind =
  | "not_found" // 404: Courtyard's catalog has no such cert. AUTHORITATIVE.
  | "unresolvable" // 400: no (cert, grader) pairing we can form is valid. AUTHORITATIVE.
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

// ── /scanner/card-grader-image — the slab photograph ──────────────────────────
//
// The SECOND scanner route, and the only source of a real slab photo we have.
// Found while chasing the two certs in spike/README.md §2e. Why it earns its place:
//
//   * COVERAGE. Measured 2026-09-05 over nine certs — PSA and CGC, priced and
//     unpriced, including one `card-details` has never heard of — it returned front
//     AND back on 9/9. The image source it replaces (Algolia, the MARKETPLACE index)
//     had an exact-cert hit on 1 of 4, missing even cert 96679812, the card that
//     prices perfectly. The image gap was always far wider than the price gap.
//   * IT VERIFIES THE CERT, so it clears the standing "official image only on an
//     exact cert match" rule by construction: an unknown cert returns 200 with an
//     EMPTY primaryImages, and cert+1 returns a different card's images. The one
//     handling rule that matters: **200 does not mean there is an image — check the
//     array.** Never treat the empty case as an error.
//   * THE URLS ARE FREE TO SERVE. No query string, no signature, no expiry, and they
//     fetch anonymously with no User-Agent (CloudFront, not api.courtyard.io). So we
//     store the URL only; the phone pulls the bytes itself. That keeps this to ONE
//     api.courtyard.io call per cert ever, which matters on an endpoint that 403s an
//     IP that hammers it.
//
// Sizes: the response carries `Thumbnail` (~21KB) and `None` (~74KB, the one to
// show). A `/large/` path substitution also resolves (~530KB) but is NOT in the
// response, so we do not synthesise it — `/original/` 404s, which is the reminder
// that guessing at their CDN layout is not ours to do.
export interface CyGraderImages {
  /** imageSize "None" — the ~74KB render. The one to display. */
  frontUrl?: string;
  frontThumbUrl?: string;
  backUrl?: string;
  backThumbUrl?: string;
}

/** PURE: the card-grader-image response → our shape. Exported for fixture tests. */
export function parseGraderImages(raw: any): CyGraderImages {
  const imgs: any[] = Array.isArray(raw?.primaryImages) ? raw.primaryImages : [];
  const pick = (side: string, thumb: boolean): string | undefined => {
    const hit = imgs.find(
      (i) =>
        typeof i?.imageUrl === "string" &&
        String(i?.imageSide ?? "").toLowerCase() === side &&
        (String(i?.imageSize ?? "") === "Thumbnail") === thumb,
    );
    return hit?.imageUrl;
  };
  return {
    frontUrl: pick("front", false),
    frontThumbUrl: pick("front", true),
    backUrl: pick("back", false),
    backThumbUrl: pick("back", true),
  };
}

/** Fetch the slab photograph URLs. NEVER THROWS.
 *
 *  A missing picture must never cost a price. This runs alongside a price lookup,
 *  and every failure mode here — the cert has no images, their CDN is unhappy, the
 *  network blinked — has the same correct answer: no image, carry on. Returning `{}`
 *  rather than throwing is what stops an image problem from reaching the
 *  `source_error` path and blanking a number. */
export async function fetchGraderImages(
  cert: string,
  grader: CyGrader,
  deps?: Deps,
): Promise<CyGraderImages> {
  const url = `${SCANNER_BASE}/card-grader-image?cert=${encodeURIComponent(cert)}&grader=${encodeURIComponent(grader.toUpperCase())}`;
  try {
    const res = await f(deps)(url, {
      // Same two headers as card-details. The acquisition one measurably changes
      // nothing on THIS route (a cert with no photo returns `primaryImages: null`
      // + `status: "NO_IMAGE"` either way, verified 2026-09-06) — it is sent
      // because Courtyard's app sends it on every `/scanner/*` URL and because a
      // route that silently starts gating on it must not become a second
      // months-long hunt.
      headers: {
        Accept: "application/json",
        "User-Agent": SCANNER_UA,
        [SCANNER_ACQ_HEADER]: "1",
      },
    });
    if (!res.ok) return {};
    return parseGraderImages(await res.json());
  } catch {
    return {};
  }
}

/** ONE request. Returns the parsed result, or throws the kind the status maps to.
 *
 *  Status semantics, all verified live 2026-09-05:
 *    200  the answer.
 *    404  {"message":"card details not found"} — AUTHORITATIVE. This cert is not
 *         in the catalog. Cache it; the UI shows an em dash.
 *    400  {"message":"unable to query gemrate for cert: … InvalidArgument …"} —
 *         GemRate REFUSED THE QUERY. Not "no such card": the (cert, grader) pair
 *         we sent is not one it will accept. Deterministic — the identical request
 *         fails identically forever.
 *    5xx  {"message":"invalid response from gemrate"} — their upstream. TRANSIENT.
 */
async function attempt(cert: string, grader: CyGrader, deps?: Deps): Promise<CyScanResult> {
  const url = `${SCANNER_BASE}/card-details?cert=${encodeURIComponent(cert)}&grader=${encodeURIComponent(grader.toUpperCase())}`;
  let res: Response;
  try {
    res = await f(deps)(url, {
      // BOTH headers are load-bearing, not decoration. Absent User-Agent = 403
      // (SCANNER_UA); absent acquisition-status = a 404 on a cert that prices
      // perfectly with it (SCANNER_ACQ_HEADER). Neither is optional.
      headers: {
        Accept: "application/json",
        "User-Agent": SCANNER_UA,
        [SCANNER_ACQ_HEADER]: "1",
      },
    });
  } catch (e) {
    throw new CyError("network", String(e));
  }

  if (res.status === 404) throw new CyError("not_found");
  if (res.status === 400) throw new CyError("unresolvable", `HTTP 400 for ${grader}/${cert}`);
  if (!res.ok) throw new CyError("source_error", `HTTP ${res.status}`);

  let raw: unknown;
  try {
    raw = await res.json();
  } catch (e) {
    throw new CyError("network", String(e));
  }

  // GUARD: the answer must be about the slab we asked for.
  //
  // This matters because `fetchCardDetails` retries under a DIFFERENT grader, and
  // nothing proves the PSA and CGC cert namespaces are disjoint. If some number is
  // a valid cert for both graders, an unguarded fallback would accept a completely
  // different card and price it as this one — the exact failure the `identify()`
  // bar exists to prevent on the Algolia side, reintroduced through the back door.
  //
  // Courtyard echoes `graderData.cert` and `graderData.grader`, so we check them.
  // Only a PRESENT-and-disagreeing value is rejected: a missing echo is not treated
  // as a mismatch, or a response shape change would blank every card at once.
  const gd = (raw as any)?.graderData ?? {};
  const echoedCert = typeof gd.cert === "string" ? gd.cert.replace(/^0+/, "") : undefined;
  const echoedGrader = typeof gd.grader === "string" ? gd.grader.toUpperCase() : undefined;
  if (echoedCert !== undefined && echoedCert !== cert.replace(/^0+/, "")) {
    throw new CyError("unresolvable", `cert echo ${gd.cert} != requested ${cert}`);
  }
  if (echoedGrader !== undefined && echoedGrader !== grader.toUpperCase()) {
    throw new CyError("unresolvable", `grader echo ${gd.grader} != requested ${grader}`);
  }

  // GUARD: a 200 must actually carry the price model. A body without one (an
  // edge page, `{}`, a renamed field) used to parse as "no price" and be cached
  // as an authoritative answer for 24h, for every user — clearing prices on
  // screen (review 2026-10-02). Not an answer: transient, nothing cached.
  const pm = (raw as any)?.priceModel;
  if (!pm || typeof pm !== "object") {
    throw new CyError("source_error", "200 without a priceModel");
  }

  return parseCardDetails(raw, grader, cert);
}

/** PURE: the (cert, grader) pairs to try, in order, for one scanned slab.
 *
 *  WHY THERE IS MORE THAN ONE. The grader is a GUESS. Nothing in a slab barcode
 *  says who graded it — `CertParser` infers it from digit count (10 -> CGC, 7-9 ->
 *  PSA), and when that guess is wrong GemRate answers 400, forever. Courtyard
 *  itself does not care: it resolves a PSA cert with the grader omitted entirely.
 *  So a 400 is a statement about OUR parameters, not about the card, and the
 *  honest response is to try the other reading before reporting no answer.
 *
 *  Verified live 2026-09-05, and this is the whole bug in one table:
 *    cert 96679812   grader=PSA -> 200 $50.80   grader=CGC -> 400
 *    cert 4260611176 grader=CGC -> 200 $111     grader=PSA -> 400
 *    cert 0096679812 grader=PSA -> 400 (leading zeros are not tolerated)
 *  Omitting the grader is NOT a universal fallback — it resolves the PSA cert but
 *  400s the CGC one — which is why this flips the grader rather than dropping it.
 *
 *  Leading zeros get their own attempt because a zero-padded barcode read changes
 *  the digit count, which flips the grader guess AND is rejected on its own. */
export function attemptsFor(cert: string, grader: CyGrader): Array<{ cert: string; grader: CyGrader }> {
  const other: CyGrader = grader === "psa" ? "cgc" : "psa";
  const out = [
    { cert, grader },
    { cert, grader: other },
  ];
  const trimmed = cert.replace(/^0+/, "");
  if (trimmed && trimmed !== cert) {
    out.push({ cert: trimmed, grader }, { cert: trimmed, grader: other });
  }
  return out;
}

/** Fetch one slab's scanner record, recovering from a mis-guessed grader.
 *
 *  Tries the pairings in `attemptsFor` until one answers, and ONLY walks past a
 *  400 — a 404 is authoritative about the cert itself, and a 5xx is their upstream
 *  having a bad minute; neither is improved by asking again with different
 *  parameters, and retrying them would multiply load on an endpoint that 403s an
 *  IP which hammers it.
 *
 *  The result is parsed against the pairing that actually ANSWERED, not the one we
 *  were asked for, so `sourceKey` and `identity.grader` describe the real slab.
 *
 *  If every pairing 400s, that is authoritative — the caller caches it, exactly
 *  like a 404. Before this existed, a 400 was classified `source_error`, which the
 *  Edge Function treats as transient: never cached, so every refresh re-sent the
 *  same doomed request and the card showed an em dash forever with nothing
 *  anywhere saying why. Card Ladder resolves the same slab independently, which is
 *  why the failure looked like "some cards just don't have Courtyard values". */
export async function fetchCardDetails(
  cert: string,
  grader: CyGrader,
  deps?: Deps,
): Promise<CyScanResult> {
  const tries = attemptsFor(cert, grader);
  let last: CyError | undefined;

  for (const t of tries) {
    try {
      return await attempt(t.cert, t.grader, deps);
    } catch (e) {
      const err = e instanceof CyError ? e : new CyError("network", String(e));
      if (err.kind !== "unresolvable") throw err; // 404 / 5xx / network: stop here.
      last = err;
    }
  }
  throw last ?? new CyError("unresolvable");
}
