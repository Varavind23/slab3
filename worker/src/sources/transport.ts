// HTTP transport abstraction.
//
// Why this exists: api.courtyard.io sits behind Cloudflare, which fingerprints
// the TLS/HTTP stack — a bare Node fetch() gets 403 even with correct headers,
// but a fetch executed INSIDE a real browser context returns 200 (verified in
// the M0 spike, 2026-08-21). So production routes requests through a Playwright
// browser context; tests inject a fixture transport. Same adapter code, swapped
// transport.

export interface JsonTransport {
  /** GET a URL, return parsed JSON. Throws TransportError on non-2xx/parse fail. */
  getJson(url: string): Promise<unknown>;
}

export class TransportError extends Error {
  constructor(
    message: string,
    readonly status?: number,
  ) {
    super(message);
    this.name = "TransportError";
  }
}

/** Test transport: maps URL substrings to fixture payloads. */
export class FixtureTransport implements JsonTransport {
  constructor(private readonly routes: Array<{ match: string; body: unknown; status?: number }>) {}
  async getJson(url: string): Promise<unknown> {
    const hit = this.routes.find((r) => url.includes(r.match));
    if (!hit) throw new TransportError(`no fixture for ${url}`, 404);
    if (hit.status && hit.status >= 400) throw new TransportError(`fixture ${hit.status}`, hit.status);
    return hit.body;
  }
}
