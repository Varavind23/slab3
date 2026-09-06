import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import {
  parseCardDetails,
  fetchCardDetails,
  SCANNER_UA,
  SCANNER_ACQ_HEADER,
  attemptsFor,
  fetchGraderImages,
  parseGraderImages,
  cySourceKey,
  gradeLabel,
  cyConfidence,
  salesForGrade,
  populationForGrade,
  CyError,
} from "../src/sources/courtyard-scanner.js";

// Fixtures captured LIVE from api.courtyard.io/scanner/card-details (2026-08-31).
const load = (n: string) => JSON.parse(readFileSync(new URL(`./fixtures/${n}`, import.meta.url), "utf8"));
// cert 96679812: the acceptance bar — Courtyard's own app shows $50.80 / medium
// confidence for this slab, confirmed on device by the owner.
const PSA = load("courtyard-scanner-psa.json");
// cert 154334127: Courtyard KNOWS the card but has no model price — it returns
// price 0 / confidence "0" and their app renders "not applicable". The case most
// likely to regress into a fabricated $0.
const NOPRICE = load("courtyard-scanner-noprice.json");
// cert 4260611176: CGC, whose grade code is "g10pristine" — NOT plain numeric.
const CGC = load("courtyard-scanner-cgc.json");
const NOTFOUND = load("courtyard-scanner-notfound.json");

const stub = (body: unknown, status = 200): typeof fetch =>
  (async () =>
    new Response(typeof body === "string" ? body : JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    })) as unknown as typeof fetch;

describe("cySourceKey", () => {
  it("is Courtyard's own graderData.id, derivable before any request", () => {
    expect(cySourceKey("psa", "96679812")).toBe("PSA_96679812");
    expect(cySourceKey("psa", "96679812")).toBe(PSA.graderData.id);
    expect(cySourceKey("cgc", "4260611176")).toBe(CGC.graderData.id);
  });
});

describe("gradeLabel", () => {
  it("normalizes every source's spelling to a bare number", () => {
    expect(gradeLabel("g10")).toBe("10");
    expect(gradeLabel("10 GEM MINT")).toBe("10");
    expect(gradeLabel("PSA 9")).toBe("9");
    expect(gradeLabel("9.5")).toBe("9.5");
  });
  it("handles CGC's non-numeric codes, which Card Ladder's displayGrade rejects", () => {
    expect(gradeLabel("g10pristine")).toBe("10");
    expect(gradeLabel(CGC.graderData.grade)).toBe("10");
  });
  it("says nothing rather than guessing when there is no number", () => {
    expect(gradeLabel("AUTH")).toBeUndefined();
    expect(gradeLabel(undefined)).toBeUndefined();
  });
});

describe("cyConfidence", () => {
  it("keeps 1-5", () => {
    expect(cyConfidence("2")).toBe(2);
    expect(cyConfidence(5)).toBe(5);
  });
  it("rejects 0 — that is 'not applicable', not a confidence", () => {
    expect(cyConfidence("0")).toBeUndefined();
    expect(cyConfidence(0)).toBeUndefined();
  });
});

describe("parseCardDetails — the priced case", () => {
  const r = parseCardDetails(PSA, "psa", "96679812");

  it("reads the number Courtyard's own app displays", () => {
    // THE LIVE BAR. Their app shows $50.80, medium confidence, for this slab.
    expect(r.priceCents).toBe(5080);
    expect(r.confidence).toBe(2);
  });

  it("carries a cert-exact identity, including the grade", () => {
    // The grade matters beyond the badge: it is a card_key segment, and before
    // this source Card Ladder was the ONLY supplier (PSA's cert page is walled).
    expect(r.identity.grade).toBe("10");
    expect(r.identity.subject).toBe("Stephen Curry");
    expect(r.identity.cardNumber).toBe("10");
    expect(r.identity.year).toBe(2022);
    expect(r.identity.id).toBe("PSA_96679812");
  });

  it("reports acquisition, the app's 'Courtyard isn't buying this card' flag", () => {
    expect(r.acquisitionAccepted).toBe(true);
  });
});

describe("parseCardDetails — no model price", () => {
  const r = parseCardDetails(NOPRICE, "psa", "154334127");

  it("maps price 0 / confidence 0 to NO price, never $0", () => {
    // Courtyard's app renders this slab as "not applicable" (confirmed on device).
    // A 0 reaching the UI would be a fabricated price — the one thing forbidden.
    expect(r.priceCents).toBeNull();
    expect(r.confidence).toBeUndefined();
  });

  it("still yields the identity, so the row is not left anonymous", () => {
    expect(r.identity.grade).toBe("9");
    expect(r.identity.title).toContain("Lewis Hamilton");
  });

  it("keeps comps that are for a DIFFERENT grade than the slab", () => {
    // This is a g9 whose only sales are g10. The app labels the grade rather than
    // hiding them, so the data must survive parsing; salesForGrade does the gating.
    expect(r.comps).toHaveLength(1);
    expect(r.comps[0].grade).toBe("10");
    expect(r.comps[0].sales[0]).toEqual({ priceCents: 14500, soldAt: "2026-05-17T00:00:00Z" });
  });
});

describe("comps are keyed by grader AND grade", () => {
  const r = parseCardDetails(PSA, "psa", "96679812");

  it("does not merge two graders' grade-10 groups", () => {
    // cert 96679812 returns TWO grade-10 groups: PSA (pop 23) and SGC (pop 3).
    // Every group repeats the SCANNED card's title, so `title` says "(PSA g10)"
    // on both — keying off it would report SGC's sales as PSA's.
    const tens = r.comps.filter((g) => g.grade === "10");
    expect(tens).toHaveLength(2);
    expect(tens.map((g) => g.grader).sort()).toEqual(["PSA", "SGC"]);
  });

  it("returns only the slab's own grader+grade sales", () => {
    const sales = salesForGrade(r, "PSA", "10");
    expect(sales.length).toBe(12);
    expect(populationForGrade(r, "PSA", "10")).toBe(23);
    // The SGC group is a different set entirely.
    expect(salesForGrade(r, "SGC", "10").length).toBe(1);
  });

  it("returns [] — not another grade's sales — when the slab's grade has none", () => {
    const g9 = parseCardDetails(NOPRICE, "psa", "154334127");
    expect(salesForGrade(g9, "PSA", "9")).toEqual([]);
  });

  it("sorts sales newest first", () => {
    const sales = salesForGrade(r, "PSA", "10");
    const dates = sales.map((s) => s.soldAt);
    expect([...dates].sort((a, b) => b.localeCompare(a))).toEqual(dates);
  });
});

describe("CGC", () => {
  const r = parseCardDetails(CGC, "cgc", "4260611176");
  it("is a real source for CGC, which had none before", () => {
    expect(r.priceCents).toBe(11100);
    expect(r.confidence).toBe(5);
    expect(r.identity.grade).toBe("10");
  });
});

describe("fetchCardDetails error semantics", () => {
  it("404 is AUTHORITATIVE not_found — the UI shows an em dash", async () => {
    await expect(fetchCardDetails("133653550", "psa", { fetch: stub(NOTFOUND, 404) })).rejects.toMatchObject({
      kind: "not_found",
    });
  });

  it("502 from their gemrate upstream is TRANSIENT, not a missing card", async () => {
    // Must not blank a price the user already saw — PriceWriteback holds that rule.
    await expect(
      fetchCardDetails("00000001", "psa", { fetch: stub({ message: "invalid response from gemrate" }, 502) }),
    ).rejects.toMatchObject({ kind: "source_error" });
  });

  it("a transport failure is a network error, not a not_found", async () => {
    const boom = (async () => {
      throw new Error("connection reset");
    }) as unknown as typeof fetch;
    await expect(fetchCardDetails("96679812", "psa", { fetch: boom })).rejects.toBeInstanceOf(CyError);
  });

  it("round-trips a live-shaped response", async () => {
    const r = await fetchCardDetails("96679812", "psa", { fetch: stub(PSA) });
    expect(r.priceCents).toBe(5080);
    expect(r.sourceKey).toBe("PSA_96679812");
  });
});

// The WAF in front of api.courtyard.io/scanner/* blocks by User-Agent (measured
// 2026-09-03: curl/node/python/Go and an ABSENT agent all 403; Deno, undici,
// okhttp, browsers and our own string all 200). This module runs under three
// runtimes with three different defaults, so the header has to be explicit — and
// asserted, because losing it fails in exactly the way that is hardest to read:
// a 403 becomes `source_error`, which is the same path a genuine GemRate outage
// takes, so the app blanks the price and nothing says why.
describe("every request carries a User-Agent — the /scanner/* WAF blocks without one", () => {
  const spy = () => {
    const seen: RequestInit[] = [];
    const fetchSpy = (async (_url: string, init: RequestInit) => {
      seen.push(init);
      return new Response(JSON.stringify(PSA), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }) as unknown as typeof fetch;
    return { seen, fetchSpy };
  };

  it("sends one, and it is not empty", async () => {
    const { seen, fetchSpy } = spy();
    await fetchCardDetails("96679812", "psa", { fetch: fetchSpy });
    const headers = seen[0].headers as Record<string, string>;
    expect(headers["User-Agent"]).toBe(SCANNER_UA);
    expect(SCANNER_UA.length).toBeGreaterThan(0);
  });

  it("does not identify as a blocked tool agent", () => {
    // Substrings the wall 403s. A future edit that reaches for a runtime default
    // or a copied curl string trips this rather than silently blanking prices.
    for (const blocked of ["curl", "python-requests", "Go-http-client", "node"]) {
      expect(SCANNER_UA.toLowerCase()).not.toContain(blocked.toLowerCase());
    }
  });

  it("still asks for JSON", async () => {
    const { seen, fetchSpy } = spy();
    await fetchCardDetails("96679812", "psa", { fetch: fetchSpy });
    expect((seen[0].headers as Record<string, string>).Accept).toBe("application/json");
  });

  // The SECOND load-bearing header, and the one with teeth: without it the
  // endpoint 404s certs it will price perfectly with it (measured 2026-09-06 —
  // cert 60928769 goes 404 -> $144.40 conf 5 on this header alone). A 404 is
  // AUTHORITATIVE in this pipeline: it gets cached and renders an em dash, so
  // dropping this header does not fail loudly, it silently converts real prices
  // into "Courtyard has no data" for 24h at a time. See spike/README.md §2f.
  it("sends the acquisition-status header — without it a priceable cert 404s", async () => {
    const { seen, fetchSpy } = spy();
    await fetchCardDetails("96679812", "psa", { fetch: fetchSpy });
    expect((seen[0].headers as Record<string, string>)[SCANNER_ACQ_HEADER]).toBe("1");
  });

  it("sends it on EVERY attempt, including the grader-flip retry", async () => {
    // The retry path builds its own request. A header set only on the first
    // attempt would rescue nothing for exactly the certs that need both fixes.
    const seen: RequestInit[] = [];
    const flip = (async (url: string, init: RequestInit) => {
      seen.push(init);
      return url.includes("grader=PSA")
        ? new Response(JSON.stringify({ message: "invalid" }), { status: 400 })
        : new Response(JSON.stringify(PSA), {
            status: 200,
            headers: { "content-type": "application/json" },
          });
    }) as unknown as typeof fetch;
    await fetchCardDetails("96679812", "psa", { fetch: flip }).catch(() => {});
    expect(seen.length).toBeGreaterThan(1);
    for (const init of seen) {
      const h = init.headers as Record<string, string>;
      expect(h[SCANNER_ACQ_HEADER]).toBe("1");
      expect(h["User-Agent"]).toBe(SCANNER_UA);
    }
  });
});

// A mis-guessed grader is the failure this suite exists for. Nothing in a slab
// barcode says who graded it — CertParser infers it from digit count — and GemRate
// answers a wrong pairing with 400, deterministically, forever. Verified live
// 2026-09-05: cert 96679812 is 200 as PSA and 400 as CGC; 4260611176 is the mirror
// image. Until this fallback existed a 400 was classed `source_error` (transient),
// so it was never cached and every refresh re-sent the same doomed request: the
// card showed an em dash indefinitely while Card Ladder priced it fine.
describe("a mis-guessed grader recovers instead of failing forever", () => {
  /** Routes by the (cert, grader) in the URL, like the real endpoint does. */
  const router = (ok: Array<{ cert: string; grader: string }>, otherwise = 400) => {
    const calls: string[] = [];
    const fetchStub = (async (url: string) => {
      calls.push(url);
      const hit = ok.some((o) => url.includes(`cert=${o.cert}&`) && url.includes(`grader=${o.grader}`));
      return hit
        ? new Response(JSON.stringify(PSA), { status: 200, headers: { "content-type": "application/json" } })
        : new Response(JSON.stringify({ message: "unable to query gemrate for cert" }), {
            status: otherwise,
            headers: { "content-type": "application/json" },
          });
    }) as unknown as typeof fetch;
    return { calls, fetchStub };
  };

  it("flips the grader when the guess was wrong, and answers", async () => {
    // Scanned as CGC (10-digit guess), actually PSA.
    const { calls, fetchStub } = router([{ cert: "96679812", grader: "PSA" }]);
    const r = await fetchCardDetails("96679812", "cgc", { fetch: fetchStub });
    expect(r.priceCents).toBe(5080);
    // Keyed by the pairing that ANSWERED, not the one we guessed.
    expect(r.sourceKey).toBe("PSA_96679812");
    expect(calls).toHaveLength(2);
  });

  it("tries the guess FIRST, so a correct guess still costs one request", async () => {
    const { calls, fetchStub } = router([{ cert: "96679812", grader: "PSA" }]);
    await fetchCardDetails("96679812", "psa", { fetch: fetchStub });
    expect(calls).toHaveLength(1);
  });

  it("recovers a zero-padded cert, which flips the digit-count guess too", async () => {
    const { calls, fetchStub } = router([{ cert: "96679812", grader: "PSA" }]);
    const r = await fetchCardDetails("0096679812", "cgc", { fetch: fetchStub });
    expect(r.priceCents).toBe(5080);
    expect(r.sourceKey).toBe("PSA_96679812");
    expect(calls.length).toBeLessThanOrEqual(4);
  });

  it("reports `unresolvable` — an ANSWER, cached — when no pairing works", async () => {
    const { fetchStub } = router([]);
    await expect(fetchCardDetails("12345678", "psa", { fetch: fetchStub })).rejects.toMatchObject({
      kind: "unresolvable",
    });
  });

  it("does NOT walk the fallbacks on a 404 — that is authoritative about the cert", async () => {
    const calls: string[] = [];
    const stub404 = (async (url: string) => {
      calls.push(url);
      return new Response(JSON.stringify(NOTFOUND), { status: 404 });
    }) as unknown as typeof fetch;
    await expect(fetchCardDetails("133653550", "psa", { fetch: stub404 })).rejects.toMatchObject({
      kind: "not_found",
    });
    expect(calls).toHaveLength(1);
  });

  it("does NOT walk the fallbacks on a 5xx — their upstream, not our parameters", async () => {
    const calls: string[] = [];
    const stub502 = (async (url: string) => {
      calls.push(url);
      return new Response(JSON.stringify({ message: "invalid response from gemrate" }), { status: 502 });
    }) as unknown as typeof fetch;
    await expect(fetchCardDetails("96679812", "psa", { fetch: stub502 })).rejects.toMatchObject({
      kind: "source_error",
    });
    expect(calls).toHaveLength(1);
  });
});

describe("attemptsFor", () => {
  it("puts the caller's own guess first, then the other grader", () => {
    expect(attemptsFor("96679812", "psa")).toEqual([
      { cert: "96679812", grader: "psa" },
      { cert: "96679812", grader: "cgc" },
    ]);
  });

  it("adds zero-stripped variants only when there are leading zeros", () => {
    expect(attemptsFor("0096679812", "cgc")).toEqual([
      { cert: "0096679812", grader: "cgc" },
      { cert: "0096679812", grader: "psa" },
      { cert: "96679812", grader: "cgc" },
      { cert: "96679812", grader: "psa" },
    ]);
  });

  it("never proposes an empty cert", () => {
    expect(attemptsFor("000", "psa").every((a) => a.cert.length > 0)).toBe(true);
  });
});

// The fallback retries under a DIFFERENT grader, and nothing proves the PSA and
// CGC cert namespaces are disjoint. Without this guard, a number that is a valid
// cert for BOTH graders would let the fallback accept a different card and price
// it as this slab — the same class of error the `identify()` bar prevents on the
// Algolia side. Courtyard echoes graderData.cert/grader, so we verify them.
describe("a fallback can never accept a different card", () => {
  const withEcho = (cert: string, grader: string) => {
    const body = JSON.parse(JSON.stringify(PSA));
    body.graderData.cert = cert;
    body.graderData.grader = grader;
    return (async () =>
      new Response(JSON.stringify(body), {
        status: 200,
        headers: { "content-type": "application/json" },
      })) as unknown as typeof fetch;
  };

  it("rejects a 200 whose echoed cert is a different card", async () => {
    await expect(
      fetchCardDetails("96679812", "psa", { fetch: withEcho("11112222", "PSA") }),
    ).rejects.toMatchObject({ kind: "unresolvable" });
  });

  it("refuses a grader-mismatched 200 when the other grader has no answer either", async () => {
    // The PSA attempt comes back labelled CGC; the CGC attempt then 400s. Neither
    // pairing is self-consistent, so there is no answer — rather than accepting a
    // response about a grader we did not ask for.
    //
    // NOTE the deliberate non-case: if the CGC attempt HAD returned a CGC-labelled
    // 200, accepting it as CGC is correct, not a leak. That is the fallback working
    // — the slab really is CGC and our digit-count guess was wrong. The guard exists
    // to stop a response describing a DIFFERENT CARD, which the cert echo catches.
    const fetchStub = (async (url: string) => {
      const body = JSON.parse(JSON.stringify(PSA));
      body.graderData.cert = "96679812";
      body.graderData.grader = "CGC";
      return url.includes("grader=PSA")
        ? new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } })
        : new Response(JSON.stringify({ message: "unable to query gemrate for cert" }), { status: 400 });
    }) as unknown as typeof fetch;
    await expect(
      fetchCardDetails("96679812", "psa", { fetch: fetchStub }),
    ).rejects.toMatchObject({ kind: "unresolvable" });
  });

  it("accepts the matching echo, ignoring leading zeros on our side", async () => {
    const r = await fetchCardDetails("0096679812", "psa", { fetch: withEcho("96679812", "PSA") });
    expect(r.priceCents).toBe(5080);
  });

  it("does NOT reject when the echo is absent — a shape change must not blank everything", async () => {
    const body = JSON.parse(JSON.stringify(PSA));
    delete body.graderData.cert;
    delete body.graderData.grader;
    const noEcho = (async () =>
      new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } })) as unknown as typeof fetch;
    const r = await fetchCardDetails("96679812", "psa", { fetch: noEcho });
    expect(r.priceCents).toBe(5080);
  });
});

// The slab photograph, from /scanner/card-grader-image. Fixtures are captured from
// the live endpoint (cert 129123650, and a made-up cert for the empty case), so the
// shape below is real, not imagined — including the two traps in it.
const IMAGES = load("courtyard-grader-image.json");
const IMAGES_EMPTY = load("courtyard-grader-image-empty.json");

describe("parseGraderImages", () => {
  it("reads front and back at both sizes", () => {
    const r = parseGraderImages(IMAGES);
    expect(r.frontUrl).toContain("/small/");
    expect(r.frontThumbUrl).toContain("/thumbnail/");
    expect(r.backUrl).toContain("/small/");
    expect(r.backThumbUrl).toContain("/thumbnail/");
    expect(r.frontUrl).not.toBe(r.backUrl);
  });

  it("treats an ABSENT imageSize as the full-size entry", () => {
    // TRAP: the full-size images carry no `imageSize` key at all — only the
    // thumbnails are labelled. Matching on the string "None" would find nothing and
    // silently leave every card thumbnail-only.
    const full = IMAGES.primaryImages.filter((i: any) => i.imageSize === undefined);
    expect(full.length).toBe(2);
    expect(parseGraderImages(IMAGES).frontUrl).toBeDefined();
  });

  it("returns nothing for a cert with no images — 200 is NOT a hit", () => {
    // The endpoint answers an unknown cert with 200 + an empty array (and
    // status:"ERROR"). Treating 200 as success is how a card would get no image and
    // no explanation. The array length is the only thing that decides.
    expect(IMAGES_EMPTY.primaryImages).toEqual([]);
    expect(parseGraderImages(IMAGES_EMPTY)).toEqual({
      frontUrl: undefined, frontThumbUrl: undefined, backUrl: undefined, backThumbUrl: undefined,
    });
  });

  it("survives junk without throwing", () => {
    for (const junk of [null, {}, { primaryImages: null }, { primaryImages: [{}, 1, "x"] }]) {
      expect(() => parseGraderImages(junk)).not.toThrow();
    }
  });
});

describe("fetchGraderImages never costs a price", () => {
  // A missing picture must never blank a number. Every failure here has the same
  // right answer — no image, carry on — so this function does not throw at all. If
  // it did, the throw would land on the `source_error` path beside the price.
  const failing = (status: number) =>
    (async () => new Response("boom", { status })) as unknown as typeof fetch;

  it("returns {} on 5xx", async () => {
    expect(await fetchGraderImages("96679812", "psa", { fetch: failing(503) })).toEqual({});
  });

  it("returns {} on a transport failure", async () => {
    const boom = (async () => { throw new Error("offline"); }) as unknown as typeof fetch;
    expect(await fetchGraderImages("96679812", "psa", { fetch: boom })).toEqual({});
  });

  it("returns {} on unparseable JSON", async () => {
    const bad = (async () => new Response("<html>", { status: 200 })) as unknown as typeof fetch;
    expect(await fetchGraderImages("96679812", "psa", { fetch: bad })).toEqual({});
  });

  it("sends the User-Agent — this route is behind the same WAF", async () => {
    const seen: RequestInit[] = [];
    const spy = (async (_u: string, init: RequestInit) => {
      seen.push(init);
      return new Response(JSON.stringify(IMAGES), { status: 200 });
    }) as unknown as typeof fetch;
    await fetchGraderImages("129123650", "psa", { fetch: spy });
    expect((seen[0].headers as Record<string, string>)["User-Agent"]).toBe(SCANNER_UA);
    // Measurably a no-op on THIS route today (a photo-less cert returns
    // `primaryImages: null` either way). Asserted so the two scanner routes stay
    // identical: if Courtyard ever gates images the way it gates card-details,
    // this is already correct rather than another silent coverage hole.
    expect((seen[0].headers as Record<string, string>)[SCANNER_ACQ_HEADER]).toBe("1");
  });

  it("parses a real response end to end", async () => {
    const ok = (async () => new Response(JSON.stringify(IMAGES), { status: 200 })) as unknown as typeof fetch;
    const r = await fetchGraderImages("129123650", "psa", { fetch: ok });
    expect(r.frontUrl).toMatch(/^https:\/\/.*\.jpg$/);
  });
});
