// Authenticated PSA cert metadata lookup. Cache hits stay in Supabase; misses
// cross a secret-authenticated boundary to the browser-capable Cloudflare Worker.

import { admin, callerId, json } from "../_shared/http.ts";

const CACHE_TTL_MS = 30 * 24 * 60 * 60 * 1000;

interface Body { certNumber?: string }
interface WorkerReply {
  status: "ok" | "not_found" | "source_error";
  certNumber?: string;
  subject?: string;
  set?: string;
  year?: number;
  grade?: string;
  title?: string;
  cardNumber?: string;
  imageUrl?: string;
}

interface PsaEnvelope {
  IsValidRequest?: boolean;
  ServerMessage?: string;
  PSACert?: Record<string, unknown>;
  [key: string]: unknown;
}

const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() ? value.trim() : undefined;

const integer = (value: unknown): number | undefined => {
  const parsed = typeof value === "number" ? value : typeof value === "string" ? Number.parseInt(value, 10) : NaN;
  return Number.isFinite(parsed) ? parsed : undefined;
};

async function officialLookup(certNumber: string): Promise<WorkerReply | null> {
  const token = Deno.env.get("PSA_ACCESS_TOKEN");
  if (!token) return null;
  try {
    const response = await fetch(`https://api.psacard.com/publicapi/cert/GetByCertNumber/${encodeURIComponent(certNumber)}`, {
      headers: { authorization: `bearer ${token}`, accept: "application/json" },
      signal: AbortSignal.timeout(15_000),
    });
    // Approval/quota/transient failures fall through to the browser adapter.
    if (!response.ok) return null;
    const envelope = await response.json() as PsaEnvelope;
    if (envelope.IsValidRequest === false || /no data found/i.test(envelope.ServerMessage ?? "")) {
      return { status: "not_found" };
    }
    const cert = (envelope.PSACert ?? envelope) as Record<string, unknown>;
    return {
      status: "ok",
      certNumber,
      subject: text(cert.Subject),
      set: text(cert.Brand) ?? text(cert.BrandTitle),
      year: integer(cert.Year),
      grade: text(cert.CardGrade) ?? text(cert.GradeDescription),
      cardNumber: text(cert.CardNumber),
      // No assembled title from the official API — only the scrape's <h1> has
      // one. Building it from the parts would be fabricating a value.
      imageUrl: text(cert.ImageUrl) ?? text(cert.ImageURL) ?? text(cert.FrontImageURL),
    };
  } catch {
    return null;
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ status: "method_not_allowed" }, 405);
  if (!(await callerId(req))) return json({ status: "unauthorized" }, 401);

  let body: Body;
  try { body = await req.json(); } catch { return json({ status: "bad_request" }, 400); }
  const certNumber = String(body.certNumber ?? "").trim();
  if (!/^\d{7,10}$/.test(certNumber)) return json({ status: "bad_request" }, 400);

  const db = admin();
  const { data: cached } = await db
    .from("psa_cert_cache")
    .select("subject, card_set, card_year, grade, title, card_number, image_url, fetch_status, updated_at")
    .eq("cert_number", certNumber)
    .maybeSingle();
  // A row cached before titles existed has title IS NULL. Under a 30-day TTL
  // that would hide the new field for a month on every already-scanned cert, so
  // treat it as a miss and refetch.
  const titleless = cached?.fetch_status === "ok" && cached.title === null;
  if (cached && !titleless && Date.now() - new Date(cached.updated_at).getTime() < CACHE_TTL_MS) {
    if (cached.fetch_status === "not_found") return json({ status: "not_found", cached: true });
    if (cached.fetch_status === "ok") return json({
      status: "ok", certNumber, subject: cached.subject, set: cached.card_set,
      year: cached.card_year, grade: cached.grade, title: cached.title,
      cardNumber: cached.card_number, imageUrl: cached.image_url, cached: true,
    });
  }

  let result: WorkerReply;
  const official = await officialLookup(certNumber);
  if (official) {
    result = official;
  } else {
    const workerUrl = Deno.env.get("PSA_SCRAPER_URL");
    const workerToken = Deno.env.get("PSA_SCRAPER_TOKEN");
    if (!workerUrl || !workerToken) return json({ status: "source_error" });
    try {
      const response = await fetch(`${workerUrl.replace(/\/$/, "")}/lookup`, {
        method: "POST",
        headers: { "authorization": `Bearer ${workerToken}`, "content-type": "application/json" },
        body: JSON.stringify({ certNumber }),
        signal: AbortSignal.timeout(50_000),
      });
      if (!response.ok && response.status !== 404) return json({ status: "source_error" });
      result = await response.json();
    } catch {
      return json({ status: "source_error" });
    }
  }

  const now = new Date().toISOString();
  if (result.status === "ok") {
    await db.from("psa_cert_cache").upsert({
      cert_number: certNumber, subject: result.subject ?? null, card_set: result.set ?? null,
      card_year: result.year ?? null, grade: result.grade ?? null, image_url: result.imageUrl ?? null,
      title: result.title ?? null, card_number: result.cardNumber ?? null,
      fetch_status: "ok", updated_at: now,
    });
    return json(result);
  }
  if (result.status === "not_found") {
    await db.from("psa_cert_cache").upsert({ cert_number: certNumber, fetch_status: "not_found", updated_at: now });
    return json({ status: "not_found" });
  }
  return json({ status: "source_error" });
});
